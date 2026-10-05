import Foundation

/// 一个可以被用户增删的 Agent 客户端声明。
///
/// 只说清三件事：配置在哪、界面里叫什么、允不允许把模型写进去。至于那个文件里到底哪个字段
/// 是模型名，仍然由 `HubAgentSync` 按文件的真实格式（TOML / JSON）判断，认不出来就拒绝。
/// 所以「加了一个客户端」不等于「一定能改它的模型」—— 界面不许假装能。
struct HubClientSpec: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// 配置文件路径。允许写 `~`，落盘时原样保存（不展开），因为换台机器 home 就不一样了。
    var path: String
    var editable: Bool
}

/// 客户端清单的唯一读写入口。
///
/// 落盘在 router 支持目录里的 `clients.json`，但**不是** router.json 的一部分：
/// router.json 是路由真源，这份清单只回答「界面要盯哪几个客户端」。两者谁都不覆盖谁。
enum HubClientRegistry {
    static let fileName = "clients.json"

    /// 默认清单：代码里认得 schema 的那几个。删改以后可以用「恢复默认」一键回来。
    static let seed: [HubClientSpec] = [
        HubClientSpec(id: "codex", name: "Codex", path: "~/.codex/config.toml", editable: true),
        HubClientSpec(id: "zcode", name: "ZCode", path: "~/.zcode/v2/config.json", editable: true),
        HubClientSpec(id: "claude", name: "Claude Code", path: "~/.claude/settings.json", editable: false),
        HubClientSpec(id: "opencode", name: "OpenCode", path: "~/.config/opencode/opencode.json", editable: false),
    ]

    static var storageURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("LocalSiriLLM", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// 读清单。文件不存在 / 读不出来 / 读出来是空的 → 默认清单（**不写盘**，保持「没配过」这个事实本身）。
    static func load(from url: URL? = nil) -> [HubClientSpec] {
        let file = url ?? storageURL
        guard let data = try? Data(contentsOf: file),
              let specs = try? JSONDecoder().decode([HubClientSpec].self, from: data) else {
            return seed
        }
        let cleaned = sanitize(specs)
        return cleaned.isEmpty ? seed : cleaned
    }

    /// 清洗：丢掉空行、补上缺的 id、按 id 去重。返回顺序就是界面顺序，用户排的序不许被重排。
    static func sanitize(_ specs: [HubClientSpec]) -> [HubClientSpec] {
        var seen = Set<String>()
        var result: [HubClientSpec] = []
        for var spec in specs {
            spec.name = spec.name.trimmingCharacters(in: .whitespacesAndNewlines)
            spec.path = spec.path.trimmingCharacters(in: .whitespacesAndNewlines)
            spec.id = spec.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spec.name.isEmpty, !spec.path.isEmpty else { continue }
            if spec.id.isEmpty { spec.id = slug(spec.name) }
            guard seen.insert(spec.id).inserted else { continue }
            result.append(spec)
        }
        return result
    }

    /// 名字 → id。只用于用户没给 id 的时候，所以允许它不够漂亮，但必须**每次启动都一样**：
    /// 不能用 hashValue，Swift 的字符串哈希每个进程都不一样，那会让同一份清单每次启动换 id。
    static func slug(_ name: String) -> String {
        let mapped = name.lowercased().map { character -> Character in
            (character.isLetter || character.isNumber) ? character : "-"
        }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "client" : collapsed
    }

    /// `~` 展开成真实的绝对路径。
    static func resolvedURL(for spec: HubClientSpec) -> URL {
        URL(fileURLWithPath: (spec.path as NSString).expandingTildeInPath)
    }

    /// 写清单：清洗 → 原子写 → 读回验证。任何一步失败都抛错，界面不许报成功。
    @discardableResult
    static func save(_ specs: [HubClientSpec], to url: URL? = nil) throws -> [HubClientSpec] {
        let file = url ?? storageURL
        let cleaned = sanitize(specs)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cleaned).write(to: file, options: .atomic)
        // 读回验证：磁盘上那份必须和刚写的一模一样，否则等于没存住。
        let readBack = try JSONDecoder().decode([HubClientSpec].self, from: Data(contentsOf: file))
        guard readBack == cleaned else { throw Failure.readBackMismatch }
        return cleaned
    }

    enum Failure: LocalizedError {
        case readBackMismatch

        var errorDescription: String? {
            switch self {
            case .readBackMismatch: return "清单写回后读回来的内容和刚写的不一致"
            }
        }
    }

