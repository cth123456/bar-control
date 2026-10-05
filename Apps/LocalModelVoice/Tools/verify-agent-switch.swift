// 无界面核对脚本：拿本机真实的 router.json / 客户端配置跑一遍 Agent 页的推理，
// 把「每张卡片会显示什么」打出来。只读，不写任何配置。
//
// 构建并运行：Tools/verify-agent-switch.command

import Foundation

@main
struct VerifyAgentSwitch {
    static func main() {
        let model = HubModel()
        model.refresh()

        rule()
        line("模型池：\(model.poolModels.count) 行 · Agent 线路：\(model.agents.count) 条")
        for agent in model.agents {
            let bound = agent.providerIDs.map { model.modelName(providerID: $0) }
            line("  线路 \(agent.name)（\(agent.id)）：\(bound.joined(separator: " / "))")
        }

        rule()
        line("客户端清单：\(model.clientSpecs.map(\.name).joined(separator: "、"))")

        for spec in model.clientSpecs {
            // 和 Agent 页 detectedAgents 里完全同一条链：先按登记的路径找，再按名字猜。
            let file = HubAgentSync.detect(path: spec.path) ?? HubAgentSync.detect(agentName: spec.name)
            let plan = file.flatMap { try? HubAgentSync.plan(agentName: spec.name, fileURL: $0) }
            let current = plan?.currentModel?.trimmingCharacters(in: .whitespaces)
            let real = (current?.isEmpty == false) ? current : nil
            let route = plan?.modelRoute
            let rows = model.switchableModels(route: route, currentModel: real)

            rule()
            line("\(spec.name)  \(spec.path)")
            line("  配置存在：\(file == nil ? "否" : "是")"
                 + " · 当前模型：\(real ?? "读不出来")"
                 + " · 线路：\(route ?? "读不出来（按整个模型池给候选）")")
            line("  配置里登记的模型 \(plan?.configuredModels.count ?? 0) 个"
                 + " · 客户端能一次存多个模型：\(plan?.holdsModelList == true ? "是" : "否")")
            // 「添加模型」菜单每张卡片都有，列表来自整个模型池：当前正在用的那个也留在里面
            // （标出来并置灰），停用的同样留着（名字后面标出来）。这一份与客户端能不能一次存
            // 多个模型无关 —— 单格的客户端以前按钮叫「设为当前模型」并且把当前模型滤掉，
            // 池里只有一个模型时菜单就是空的。
            line("  「添加模型」菜单 \(model.poolModels.count) 项（整池：含当前正在用的、含停用的）：")
            for entry in model.poolModels {
                var marks: [String] = []
                if HubModel.isCurrentModel(entry, currentModel: real) { marks.append("← 当前正在用（置灰）") }
                if !model.providerEnabled(entry.id) { marks.append("（已停用）") }
                line("    \(model.modelName(providerID: entry.id))\(marks.isEmpty ? "" : "  " + marks.joined(separator: " "))")
            }
            if model.poolModels.isEmpty { line("    （模型池是空的）") }

            if plan?.holdsModelList == false {
                // 只存一格的客户端还会在下面画一条「可切换的模型」：线路读不出来时它是整个模型池。
                line("  切换盘上 \(rows.count) 个模型（线路绑的 ＋ 池里其它启用的；线路读不出来时＝整个池）：")
                for row in rows {
                    var marks: [String] = []
                    if row.isCurrent { marks.append("← 当前") }
                    if row.isUnbound { marks.append("（未绑定）") }
                    if row.isDisabled { marks.append("（已停用）") }
                    let supplier = row.model.supplier.map { " · \($0)" } ?? ""
                    line("    \(row.model.model)\(supplier)\(marks.isEmpty ? "" : "  " + marks.joined(separator: " "))")
                }
                if rows.isEmpty { line("    （没有）") }
                let unboundCount = rows.filter { $0.isUnbound && !$0.isCurrent }.count
                if real != nil, unboundCount > 0 {
                    line("  其中 \(unboundCount) 个没绑在这条线路上：切开网关会拿名字在池里找到它、发它，"
                         + "并顺手绑进这条线路（不是「用不了的模型」）。")
                }
                let currentCount = rows.filter(\.isCurrent).count
                let verdict = currentCount == 1 ? "（正好一个）"
                    : (real == nil ? "（当前模型读不出来，所以没法标）" : "（应为 1，检查判定）")
                line("  当前标记 \(currentCount) 个\(verdict)")
            } else {
                line("  （它一次能存多个模型，不画切换盘）")
            }
        }

        rule()
        line("完成：以上都是本机真实配置算出来的结果。")
    }

    static func line(_ text: String) { print(text) }

    static func rule() { line(String(repeating: "─", count: 78)) }
}