    // MARK: 自检（--hub-self-test 调用；只碰临时目录）

    /// 把自检结果打成人能看的 PASS / FAIL，并给出退出码（0 = 全过）。
    static func runSelfTest() -> Int32 {
        let failures = selfTest()
        for failure in failures {
            print("FAIL 客户端清单：\(failure)")
        }
        if failures.isEmpty {
            print("PASS 客户端清单：默认值 / 增 / 删 / 脏数据清洗 / 路径展开 / 拒写未知格式")
        }
        return failures.isEmpty ? 0 : 1
    }

    static func selfTest() -> [String] {
        var failures: [String] = []
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hub-clients-selftest-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent(fileName)
        defer { try? FileManager.default.removeItem(at: directory) }

        if seed.isEmpty || seed.contains(where: { $0.name.isEmpty || $0.path.isEmpty || $0.id.isEmpty }) {
            failures.append("默认客户端清单必须有 id / 名字 / 路径")
        }
        if load(from: file) != seed {
            failures.append("清单文件还不存在时必须给出默认清单")
        }

        // 增：自定义客户端 + 默认清单，落盘后读回来必须一致。
        let custom = HubClientSpec(id: "", name: "Cursor",
                                   path: "~/Library/Application Support/Cursor/settings.json", editable: true)
        do {
            let saved = try save([custom] + seed, to: file)
            if saved.count != seed.count + 1 {
                failures.append("添加客户端后清单条数不对")
            }
            if saved.first?.id != "cursor" || saved.first?.name != "Cursor" {
                failures.append("新客户端要按名字补出稳定 id")
            }
            if load(from: file) != saved {
                failures.append("客户端清单存盘后读回来必须一致")
            }
        } catch {
            failures.append("保存客户端清单失败：\(error.localizedDescription)")
        }

        // 删：只删一个，其它的必须原样留在清单里（删减不许连坐）。
        do {
            let remaining = try save(seed.filter { $0.id != "zcode" }, to: file)
            if remaining.contains(where: { $0.id == "zcode" }) {
                failures.append("删掉的客户端不该还在清单里")
            }
            if remaining.count != seed.count - 1 {
                failures.append("删一个客户端不该带走别的")
            }
            if load(from: file) != remaining {
                failures.append("删除后读回来的清单和存盘的应一致")
            }
        } catch {
            failures.append("删除客户端失败：\(error.localizedDescription)")
        }

        // 脏数据：空名字 / 空路径丢掉，重复 id 只留第一条，乱输入不许让整份清单变空。
        let dirty = sanitize([
            HubClientSpec(id: "a", name: "A", path: "~/a.json", editable: true),
            HubClientSpec(id: "a", name: "重复的 A", path: "~/a2.json", editable: true),
            HubClientSpec(id: "", name: "   ", path: "~/b.json", editable: true),
            HubClientSpec(id: "c", name: "C", path: "  ", editable: true),
        ])
        if dirty.count != 1 || dirty.first?.name != "A" {
            failures.append("清单清洗要去重并丢掉空名字 / 空路径")
        }
        if sanitize([HubClientSpec(id: "x", name: "X", path: "~/x.json", editable: false)]).count != 1 {
            failures.append("合法的一条清单不该被清洗掉")
        }

        // 路径：`~` 展开，存在性与格式检查都按真实文件说话。
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if resolvedURL(for: HubClientSpec(id: "t", name: "T", path: "~/x.json", editable: false)).path !=
            home + "/x.json" {
            failures.append("客户端路径要把 ~ 展开成 home")
        }
        if HubAgentSync.detect(path: directory.appendingPathComponent("not-there.json").path) != nil {
            failures.append("文件不存在时不许当成找到了客户端")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let real = directory.appendingPathComponent("probe.json")
            try "{\"model\":\"gpt-x\"}".write(to: real, atomically: true, encoding: .utf8)
            if HubAgentSync.detect(path: real.path) != real {
                failures.append("文件存在时应该按登记的路径找到它")
            }
            // 认不出的格式必须拒绝，而不是往别人的配置文件里乱塞一个 model 字段。
            let yaml = directory.appendingPathComponent("probe.yaml")
            try "model: gpt-x\n".write(to: yaml, atomically: true, encoding: .utf8)
            if (try? HubAgentSync.plan(agentName: "Cursor", fileURL: yaml)) != nil {
                failures.append("认不出的配置格式必须拒绝写入，不能猜")
            }
        } catch {
            failures.append("自检准备临时文件失败：\(error.localizedDescription)")
        }

        return failures
    }
}
