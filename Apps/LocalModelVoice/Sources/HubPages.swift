import AppKit
import Combine
import SwiftUI

// MARK: - 设计令牌

enum HubInk {
    static let page = Color(red: 0.961, green: 0.969, blue: 0.984)
    static let card = Color.white
    static let hero = Color(red: 0.078, green: 0.078, blue: 0.086)
    static let ink = Color(red: 0.090, green: 0.137, blue: 0.247)
    static let sub = Color(red: 0.400, green: 0.439, blue: 0.522)
    static let faint = Color(red: 0.545, green: 0.580, blue: 0.659)
    static let line = Color(red: 0.906, green: 0.918, blue: 0.949)
    static let accent = Color(red: 0.388, green: 0.463, blue: 1.0)
    static let green = Color(red: 0.086, green: 0.639, blue: 0.290)
    static let orange = Color(red: 0.937, green: 0.553, blue: 0.0)
    static let red = Color(red: 0.839, green: 0.211, blue: 0.196)
    static let onDark = Color(red: 0.973, green: 0.973, blue: 0.980)
    static let onDarkSub = Color(red: 0.973, green: 0.973, blue: 0.980).opacity(0.58)

    // 设计稿（Lunacy）里另外几个色值，和上面的通用令牌区分开，避免改一处影响全局。
    /// 说明文字 #7A8499
    static let muted = Color(red: 0.478, green: 0.518, blue: 0.600)
    /// 卡片里的小字提示 #A0A8B8
    static let hint = Color(red: 0.627, green: 0.659, blue: 0.722)
    /// 表头文字 #8B94A8
    static let tableHead = Color(red: 0.545, green: 0.580, blue: 0.659)
    /// 浅底块 #F7F8FC
    static let band = Color(red: 0.969, green: 0.973, blue: 0.988)
    /// 浅紫底 #EEF1FF
    static let tint = Color(red: 0.933, green: 0.945, blue: 1.0)
    /// 浅紫底上的文字 #3C4DB5
    static let tintInk = Color(red: 0.235, green: 0.302, blue: 0.710)

    // 状态色（设计稿：文字 / 圆点两套）
    static let okText = Color(red: 0.224, green: 0.663, blue: 0.471)
    static let warnText = Color(red: 0.706, green: 0.482, blue: 0.145)
    static let badText = Color(red: 0.788, green: 0.341, blue: 0.384)
    static let dotOK = Color(red: 0.224, green: 0.788, blue: 0.541)
    static let dotWarn = Color(red: 0.953, green: 0.659, blue: 0.294)
    static let dotBad = Color(red: 0.890, green: 0.420, blue: 0.447)
}

// MARK: - 基础组件

struct HubCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HubInk.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(HubInk.line, lineWidth: 1))
    }
}

/// 紧凑的左对齐流式布局。LazyVGrid 会把每一列拉成等宽，模型少时会产生
/// “左边一个、右边一个、中间大片空白”的占位；模型标签应该按内容自然排列。
private struct HubFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + verticalSpacing
                x = 0
                rowHeight = 0
            }
            x += (x > 0 ? horizontalSpacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x)
        }
        return CGSize(width: proposal.width ?? usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + verticalSpacing
                x = bounds.minX
                rowHeight = 0
            }
            if x > bounds.minX { x += horizontalSpacing }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct HubDarkCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(HubInk.hero))
            .foregroundStyle(HubInk.onDark)
    }
}

struct HubTag: View {
    var text: String
    var tint: Color = HubInk.sub

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
            .foregroundStyle(tint)
    }
}

struct HubStatusTag: View {
    var ok: Bool?
    var latency: Int?
    var error: String
    /// 这次结论是怎么来的（`catalog` / `generation`）。空串按列表探测显示，不带尾巴。
    var method: String = ""
    /// 网关真实回执里的状态码（如 "HTTP 401"）。有就贴在「未连接」后面：
    /// 不用点开也知道是钥匙被拒、地址上没有这个模型，还是服务方在限流。
    var failureCode: String = ""

    private var label: String {
        switch ok {
        case .some(true):
            // 没有 /models 的接口是靠一次 1 token 生成探测定的「已连接」，这里说清楚，
            // 免得看的人以为是读到了列表。
            let base = latency.map { "已连接 · \($0) ms" } ?? "已连接"
            return method == "generation" ? base + " · 生成探测" : base
        case .some(false):
            return failureCode.isEmpty ? "未连接" : "未连接 · \(failureCode)"
        case .none: return "未检查"
        }
    }

    private var methodNote: String {
        switch method {
        case "generation": return "结论来自一次 1 token 生成探测：该接口不提供 GET /models"
        case "catalog": return "结论来自 GET /models 列表"
        default: return ""
        }
    }

    private var tint: Color {
        switch ok {
        case .some(true): return HubInk.green
        case .some(false): return HubInk.red
        case .none: return HubInk.faint
        }
    }

    private var hint: String {
        [methodNote, failureCode.isEmpty ? "" : "网关回执：\(failureCode)", error]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
        }
        .help(hint.isEmpty ? label : hint)
    }
}

struct HubPrimaryButton: View {
    var title: String
    var systemImage: String?
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubInk.hero))
            .foregroundStyle(HubInk.onDark)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

struct HubGhostButton: View {
    var title: String
    var systemImage: String?
    var tint: Color = HubInk.ink
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12.5, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(HubInk.line, lineWidth: 1))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

struct HubStatCard: View {
    var value: String
    var label: String
    var hint: String
    var width: CGFloat = 250

    var body: some View {
        // 设计稿顺序：小标签 → 大数字 → 底部提示；卡片默认 250 宽，但窄窗口时让出。
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 12)).foregroundStyle(HubInk.muted)
            Spacer(minLength: 2)
            Text(value)
                .font(.system(size: 30))
                .foregroundStyle(HubInk.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 2)
            Text(hint).font(.system(size: 11)).foregroundStyle(HubInk.hint).lineLimit(1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HubInk.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(HubInk.line, lineWidth: 1))
    }
}

/// 设计稿里的白色小按钮：34 高，圆角 9，浅描边。
struct HubWhiteButton: View {
    var title: String
    var width: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(HubInk.ink)
                .frame(width: width, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(HubInk.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// 设计稿里的主色实心按钮（「＋ 添加供应商」）。
struct HubAccentButton: View {
    var title: String
    var width: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: width, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubInk.accent))
        }
        .buttonStyle(.plain)
    }
}

/// 右上角 36×36 圆形图标按钮（EEF1FF 底 + 主色图标）。
struct HubCircleIconButton: View {
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(HubInk.accent)
                .frame(width: 36, height: 36)
                .background(Circle().fill(HubInk.tint))
        }
        .buttonStyle(.plain)
    }
}

struct HubPageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(HubInk.ink)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(HubInk.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

extension HubPageHeader where Trailing == EmptyView {
    /// 页头没有右侧操作时不必写空闭包。
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct HubKeyValue: View {
    var label: String
    var value: String
    var mono = true
    var tint: Color = HubInk.ink

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(HubInk.sub)
                .frame(width: 84, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 12, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundStyle(tint)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

struct HubDivider: View {
    var body: some View { Rectangle().fill(HubInk.line).frame(height: 1) }
}

// MARK: - 语音总览（原首页）状态桥

/// 语音面板只认识「状态 + 忙碌 + 最近一次对话」，这里原样转成 SwiftUI 的发布属性。
final class HubHomeBridge: ObservableObject {
    @Published var introText = "AI 中枢 · 语音与模型路由"
    @Published var status = "待机"
    @Published var detail = "麦克风默认关闭，随时可以开始说话。"
    @Published var tint = HubInk.sub
    @Published var busy = false
    @Published var lastQuestion = ""
    @Published var lastAnswer = ""
    @Published var lastRoute = ""
    @Published var focusToken = 0
    /// 流水线阶段 0…4（待机 / 聆听 / 转写 / 思考 / 播报），和对话页同一个 `pipelineStage`。
    @Published var stageIndex = 0
    /// 麦克风电平 0…1，只在实际录音时有意义；菜单栏面板拿它画电平条。
    @Published var level = 0.0

    var onAsk: ((String) -> Void)?
    var onToggleVoice: (() -> Void)?
    var onOpenPage: ((HubWindowController.Page) -> Void)?
    var onCancelVoice: (() -> Void)?
    var onCopyAnswer: (() -> Void)?
    var onReplayAnswer: (() -> Void)?
    var onRevealSupportDirectory: (() -> Void)?
    var onQuit: (() -> Void)?

    func apply(status: String, detail: String, tint: Color, busy: Bool) {
        self.status = status
        self.detail = detail
        self.tint = tint
        self.busy = busy
    }

    func setLastExchange(question: String, answer: String, route: String) {
        lastQuestion = question
        lastAnswer = answer
        lastRoute = route
    }
}

// MARK: - 总览（Lunacy：本地路由与 Agent 管理）

private struct HubDashboardAgent: Identifiable {
    let id: String
    let name: String
    let model: String
    let canAddModel: Bool
    /// 设计稿里每个 Agent 的图标字符与配色。
    let glyph: String
    let tint: Color
    let tintBG: Color
}

struct HubOverviewPage: View {
    @ObservedObject var bridge: HubHomeBridge
    @ObservedObject var model: HubModel
    @State private var liveRefresh = true
    @State private var addingSupplier = false
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// 设计稿尺寸：左列自适应、右列 308、列间距 36、页面左右留白 40。
    private let rightWidth: CGFloat = 308
    private let columnGap: CGFloat = 36

    /// 图标与配色按 id 认；认不出来的自定义客户端给一套中性色，不假装认得它。
    private static func style(for spec: HubClientSpec) -> (glyph: String, tint: Color, tintBG: Color) {
        switch spec.id {
        case "codex":
            return ("⌘", HubInk.accent, HubInk.tint)
        case "zcode":
            return ("Z", Color(red: 0.843, green: 0.565, blue: 0.200),
                    Color(red: 1.0, green: 0.949, blue: 0.875))
        case "claude":
            return ("C", HubInk.okText, Color(red: 0.914, green: 0.976, blue: 0.949))
        case "dsh":
            return ("D", Color(red: 0.506, green: 0.357, blue: 0.831),
                    Color(red: 0.945, green: 0.925, blue: 1.0))
        case "opencode":
            return ("O", Color(red: 0.129, green: 0.529, blue: 0.588),
                    Color(red: 0.898, green: 0.965, blue: 0.973))
        default:
            let initial = spec.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .first.map { String($0).uppercased() } ?? "·"
            return (initial, HubInk.sub, Color(red: 0.937, green: 0.945, blue: 0.965))
        }
    }

    /// 右列列的就是用户那份客户端清单（与 Agent 管理页同一个真源）：
    /// 加一个多一行，删一个少一行，两处不许各说各话。
    private var dashboardAgents: [HubDashboardAgent] {
        model.clientSpecs.map { spec in
            let file = HubAgentSync.detect(path: spec.path) ?? HubAgentSync.detect(agentName: spec.name)
            let plan = file.flatMap { try? HubAgentSync.plan(agentName: spec.name, fileURL: $0) }
            let current = plan?.currentModel
            let trimmed = current?.trimmingCharacters(in: .whitespaces)
            let real = (trimmed?.isEmpty == false) ? trimmed : nil
            let style = Self.style(for: spec)
            let configured = Set((plan?.configuredModels ?? []).map {
                $0.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })
            let visibleDefault = Set(model.defaultAllowedModels.map { $0.id })
            let canAddModel = !model.isReadOnlyMode && spec.editable && file != nil && model.poolModels.contains { entry in
                !visibleDefault.contains(entry.id)
                    && !configured.contains(entry.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            return HubDashboardAgent(
                id: spec.id,
                name: spec.name,
                model: (real == "dsh" ? "AI助手本地路由（Jev）" : real)
                    ?? (file == nil ? "未检测到配置" : "已配置但未读出模型"),
                canAddModel: canAddModel,
                glyph: style.glyph,
                tint: style.tint,
                tintBG: style.tintBG
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            // 统计卡：宽窗口一行四张，窄窗口折成两行两张。
            if model.viewportWidth >= 900 {
                HStack(spacing: 18) {
                    HubStatCard(value: "\(model.supplierGroups.count)", label: "已接入供应商", hint: "连接配置集中管理")
                    HubStatCard(value: "\(model.onlineSupplierCount) / \(model.supplierGroups.count)", label: "当前在线", hint: "按供应商探测 /models")
                    HubStatCard(value: "\(model.poolModels.count) / \(model.defaultAgentModelCount)", label: "模型池 / Agent", hint: "已接入 / 可执行模型")
                    HubStatCard(
                        value: model.averageLatencyMS.map { "\($0) ms" } ?? "—",
                        label: "平均延迟",
                        hint: model.checkedAt == "尚未检查" ? "最近一次探测" : "最近检查 \(model.checkedAt)"
                    )
                }
            } else {
                VStack(spacing: 18) {
                    HStack(spacing: 18) {
                        HubStatCard(value: "\(model.supplierGroups.count)", label: "已接入供应商", hint: "连接配置集中管理")
                        HubStatCard(value: "\(model.onlineSupplierCount) / \(model.supplierGroups.count)", label: "当前在线", hint: "按供应商探测 /models")
                    }
                    HStack(spacing: 18) {
                        HubStatCard(value: "\(model.poolModels.count) / \(model.defaultAgentModelCount)", label: "模型池 / Agent", hint: "已接入 / 可执行模型")
                        HubStatCard(
                            value: model.averageLatencyMS.map { "\($0) ms" } ?? "—",
                            label: "平均延迟",
                            hint: model.checkedAt == "尚未检查" ? "最近一次探测" : "最近检查 \(model.checkedAt)"
                        )
                    }
                }
            }

            // 两列并排需要「左列至少 520 + 间距 36 + 右列 308」。比这窄就上下堆叠，
            // 绝不靠把右列挤出窗口来硬撑并排 —— 那正是「UI 重叠 / 右侧被裁掉」的来源。
            if model.viewportWidth >= 520 + columnGap + rightWidth {
                HStack(alignment: .top, spacing: columnGap) {
                    leftColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    rightColumn
                        .frame(width: rightWidth, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    leftColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                    rightColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 26)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { model.refresh() }
        .onReceive(refreshTimer) { _ in
            guard liveRefresh else { return }
            model.refresh()
        }
        .sheet(isPresented: $addingSupplier) {
            HubConnectionEditor(model: model, draft: HubConnectionDraft())
        }
    }

    // MARK: 顶部标题

    private var header: some View {
        // 窄窗口时标题和按钮竖着排，避免「自动刷新 / 刷新数据 / 齿轮」把标题挤没。
        //
        // 这里不能用 ViewThatFits：宿主用 `host.fittingSize` 反推内容宽度，而
        // fittingSize 是按「理想宽度」量出来的，ViewThatFits 于是在任何宽度都判定
        // 第一分支放得下 —— 内容被撑到 778pt 塞进 676pt 的视口，右侧按钮直接跑到
        // 窗口外。改成和页面其它区块一样，用视口宽度决定。
        return Group {
            if model.viewportWidth >= 840 {
                HStack(alignment: .top, spacing: 20) {
                    headerTitle
                    Spacer(minLength: 12)
                    headerActions
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    headerTitle
                    headerActions
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("本地路由与 Agent 管理")
                .font(.system(size: 26))
                .foregroundStyle(HubInk.ink)
            Text("供应商只配置一次，模型从模型池加入不同 Agent；URL、Key 与健康状态统一同步。")
                .font(.system(size: 13))
                .foregroundStyle(HubInk.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 10) {
            Button {
                liveRefresh.toggle()
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(liveRefresh ? HubInk.dotOK : HubInk.faint).frame(width: 7, height: 7)
                    Text(liveRefresh ? "自动刷新" : "手动刷新")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(liveRefresh ? HubInk.okText : HubInk.sub)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubInk.card))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(HubInk.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("每 30 秒重新读取 router.json、health.json 和 stats.json")
            HubWhiteButton(title: "刷新数据", width: 108) { model.refresh() }
            HubCircleIconButton(systemImage: "gearshape") { model.onOpenPage?(.status) }
        }
        .padding(.top, 4)
    }

    private func sectionHeader(title: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 17)).foregroundStyle(HubInk.ink)
            Text(desc).font(.system(size: 12)).foregroundStyle(HubInk.muted)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(HubInk.card)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(HubInk.line, lineWidth: 1))
    }

    // MARK: 左列

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "供应商模型库", desc: "添加 URL 后拉取模型；只勾选常用模型进入本地路由池。")
            Spacer().frame(height: 18)
            supplierCard
            Spacer().frame(height: 14)
            HStack(spacing: 12) {
                // 按钮写着「添加供应商」就直接开添加表单，而不是先跳页再让人自己找按钮。
                HubAccentButton(title: "＋ 添加供应商", width: 148) { addingSupplier = true }
                HubWhiteButton(title: "测速全部", width: 112) { model.probeAll() }
                HubWhiteButton(title: "打开高级面板", width: 132) { model.presentLegacyRouterPanel?() }
            }
            Spacer().frame(height: 44)
            sectionHeader(
                title: "路由说明",
                desc: "健康探测只请求 /models，不发送生成请求。供应商设置保存后，所有 Agent 引用自动同步。"
            )
            Spacer().frame(height: 18)
            permissionHint
        }
    }

    /// 权限说明卡。名字从 `noticeBanner` 改过来：它不是「刚才发生了什么」的提示条
    ///（那种提示现在统一由窗口顶部的横幅负责），而是一段固定说明。
    private var permissionHint: some View {
        HStack(spacing: 12) {
            Circle().fill(HubInk.accent).frame(width: 16, height: 16)
            Text("关闭窗口不会退出 AI助手；语音入口默认关闭，点击“开始说话”才申请麦克风权限。")
                .font(.system(size: 12))
                .foregroundStyle(HubInk.tintInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HubInk.tint))
    }

    private var supplierCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            supplierBand
            Spacer().frame(height: 10)
            ForEach(Array(model.supplierGroups.prefix(5))) { group in
                supplierRow(group)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var supplierBand: some View {
        HStack(spacing: 0) {
            Text("供应商").frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            Text("模型数").frame(width: 92, alignment: .leading)
            Text("状态").frame(width: 82, alignment: .leading)
            Text("延迟").frame(width: 78, alignment: .leading)
        }
        .font(.system(size: 11))
        .foregroundStyle(HubInk.tableHead)
        .padding(.horizontal, 20)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HubInk.band))
    }

    private func supplierRow(_ group: HubModel.SupplierGroup) -> some View {
        let status = statusStyle(group)
        return VStack(spacing: 0) {
            Rectangle().fill(HubInk.line).frame(height: 1)
            HStack(spacing: 0) {
                Circle().fill(status.dot).frame(width: 12, height: 12)
                Spacer().frame(width: 11)
                Text(group.name)
                    .font(.system(size: 12))
                    .foregroundStyle(HubInk.ink)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                Text("\(group.modelCount) 个模型")
                    .font(.system(size: 12))
                    .foregroundStyle(HubInk.ink)
                    .frame(width: 92, alignment: .leading)
                Text(status.text)
                    .font(.system(size: 12))
                    .foregroundStyle(status.color)
                    .frame(width: 82, alignment: .leading)
                Text(group.latencyMS.map { "\($0) ms" } ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(HubInk.ink)
                    .frame(width: 78, alignment: .leading)
            }
            .padding(.leading, 15)
            .padding(.trailing, 16)
            .frame(height: 42)
        }
    }

    private func statusStyle(_ group: HubModel.SupplierGroup) -> (text: String, color: Color, dot: Color) {
        if group.onlineCount == group.connections.count { return ("已连接", HubInk.okText, HubInk.dotOK) }
        if group.onlineCount > 0 { return ("部分可用", HubInk.warnText, HubInk.dotWarn) }
        if group.uncheckedCount == group.connections.count { return ("待测速", HubInk.warnText, HubInk.dotWarn) }
        return ("不可用", HubInk.badText, HubInk.dotBad)
    }

    // MARK: 右列

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title: "Agent 管理", desc: "检测真实配置文件；点击 ＋ 从左侧模型池添加。")
            Spacer().frame(height: 18)
            agentCard
            Spacer().frame(height: 18)
            jevPanel
        }
    }

    private var agentCard: some View {
        VStack(spacing: 10) {
            ForEach(dashboardAgents) { agent in
                agentRow(agent)
            }
        }
        .padding(16)
        .frame(width: rightWidth, alignment: .leading)
        .background(cardBackground)
    }

    private func agentRow(_ agent: HubDashboardAgent) -> some View {
        HStack(spacing: 9) {
            Text(agent.glyph)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(agent.tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(agent.tintBG))
            VStack(alignment: .leading, spacing: 5) {
                Text(agent.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(HubInk.ink)
                Text("当前：\(agent.model)")
                    .font(.system(size: 12))
                    .foregroundStyle(HubInk.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if agent.canAddModel {
                Button { model.onOpenPage?(.agents) } label: {
                    Text("＋")
                        .font(.system(size: 19))
                        .foregroundStyle(Color.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(HubInk.accent))
                }
                .buttonStyle(.plain)
            } else {
                Label("已全部添加", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(HubInk.green)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 62)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HubInk.band))
    }

    private var jevPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Jev 档位模型")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(HubInk.ink)
            Text("Luna · Terra · Sol · Astra")
                .font(.system(size: 11))
                .foregroundStyle(HubInk.muted)
                .padding(.top, 10)
            Button { model.onOpenPage?(.jev) } label: {
                Text("统一从本地模型池选择 →")
                    .font(.system(size: 12))
                    .foregroundStyle(HubInk.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 17)
        .padding(.bottom, 18)
        .frame(width: rightWidth, alignment: .leading)
        .background(cardBackground)
    }
}


// MARK: - 本地路由

struct HubRouterPage: View {
    @ObservedObject var model: HubModel
    @State private var editing: HubConnectionDraft?
    /// 展开的供应商。默认全部收起：先看供应商全貌，再点开看模型。
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            routerHeader

            if model.connections.isEmpty {
                HubCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有供应商线路").font(.system(size: 13, weight: .semibold)).foregroundStyle(HubInk.ink)
                        Text("先加一条本地或云端线路，再从它的模型清单里挑模型进池子。")
                            .font(.system(size: 12)).foregroundStyle(HubInk.sub)
                    }
                }
            } else {
                let displayCards = model.flatDisplayCardIDs()
                ForEach(model.supplierGroups) { group in
                    HubSupplierGroupRow(
                        model: model,
                        group: group,
                        isDisplayOnlyCard: displayCards.contains(group.id),
                        isExpanded: expanded.contains(group.id),
                        onToggle: {
                            if expanded.contains(group.id) { expanded.remove(group.id) }
                            else { expanded.insert(group.id) }
                        },
                        onEdit: { connection in
                            editing = HubConnectionDraft(connection: connection)
                        }
                    )
                }
            }

            // ③ 台账放在供应商列表下面：先看正常线路，再看「没进池的那些行」到底怎么回事。
            HubRouteLedgerSection(model: model)

            Text("说明：供应商发现到的模型只有加入模型池后，Agent 线路才能引用；客户端当前模型和 Agent 线路请到「Agent 管理」查看。")
                .font(.system(size: 11)).foregroundStyle(HubInk.faint)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 26)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { model.refresh() }
        .sheet(item: $editing) { draft in
            HubConnectionEditor(model: model, draft: draft)
        }
    }

    private var routerHeader: some View {
        let actions = HStack(spacing: 8) {
            HubGhostButton(title: expanded.isEmpty ? "展开全部" : "收起全部",
                           systemImage: expanded.isEmpty ? "chevron.down" : "chevron.up") {
                if expanded.isEmpty {
                    expanded = Set(model.supplierGroups.map { $0.id })
                } else {
                    expanded.removeAll()
                }
            }
            HubGhostButton(title: "探测全部", systemImage: "dot.radiowaves.left.and.right") {
                model.probeAll()
            }
            HubPrimaryButton(title: "添加供应商", systemImage: "plus") {
                editing = HubConnectionDraft()
            }
        }

        return Group {
            if model.viewportWidth > 0, model.viewportWidth < 820 {
                VStack(alignment: .leading, spacing: 10) {
                    HubPageHeader(title: "本地路由", subtitle: routerSubtitle)
                    actions
                }
            } else {
                HubPageHeader(title: "本地路由", subtitle: routerSubtitle, trailing: { actions })
            }
        }
        // Keep the page title clear of the host scroll view's top clip when a
        // previous expanded page left a non-zero document offset.
        .padding(.top, 12)
    }

    /// 表头就把 ① 和 ③ 的账对好：这三个数字应该是同一批行，对不上要说清去哪看。
    private var routerSubtitle: String {
        let check = model.poolReconciliation()
        var lines = ["这里只管理供应商和全局模型池，不展示 Codex / ZCode 当前模型。",
                     "按供应商分组：\(model.supplierGroups.count) 个供应商 · 模型池 \(model.poolModels.count) 个 · default Agent 可执行 \(model.defaultAgentModelCount) 个"
                     + (model.defaultAgentBridgeCount > 0 ? " + \(model.defaultAgentBridgeCount) 个执行桥" : "")
                     + (check.isConsistent ? " = ③ 池内 \(check.ledgerRowCount) 行，逐条对账一致。"
                                           : "；③ 池内 \(check.ledgerRowCount) 行，两边对不上，差的在哪几行写在 ③ 里。")]
        let displayCards = model.flatDisplayCardIDs()
        if !displayCards.isEmpty {
            lines.append("② 上的 \(model.connections.count) 张卡 = router.json 的 connections \(model.routerConnectionCardCount) 条"
                         + " + 显示卡 \(displayCards.count) 张。"
                         + "显示卡在 router.json 的 connections 里没有它：是网关给没写 connection_id 的旧线路临时投影出来的，"
                         + "在 ③ 点「收编」就会变成一条真连接。")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - ③ 线路台账

/// 「③ 线路台账」：把 router.json 里的每一行摆到台面上，并给出能一键做的两件事（收编 / 还原）。
///
/// 这里的每个数字都来自 `HubModel.auditRouteLines` 对真实配置的逐行审计：
/// 没进池的行照样列出来，并写清它为什么没进池；能不能收编、收编会动几条，都先算好再显示。
/// 按钮上的条数就是真实会处理的条数（`planAdoption` 的预览），不写“点击试试”。
///
/// 版式按「先结论、再证据」排：
///   1. 第一行三个标签回答“一共什么状态”：池内 N / 需处理 M / 其他 K；
///   2. 第二行把每个标签拆开（其他 10 = 内部线路 3 · Agent 侧 5 · 非模型行 2），
///      数字不再只藏在悬停提示里；
///   3. 需要动手的分组默认展开（问题优先），不用动手的「其他」默认收起、点标签或标题都能展开；
///   4. ① 模型池和 ③ 池内行逐条对账，对不上就标红并写出差在哪几行。
struct HubRouteLedgerSection: View {
    @ObservedObject var model: HubModel
    @State private var showPooled = false
    @State private var showOthers = false
    @State private var result = ""
    @State private var confirming: HubModel.AdoptionSelection?
    @State private var confirmingSummary = ""
    @State private var confirmingRepair = false

    private var lines: [HubModel.RouteLine] { model.routeLines }
    private var pooledLines: [HubModel.RouteLine] { lines.filter { $0.state == .pooled } }

    /// ① 模型池里的行和 ③ 池内行是不是同一批。两处数字对不上时，下面那行会标红并写出差在哪。
    private var poolCheck: HubPoolReconciliation { model.poolReconciliation() }

    // 状态口径只有一个来源：HubModel 给每行分好的 RouteLine.state。有现成入口的（可收编 / Agent 侧 /
    // 已归属未进池 / 内部线路 / 引用缺口）直接读入口，页面不自己再判一遍；加总那行会跟入口逐个对账。
    private var adoptableLines: [HubModel.RouteLine] { model.adoptableLines }
    private var unpooledLines: [HubModel.RouteLine] { model.boundNotPooledLines }
    private var danglingLines: [HubModel.RouteLine] { model.danglingLines }
    private var agentSideLines: [HubModel.RouteLine] { model.agentSideLines }
    private var internalLines: [HubModel.RouteLine] { model.internalLines }
    private var notModelLines: [HubModel.RouteLine] { lines.filter { $0.state == .notModel } }
    private var addressFixCount: Int { model.addressRepair.connections.count + model.addressRepair.lines.count }

    /// 发不出去 = 这一行和它的归属连接都没写地址（HubModel 的地址口径）。这条按地址筛、不按状态：
    /// 命中的行状态各不相同，所以它只说清「缺什么」，不占状态加总里的某一类。
    private var unreachableLines: [HubModel.RouteLine] { model.linesWithoutAddress }
    private var unreachableIDs: Set<String> { Set(unreachableLines.map(\.id)) }

    /// 其他：按规则排除、不用动手的三类状态（Agent 侧 / 内部线路 / 非模型行）。
    private var otherLines: [HubModel.RouteLine] {
        lines.filter { [.agentSide, .internalLine, .notModel].contains($0.state) }
    }
    /// 那三类里没写地址的行已经在「发不出去」那组列过，这里跳过，免得同一行出现两次。
    private func otherRows(_ state: HubModel.RouteLineState) -> [HubModel.RouteLine] {
        lines.filter { $0.state == state && !unreachableIDs.contains($0.id) }
    }
    private var otherBreakdown: [(String, Int)] {
        [("Agent 侧", agentSideLines.count),
         ("内部线路", internalLines.count),
         ("非模型行", notModelLines.count)]
            .filter { $0.1 > 0 }
    }

    /// 需处理 = 三类状态缺口（可收编 / 已归属未进池 / 引用缺口）+ 两条地址口径（发不出去 / 地址要修）。
    /// 地址那两条可能落在任何状态里，所以这栏是「要动手的量」，不等于加总里的某一类。
    private var problemCount: Int {
        adoptableLines.count + unpooledLines.count + danglingLines.count + unreachableLines.count + addressFixCount
    }

    /// 加总的账：拿 HubModel 分好的 7 个状态当账，每行只算一类，加起来必须正好等于行数。
    private var stateBuckets: [(HubModel.RouteLineState, Int)] {
        [(.pooled, pooledLines.count),
         (.adoptable, adoptableLines.count),
         (.boundNotPooled, unpooledLines.count),
         (.danglingReference, danglingLines.count),
         (.internalLine, internalLines.count),
         (.agentSide, agentSideLines.count),
         (.notModel, notModelLines.count)]
    }
    private var stateSum: Int { stateBuckets.reduce(0) { $0 + $1.1 } }
    private var sumCheckOK: Bool { stateSum == lines.count }
    private var sumCheckText: String {
        "\(lines.count) 行 = " + stateBuckets.map { "\($0.0.title) \($0.1)" }.joined(separator: " + ")
    }
    private var sumCheckSuffix: String {
        guard !sumCheckOK else { return " ✓ 加总对得上" }
        return "（加起来 \(stateSum) 行，和台账的 \(lines.count) 行差 \(abs(lines.count - stateSum)) 行：有行漏判或多判了）"
    }
    /// 页面自己按 state 数的数，跟 HubModel 那几组入口必须一模一样；对不上就写清差在哪一类。
    private var stateSourceMismatch: String? {
        let pairs: [(String, Int, Int)] = [
            ("可收编", adoptableLines.count, lines.filter { $0.state == .adoptable }.count),
            ("已归属未进池", unpooledLines.count, lines.filter { $0.state == .boundNotPooled }.count),
            ("引用缺口", danglingLines.count, lines.filter { $0.state == .danglingReference }.count),
            ("Agent 侧", agentSideLines.count, lines.filter { $0.state == .agentSide }.count),
            ("内部线路", internalLines.count, lines.filter { $0.state == .internalLine }.count)]
        let bad = pairs.filter { $0.1 != $0.2 }
        guard !bad.isEmpty else { return nil }
        return bad.map { "\($0.0)：HubModel 入口 \($0.1) 条，页面按 state 数 \($0.2) 条" }.joined(separator: "；")
    }
    /// 「发不出去」「地址要修」按地址筛、不按状态，所以不并进上面那条加总；为 0 时也交代一句。
    private var crossCutNote: String {
        var parts: [String] = []
        if !unreachableLines.isEmpty { parts.append("两处都没写地址、发不出去 \(unreachableLines.count) 条") }
        if addressFixCount > 0 { parts.append("地址要修 \(addressFixCount) 处（\(model.addressRepair.defectSummary)）") }
        if parts.isEmpty {
            return "另有两条地址口径「发不出去」「地址要修」现在都是 0：它们按地址筛、可能落在上面任何一类里，所以不并进加总。"
        }
        return "另有两条地址口径（不并进加总，命中的行可能落在上面任何一类里）：" + parts.joined(separator: " · ") + "。"
    }

    /// 可收编 0 条不是「没内容」：说清空的是哪一类、为什么空、剩下的都去哪儿了。
    private var adoptCompletion: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(HubInk.green)
            Text(adoptCompletionText)
                .font(.system(size: 12)).foregroundStyle(HubInk.sub)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .help("「可收编」按状态算、不按地址算：空 = 没有『有模型名和地址、只差一个连接归属』的行。")
    }

    private var adoptCompletionText: String {
        var text = "可收编 0 条：没有「有模型名和地址、只差一个连接归属」的线路，这一类已经收干净了。"
        text += "剩下的 \(lines.count) 行都有去处：池内 \(pooledLines.count) 行 Agent 和 JEV 档位能直接引用"
        text += " · 内部线路 \(internalLines.count) 行只从 JEV 档位进池（要另收编得再确认一次）"
        text += " · Agent 侧 \(agentSideLines.count) 行按规则排除、默认收起"
        if !notModelLines.isEmpty {
            text += " · 非模型行 \(notModelLines.count) 条是没模型名的配置行（桥接、命令这类）"
        }
        var todo: [String] = []
        if !unpooledLines.isEmpty { todo.append("已归属未进池 \(unpooledLines.count) 条") }
        if !danglingLines.isEmpty { todo.append("引用缺口 \(danglingLines.count) 条") }
        if !unreachableLines.isEmpty { todo.append("没写地址、发不出去 \(unreachableLines.count) 条") }
        if addressFixCount > 0 { todo.append("地址要修 \(addressFixCount) 处") }
        text += todo.isEmpty ? "；没有别的要动手的线路。" : "。另外还有要动手的：" + todo.joined(separator: " · ") + "。"
        return text
    }

    var body: some View {
        HubCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                ledgerFirstLine
                headlineCounters
                breakdown
                if !lines.isEmpty && adoptableLines.isEmpty { adoptCompletion }
                reconciliation
                howToRead
                buttons
                if !result.isEmpty {
                    Text(result).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HubInk.tintInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.lastBackupPath.isEmpty {
                    Text("备份：\((model.lastBackupPath as NSString).lastPathComponent)")
                        .font(.system(size: 11)).foregroundStyle(HubInk.hint)
                        .help(model.lastBackupPath)
                }
                if !lines.isEmpty { evidence }
            }
        }
        .confirmationDialog(
            "确认收编范围？",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button("收编") {
                if let selection = confirming { result = model.adoptUnassignedLines(selection) }
                confirming = nil
            }
            Button("取消", role: .cancel) { confirming = nil }
        } message: {
            Text(confirmingSummary)
        }
    }

    /// ③ 卡第一句：①②③④ 各数什么、为什么不相等、差在哪儿 —— 先用一句话交代清楚。
    private var ledgerFirstLine: some View {
        Text("① 数的是模型池里的模型（一个模型一行）；② 数的是供应商连接；③ 和右边的行数数的是 router.json 里的配置行，"
             + "一行只落进一个状态，所以三个数加起来正好是行数；④ 是 Agent 的引用，按 Agent 数。"
             + "这四个数本来就不是一套账：行进了池才会同时出现在 ① 和 ③，③ 的「可收编 / 缺口」在 ① 里看不见，"
             + "① 里也可能有 ③ 没有对应行的模型（连接自带）。"
             + "所以下面这些数字不必互相对得上，差在哪儿点开 ③ 的池内清单，一行比一行。")
            .font(.system(size: 12)).foregroundStyle(HubInk.sub)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 标题

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("③ 线路台账").font(.system(size: 15, weight: .semibold)).foregroundStyle(HubInk.ink)
            Text("router.json 的每一行都在这儿，一行不落；每行只落进一个状态")
                .font(.system(size: 12)).foregroundStyle(HubInk.muted)
            Spacer(minLength: 0)
        }
    }

    /// 第一行三个大标签：一眼看出池内多少、要动手多少、其余多少。
    private var headlineCounters: some View {
        HStack(spacing: 8) {
            HubCountChip(value: pooledLines.count, label: "池内",
                         tint: HubInk.green,
                         hint: "③ 的池内行 = ① 模型池的本体：Agent 和 JEV 档位能直接引用。点一下就地展开，带归属、谁在用、通不通。",
                         action: { showPooled.toggle() })
            HubCountChip(value: problemCount, label: "需处理",
                         tint: problemCount == 0 ? HubInk.sub : HubInk.orange,
                         hint: problemCount == 0 ? zeroProblemHelp : problemHelp,
                         action: nil)
            HubCountChip(value: otherLines.count, label: "其他",
                         tint: HubInk.sub,
                         hint: otherLines.isEmpty ? "没有按规则排除的行。" : "不是缺口、被规则排除的行（Agent 侧、4202 内部线路、非模型行），默认收起，不进模型池也不会被收编。点一下展开。",
                         action: { showOthers.toggle() })
            Spacer(minLength: 0)
        }
    }

    /// 第二行是算出来的加总：7 类互斥状态（名字直接读 HubModel 的 state.title）加起来必须正好等于行数。
    /// 页面不写死任何数字；对不上就把差数标红摆出来，省得两套算法各说各话。
    private var breakdown: some View {
        let ok = sumCheckOK && stateSourceMismatch == nil
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: ok ? "equal.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(ok ? HubInk.green : HubInk.red)
                Text(sumCheckText + sumCheckSuffix)
                    .font(.system(size: 12, weight: ok ? .regular : .semibold))
                    .foregroundStyle(ok ? HubInk.sub : HubInk.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .help("7 类互斥状态各多少，加起来就是 router.json 的行数。这行是算出来的，不是写死的。")
            Text("口径：池内＝已进模型池、能被直接引用；可收编＝有模型名和地址、只差一个连接归属；内部线路＝4202 内部那批，只从 JEV 档位进池；Agent 侧＝自带来源、收编要另建连接；非模型行＝没有模型名的配置行。")
                .font(.system(size: 12)).foregroundStyle(HubInk.sub)
                .fixedSize(horizontal: false, vertical: true)
            Text(crossCutNote)
                .font(.system(size: 12))
                .foregroundStyle(addressFixCount > 0 || !unreachableLines.isEmpty ? HubInk.orange : HubInk.sub)
                .fixedSize(horizontal: false, vertical: true)
            if let mismatch = stateSourceMismatch {
                Text("口径对不上：\(mismatch)。加总读 HubModel 的入口，页面按 state 数，两处必须一样。")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(HubInk.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// ① 模型池 ↔ ③ 池内行对账。对得上说得清，对不上直接标红说明差在哪几行。
    private var reconciliation: some View {
        let check = poolCheck
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: check.isConsistent ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(check.isConsistent ? HubInk.green : HubInk.red)
            Text(check.summary)
                .font(.system(size: 12, weight: check.isConsistent ? .medium : .semibold))
                .foregroundStyle(check.isConsistent ? HubInk.sub : HubInk.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .help(check.detail)
    }

    /// 这栏怎么读：一句话 + 两行要点，字号抬到 12，不再用小灰字一整段。
    private var howToRead: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("这一栏怎么用")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(HubInk.ink)
            Text("· 每个数字都读自 router.json 的每一行，每行只落进一个状态；加总那行是 7 类互斥状态相加，必须正好等于行数，对不上会标红写出差多少。① 模型池只显示能用的行，③ 连没进池的行一起列出来。")
                .font(.system(size: 12)).foregroundStyle(HubInk.sub)
            Text("· 「需处理」= 三类状态缺口（可收编 / 已归属未进池 / 引用缺口）+ 两条地址口径（发不出去 / 地址要修）；地址那两条按地址筛、可能落在任何一类里，所以跟加总不是一套账。")
                .font(.system(size: 12)).foregroundStyle(HubInk.sub)
            Text("· 收编 = 给没归属的模型线路补一条供应商连接（地址、密钥、模型名原样搬过去）；还原 = 只拆掉 App 收编建的连接，线路行和密钥都留着。写盘前自动备份。")
                .font(.system(size: 12)).foregroundStyle(HubInk.sub)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var otherBreakdownText: String {
        otherBreakdown.map { "\($0.0) \($0.1) 条" }.joined(separator: " · ")
    }

    private var problemHelp: String {
        var parts: [String] = []
        if !adoptableLines.isEmpty { parts.append("可收编 \(adoptableLines.count) 条：有模型名和地址、只差一个连接归属") }
        if !unpooledLines.isEmpty { parts.append("已归属未进池 \(unpooledLines.count) 条：有归属连接但这一行自己没进池") }
        if !danglingLines.isEmpty { parts.append("引用缺口 \(danglingLines.count) 条：写着的连接在 connections 里找不到") }
        if !unreachableLines.isEmpty { parts.append("发不出去 \(unreachableLines.count) 条：这一行和它的连接都没写地址") }
        if addressFixCount > 0 { parts.append("地址要修 \(addressFixCount) 处：\(model.addressRepair.summary)") }
        return parts.joined(separator: "；")
            + "。下面需要动手的分组已经默认展开；「发不出去」「地址要修」按地址筛、可能落在任何一类里，所以不并进加总。"
    }

    /// 「需处理 0」时也给一句话交代口径，别让这栏空着。
    private var zeroProblemHelp: String {
        "可收编、已归属未进池、引用缺口三类都空，地址也没有要修的：线路这边没有要动手的地方。"
    }

    // MARK: 按钮（每条都写清会动几条、动哪个文件）

    private var buttons: some View {
        let adoptablePlan = model.planAdoption()
        let internalPlan = model.planAdoption(.init(includeInternal: true))
        let allPlan = model.planAdoption(.init(includeAgentSide: true, includeInternal: true))
        return HStack(spacing: 8) {
            if !adoptablePlan.isEmpty {
                HubPrimaryButton(title: "收编可收编的 \(adoptablePlan.lineCount) 条",
                                 systemImage: "arrow.down.to.line") {
                    run(.init())
                }
                .help(adoptHelp(adoptablePlan, extra: ""))
            }
            if !internalPlan.isEmpty {
                HubGhostButton(title: "含内部线路 \(internalPlan.lineCount) 条",
                               systemImage: "arrow.triangle.merge") {
                    ask(.init(includeInternal: true),
                        summary: "范围：\(internalPlan.summary)\n会新建 \(internalPlan.connections.count) 条供应商连接、归属 \(internalPlan.lineCount) 条线路。\n"
                               + "4202 内部线路是你自己那台机器上的线路，收编只是把它在 ① 里单独列出来，不改它的地址。"
                               + skipNote(internalPlan))
                }
                .help(adoptHelp(internalPlan, extra: "4202 内部线路只加一条连接归属，地址不改。"))
            }
            if !allPlan.isEmpty {
                HubGhostButton(title: "全部收编 \(allPlan.lineCount) 条",
                               systemImage: "square.stack.3d.up") {
                    ask(.init(includeAgentSide: true, includeInternal: true),
                        summary: "范围：\(allPlan.summary)\n会新建 \(allPlan.connections.count) 条供应商连接、归属 \(allPlan.lineCount) 条线路。\n"
                               + "Agent 侧的行会按来源或域名命名成新连接。"
                               + skipNote(allPlan))
                }
                .help(adoptHelp(allPlan, extra: "Agent 侧的行按来源或域名命名成新连接。"))
            }
            if !model.adoptedConnectionIDs.isEmpty {
                HubGhostButton(title: "还原收编（\(model.adoptedConnectionIDs.count) 个连接）",
                               systemImage: "arrow.uturn.backward") {
                    result = model.restoreAdoptedLines()
                }
                .help("会拆掉 App 收编建的 \(model.adoptedConnectionIDs.count) 条连接，"
                      + "线路行和密钥都保留，随时能再收编。\n"
                      + "改动文件：router.json（写前自动备份）＋ 收编台账 router-adoptions.json。")
            }
            if !model.addressRepair.isEmpty {
                HubGhostButton(title: "修地址（\(model.addressRepair.summary)）",
                               systemImage: "bandage") {
                    confirmingRepair = true
                }
                .help("会修 \(addressFixCount) 处（\(model.addressRepair.summary)）："
                      + "把地址收成网关真正会用的那一条，URL 本体不改写、也不猜。\n"
                      + "改动文件：router.json（写前自动备份）。")
                .confirmationDialog("确认修地址？", isPresented: $confirmingRepair, titleVisibility: .visible) {
                    Button("修地址") { result = model.repairAddresses() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(repairSummary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 悬停就把「动几条连接、动几条线路、动哪个文件」说完，不让按钮变成盲盒。
    private func adoptHelp(_ plan: HubModel.AdoptionPlan, extra: String) -> String {
        var lines = ["会新建 \(plan.connections.count) 条供应商连接、给 \(plan.lineCount) 条线路补上连接归属。",
                     "范围：\(plan.summary)。"]
        if !plan.notes.isEmpty { lines.append(plan.notes + "。") }
        if !extra.isEmpty { lines.append(extra) }
        lines.append("地址、密钥、模型名原样搬过去，不改值。")
        lines.append("改动文件：router.json（写前自动备份）＋ 收编台账 router-adoptions.json。")
        return lines.joined(separator: "\n")
    }

    /// 修地址前把「改哪几处、收成什么」一句句摆出来，不让人盲点。
    private var repairSummary: String {
        let repair = model.addressRepair
        var lines = ["要修 \(repair.summary)：把地址收成网关真正会用的那一条，URL 本体不改写、也不猜。"]
        lines.append("毛病是：" + repair.defectSummary + "。")
        for fix in repair.connections.prefix(4) {
            lines.append("连接「\(fix.name)」→ \(HubModel.cleanedAddress(fix.from))")
        }
        for fix in repair.lines.prefix(4) {
            lines.append("线路「\(fix.id)」→ \(HubModel.cleanedAddress(fix.from))")
        }
        if repair.connections.count + repair.lines.count > 8 { lines.append("……其余同类项一起改。") }
        lines.append("写盘前自动备份。")
        return lines.joined(separator: "\n")
    }

    // MARK: 证据（逐行）

    @ViewBuilder
    private var evidence: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(HubInk.line).frame(height: 1)
            if problemCount > 0 { problemSections }
            pooledSection
            othersSection
            if !lines.isEmpty && pooledLines.count == lines.count {
                Text("\(lines.count) 行全在池里：没有可收编的、没有缺口、没有按规则排除的行。")
                    .font(.system(size: 12)).foregroundStyle(HubInk.green)
            }
        }
    }

    /// 需处理的分组默认展开：打开页面就能看到要动手的那些行。
    @ViewBuilder
    private var problemSections: some View {
        if !adoptableLines.isEmpty {
            stateGroup(.adoptable, lines: adoptableLines,
                       note: "有模型名和地址、只差一个连接归属。点上面的「收编」按地址和来源给它们建新连接。")
        }
        if !unpooledLines.isEmpty {
            stateGroup(.boundNotPooled, lines: unpooledLines,
                       note: "有归属连接、但这一行自己没进模型池。检查这行的开关，或等模型池刷新。")
        }
        if !danglingLines.isEmpty {
            stateGroup(.danglingReference, lines: danglingLines,
                       note: "这些行写着的连接在 connections 里找不到，网关不会拿它们进池。")
        }
        if !unreachableLines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                stateHeader("发不出去", count: unreachableLines.count, tint: HubInk.orange)
                Text("按地址口径筛的：这一行和它的归属连接都没写地址（只打空格也算没写），网关发不出去。先补地址，收编救不了它。"
                     + "\n这条不按状态分 —— 命中的行状态各不相同（下面每行的标签就是它自己的状态），所以它不占加总里的某一类。")
                    .font(.system(size: 12)).foregroundStyle(HubInk.sub)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(unreachableLines) { line in
                    lineRow(line)
                }
            }
        }
        if addressFixCount > 0 {
            VStack(alignment: .leading, spacing: 6) {
                stateHeader("地址要修", count: addressFixCount, tint: HubInk.orange)
                Text("毛病是：\(model.addressRepair.defectSummary)。点上面的「修地址」把地址收成网关真正会用的那一条。")
                    .font(.system(size: 12)).foregroundStyle(HubInk.sub)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.addressRepair.connections.prefix(4), id: \.name) { fix in
                    fixRow(label: "连接「\(fix.name)」", from: fix.from)
                }
                ForEach(model.addressRepair.lines.prefix(4), id: \.id) { fix in
                    fixRow(label: "线路「\(fix.id)」", from: fix.from)
                }
            }
        }
    }

    private func fixRow(label: String, from: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            HubTag(text: "地址要修", tint: HubInk.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(HubInk.ink)
                Text(HubModel.cleanedAddress(from))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(HubInk.sub)
                    .lineLimit(1).truncationMode(.middle)
                    .help("原文：\(from)")
            }
            Spacer(minLength: 0)
        }
    }

    /// 池内行就地展开：不用回 ① 找，模型名、归属、谁在用、通不通都在这行上。
    private var pooledSection: some View {
        DisclosureGroup(isExpanded: $showPooled) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer(minLength: 0)
                    HubGhostButton(title: "收起池内", systemImage: "chevron.up") {
                        showPooled = false
                    }
                }
                Text("和 ① 模型池里是同一批行；这里多给两样：谁在用、通不通。")
                    .font(.system(size: 11)).foregroundStyle(HubInk.hint)
                ForEach(pooledLines) { line in
                    pooledRow(line)
                }
                HStack {
                    Spacer(minLength: 0)
                    HubGhostButton(title: "收起池内", systemImage: "chevron.up") {
                        showPooled = false
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                HubTag(text: "池内", tint: HubInk.green)
                Text("\(pooledLines.count) 行在模型池里")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(HubInk.ink)
                Spacer(minLength: 0)
            }
        }
    }

    private func pooledRow(_ line: HubModel.RouteLine) -> some View {
        let users = model.agentsUsing(providerID: line.id)
        let tierNames = model.tiers.filter { $0.value == line.id }.map { $0.key }.sorted()
        let healthID = line.connectionID.isEmpty ? line.id : line.connectionID
        let health = model.connections.first { $0.id == healthID }
        let owner = line.ownerName.isEmpty
            ? (line.connectionID.isEmpty ? "本机线路（没有连接归属）" : line.connectionID)
            : line.ownerName
        let modelName = line.model.isEmpty ? line.displayName : line.model
        return HStack(alignment: .top, spacing: 8) {
            HubTag(text: "池内", tint: HubInk.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(modelName).font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(HubInk.ink)
                Text("归属：\(owner) · 来源：\(line.sourceLabel)")
                    .font(.system(size: 11)).foregroundStyle(HubInk.faint)
                    .fixedSize(horizontal: false, vertical: true)
                Text(users.isEmpty ? "还没有 Agent 引用" : "在用：\(users.prefix(3).map { $0.name }.joined(separator: "、"))\(users.count > 3 ? " 等 \(users.count) 个" : "")")
                    .font(.system(size: 11)).foregroundStyle(users.isEmpty ? HubInk.faint : HubInk.green)
                if !tierNames.isEmpty {
                    Text("JEV 档位：\(tierNames.joined(separator: "、"))")
                        .font(.system(size: 11)).foregroundStyle(HubInk.sub)
                }
                if HubModel.isEmptyAddress(line.effectiveAddress) {
                    Text("这一行和它的归属连接都没写地址，网关发不出去")
                        .font(.system(size: 11)).foregroundStyle(HubInk.orange)
                } else {
                    Text(line.effectiveAddress)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(HubInk.hint)
                        .lineLimit(1).truncationMode(.middle)
                        .help(line.addressOrigin)
                }
                HubReceiptView(providerID: line.id)
            }
            Spacer(minLength: 0)
            HubStatusTag(ok: health?.healthOK, latency: health?.latencyMS,
                         error: health?.healthError ?? "", method: health?.healthMethod ?? "",
                         failureCode: HubReceiptLedger.shared.receipt(for: line.id)?.shortCode ?? "")
        }
    }

    /// 其他（按规则排除的行）默认收起，点标签或标题都能展开。
    private var othersSection: some View {
        DisclosureGroup(isExpanded: $showOthers) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer(minLength: 0)
                    HubGhostButton(title: "收起其他", systemImage: "chevron.up") {
                        showOthers = false
                    }
                }
                Text(othersIntroText)
                    .font(.system(size: 11)).foregroundStyle(HubInk.hint)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(otherStates, id: \.rawValue) { state in
                    let group = otherRows(state)
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            stateHeader(state.title, count: group.count, tint: tint(for: state))
                            Text(stateNote(state)).font(.system(size: 11.5)).foregroundStyle(HubInk.sub)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(group) { line in
                                lineRow(line)
                            }
                        }
                    }
                }
                HStack {
                    Spacer(minLength: 0)
                    HubGhostButton(title: "收起其他", systemImage: "chevron.up") {
                        showOthers = false
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                HubTag(text: "其他", tint: HubInk.sub)
                Text("\(otherLines.count) 行按规则排除"
                     + (otherBreakdownText.isEmpty ? "" : "（\(otherBreakdownText)）"))
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(HubInk.ink)
                Spacer(minLength: 0)
            }
        }
    }

    private var otherStates: [HubModel.RouteLineState] { [.agentSide, .internalLine, .notModel] }

    /// 其他那组实际列出来的行数：没写地址的行已经算在「发不出去」里，这儿不重复列。
    private var otherShownCount: Int { otherLines.filter { !unreachableIDs.contains($0.id) }.count }

    /// 这些行里有几条被网关的真实回执判了「重试也不会变」，已经排除出自动挑选。
    private var receiptExcludedCount: Int {
        otherLines.filter { HubReceiptLedger.shared.receipt(for: $0.id)?.excludesFromAutoPick == true }.count
    }

    private var othersIntroText: String {
        var text = "这些行不算缺口：按规则排除，不进模型池、也不会被收编，默认收起。"
        if otherLines.count != otherShownCount {
            text += "其中 \(otherLines.count - otherShownCount) 条没写地址，已经列在上面「发不出去」那一组，这里不重复列。"
        }
        if receiptExcludedCount > 0 {
            text += "其中 \(receiptExcludedCount) 条有网关真实失败回执（如 HTTP 401 密钥被拒），已排除出自动挑选；"
                + "修好后成功调用一次会自动解除。"
        }
        return text
    }

    private func stateGroup(_ state: HubModel.RouteLineState,
                            lines group: [HubModel.RouteLine],
                            note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            stateHeader(state.title, count: group.count, tint: tint(for: state))
            Text(note).font(.system(size: 12)).foregroundStyle(HubInk.sub)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(group) { line in
                lineRow(line)
            }
        }
    }

    private func stateHeader(_ title: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text("\(title) · \(count) 条")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(tint)
            Spacer(minLength: 0)
        }
    }

    /// 每个状态一句话解释，省得对着标签猜。
    private func stateNote(_ state: HubModel.RouteLineState) -> String {
        switch state {
        case .agentSide: return "自带 source 的 Agent 侧线路，收编会按来源或域名另建连接。"
        case .internalLine: return "4202 / Jev 内部线路，只给「Jev 档位」页用，不进全局模型池。"
        case .notModel: return "没有模型名的行，当配置读，不参与线路池。"
        case .pooled: return "已在模型池里。"
        case .adoptable: return "有模型名和地址、只差一个连接归属。"
        case .boundNotPooled: return "有归属连接、但这一行自己没进池。"
        case .danglingReference: return "写着的连接在 connections 里找不到。"
        }
    }

    private func lineRow(_ line: HubModel.RouteLine) -> some View {
        let receipt = HubReceiptLedger.shared.receipt(for: line.id)
        return HStack(alignment: .top, spacing: 8) {
            HubTag(text: line.state.title, tint: tint(for: line.state))
            if receipt?.excludesFromAutoPick == true {
                HubTag(text: "不参与自动挑选", tint: HubInk.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(line.displayName).font(.system(size: 12, weight: .medium)).foregroundStyle(HubInk.ink)
                Text("\(line.model.isEmpty ? "没有模型名" : line.model) · \(line.sourceLabel) · \(line.reason)")
                    .font(.system(size: 11)).foregroundStyle(HubInk.faint)
                    .fixedSize(horizontal: false, vertical: true)
                lineAddress(line)
                HubReceiptView(providerID: line.id)
            }
            Spacer(minLength: 0)
        }
    }

    /// 这行真正会被用到的地址。行里没写、外面再猜「是不是没地址」最费时间，所以直接摆出来加一句来源。
    @ViewBuilder
    private func lineAddress(_ line: HubModel.RouteLine) -> some View {
        if HubModel.isEmptyAddress(line.effectiveAddress) {
            Text("这一行和它的归属连接都没写地址，网关发不出去")
                .font(.system(size: 11)).foregroundStyle(HubInk.orange)
        } else {
            Text(line.effectiveAddress)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(line.addressDefect == nil ? HubInk.hint : HubInk.orange)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(line.addressDefect.map { "\(line.addressOrigin)\n要修：\($0)" } ?? line.addressOrigin)
        }
    }

    private func tint(for state: HubModel.RouteLineState) -> Color {
        switch state {
        case .pooled: return HubInk.green
        case .adoptable: return HubInk.accent
        case .boundNotPooled: return HubInk.orange
        case .danglingReference: return HubInk.red
        case .agentSide, .internalLine, .notModel: return HubInk.sub
        }
    }

    private func ask(_ selection: HubModel.AdoptionSelection, summary: String) {
        confirmingSummary = summary
        confirming = selection
    }

    /// 确认单上的「跳过说明」：方案里没列的行，得让用户看见是因为什么被漏掉的。
    private func skipNote(_ plan: HubModel.AdoptionPlan) -> String {
        plan.notes.isEmpty ? "" : "\n\(plan.notes)"
    }

    private func run(_ selection: HubModel.AdoptionSelection) {
        result = model.adoptUnassignedLines(selection)
    }
}

/// 大号计数标签：数字大、说明紧跟，点得动的会带一个展开箭头。
struct HubCountChip: View {
    var value: Int
    var label: String
    var tint: Color
    var hint: String
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content(clickable: true) }.buttonStyle(.plain)
            } else {
                content(clickable: false)
            }
        }
        .help(hint)
    }

    private func content(clickable: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(value)").font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
            if clickable {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.7))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

// MARK: - ① ↔ ③ 对账

/// ① 模型池和 ③ 池内行到底是不是同一批。两边的行都用「归属连接 + 模型 id」标识，
/// flat 线路（没有 connection_id）按「连接 = 模型自己的 id」等价折算，避免把
/// 同一行算成两处不一致。
struct HubPoolReconciliation {
    struct Row: Hashable {
        var connectionID: String
        var modelID: String

        var display: String {
            connectionID == modelID ? modelID : "\(connectionID)/\(modelID)"
        }

        /// 人看的时候只在乎模型名（连接名是附加信息）。
        var label: String { modelID }
    }

    var poolRowCount: Int
    var ledgerRowCount: Int
    var missingInLedger: [Row]
    var missingInPool: [Row]

    var isConsistent: Bool { missingInLedger.isEmpty && missingInPool.isEmpty }

    var summary: String {
        if isConsistent {
            return "① 模型池 \(poolRowCount) 行 ↔ ③ 池内 \(ledgerRowCount) 行：逐条核对一致。"
        }
        var parts = ["① 模型池 \(poolRowCount) 行，③ 池内 \(ledgerRowCount) 行，两边对不上。"]
        if !missingInLedger.isEmpty {
            parts.append("① 有、③ 池内没有的行 \(missingInLedger.count) 条：" + names(missingInLedger))
        }
        if !missingInPool.isEmpty {
            parts.append("③ 池内有、① 没显示的行 \(missingInPool.count) 条：" + names(missingInPool))
        }
        return parts.joined(separator: " ")
    }

    var detail: String {
        var lines = [summary,
                     "① 的行是「连接 × 模型」，③ 的行是 router.json 里 provider 行的 model。"]
        if isConsistent { lines.append("对得上的含义：模型池里显示的每一行，都能在 router.json 里指到具体的 provider 行。") }
        else {
            lines.append("对不上通常意味着模型池缓存还没刷新，或一行 provider 没有归属到任何连接；"
                         + "想对到具体行，看 ③ 的池内清单。")
        }
        return lines.joined(separator: "\n")
    }

    private func names(_ rows: [Row]) -> String {
        let head = rows.prefix(4).map { $0.label }.joined(separator: "、")
        return rows.count > 4 ? "\(head) 等" : head
    }
}

extension HubModel {
    /// 逐条对账 ① 和 ③：多重集合比较，重复行也会显出差异。
    func poolReconciliation() -> HubPoolReconciliation {
        let poolRows = supplierGroups.flatMap { group in
            group.connections.flatMap { connection in
                connection.models.map { model in
                    HubPoolReconciliation.Row(connectionID: connection.id, modelID: model.id)
                }
            }
        }
        let ledgerRows = routeLines.filter { $0.state == .pooled }.map { line in
            HubPoolReconciliation.Row(connectionID: line.connectionID.isEmpty ? line.id : line.connectionID,
                                      modelID: line.id)
        }
        var poolCounts: [HubPoolReconciliation.Row: Int] = [:]
        for row in poolRows { poolCounts[row, default: 0] += 1 }
        var ledgerCounts: [HubPoolReconciliation.Row: Int] = [:]
        for row in ledgerRows { ledgerCounts[row, default: 0] += 1 }
        var missingInLedger: [HubPoolReconciliation.Row] = []
        for (row, count) in poolCounts {
            let extra = count - (ledgerCounts[row] ?? 0)
            if extra > 0 { missingInLedger += Array(repeating: row, count: extra) }
        }
        var missingInPool: [HubPoolReconciliation.Row] = []
        for (row, count) in ledgerCounts {
            let extra = count - (poolCounts[row] ?? 0)
            if extra > 0 { missingInPool += Array(repeating: row, count: extra) }
        }
        return HubPoolReconciliation(poolRowCount: poolRows.count,
                                     ledgerRowCount: ledgerRows.count,
                                     missingInLedger: missingInLedger.sorted { $0.display < $1.display },
                                     missingInPool: missingInPool.sorted { $0.display < $1.display })
    }

    /// ② 里那些「不落盘的显示卡」。
    ///
    /// 旧版每条 provider 自己带地址和模型，没有 `connections` 这一层；网关为了不让这些线路
    /// 从页面上消失，把它们临时投影成一张连接卡。所以 ② 的卡片数会比 router.json 的
    /// `connections` 多，多出来的就是这些卡。
    ///
    /// 判据只认投影时自己写下的标记 `flat_provider_id`：router.json 的真连接没有这个字段，
    /// 这个字段也不可能凭空出现在真连接上。卡里必须有模型行，空卡不贴「显示卡」标签。
    func flatDisplayCardIDs() -> Set<String> {
        Set(connections.filter { !$0.flatProviderID.isEmpty && !$0.models.isEmpty }.map(\.id))
    }

    /// router.json 里真有的连接数 = ② 卡片数 − 显示卡数（负数说明有卡丢了模型行，界面会照实说）。
    var routerConnectionCardCount: Int { connections.count - flatDisplayCardIDs().count }
}

/// 一个供应商：标题行可点击展开，展开后逐条列出它的模型线路。
struct HubSupplierGroupRow: View {
    @ObservedObject var model: HubModel
    var group: HubModel.SupplierGroup
    /// 网关把「没写 connection_id 的线路」投影成的临时显示卡（router.json 里没有这条 connection）。
    var isDisplayOnlyCard = false
    var isExpanded: Bool
    var onToggle: () -> Void
    var onEdit: (HubModel.Connection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Spacer(minLength: 0)
                        HubGhostButton(title: "收起", systemImage: "chevron.up") {
                            onToggle()
                        }
                    }
                    .padding(.horizontal, 16)
                    ForEach(group.connections) { connection in
                        modelRows(connection)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HubInk.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(HubInk.line, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        Button(action: onToggle) {
            if model.viewportWidth >= 820 {
                HStack(spacing: 12) {
                    headerIdentity
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    headerMetrics
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: 56, alignment: .leading)
                .contentShape(Rectangle())
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    headerIdentity
                    headerMetrics
                }
                .padding(14)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "收起这个供应商的模型" : "展开这个供应商的模型")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerIdentity: some View {
        HStack(spacing: 12) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HubInk.accent)
                .frame(width: 14)
            statusDot
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(group.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(HubInk.ink)
                    if group.isLocal { HubTag(text: "本地", tint: HubInk.green) }
                    if !group.source.isEmpty { HubTag(text: group.source, tint: HubInk.sub) }
                    if isDisplayOnlyCard {
                        HubTag(text: "显示卡", tint: HubInk.sub)
                            .help("router.json 的 connections 里没有这一条：它是网关给「没写 connection_id 的模型线路」临时投影出来的显示卡。")
                    }
                    if !groupFact.isUniform, !groupFact.isEmptyGroup, groupFact.missingCount == 0 {
                        HubTag(text: "地址不一致", tint: HubInk.sub)
                            .help("这一组的线路用了不止一种地址，每行地址在展开后逐条标出。")
                    }
                    if !groupFact.defect.isEmpty {
                        HubTag(text: "地址要修", tint: HubInk.orange).help(groupFact.defect)
                    }
                }
                addressLine
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerMetrics: some View {
        HStack(spacing: 12) {
            Text("\(group.modelCount) 个模型")
                .font(.system(size: 11)).foregroundStyle(HubInk.sub)
                .fixedSize(horizontal: true, vertical: false)
            Text(summary)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(summaryTint)
                .frame(width: 104, alignment: .trailing)
                .lineLimit(1)
            Text(group.latencyMS.map { "\($0) ms" } ?? "—")
                .font(.system(size: 12)).foregroundStyle(HubInk.ink)
                .frame(width: 74, alignment: .trailing)
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statusDot: some View {
        Circle().fill(group.onlineCount > 0 ? HubInk.dotOK : (group.failedCount > 0 ? HubInk.dotBad : HubInk.dotWarn))
            .frame(width: 10, height: 10)
    }

    /// 组里每条模型线路真正会用到的地址（把「行自己的」和「连接上的」两处合成一个答案）。
    private var groupFact: HubModel.GroupAddress { model.groupAddress(group) }

    /// 标题下的地址：一致就写地址本身，不一致就说清有几种、哪几条没写。
    /// 以前这里直接显示连接上的 `baseURL`，行里自己带地址时会显示成空的 ——
    /// 等于把「地址写在线路行上」说成了「没有地址」。
    private var addressLine: some View {
        let fact = groupFact
        return Text(fact.address.isEmpty ? fact.label : fact.address)
            .font(.system(size: 10.5, design: fact.address.isEmpty ? .default : .monospaced))
            .foregroundStyle(addressTint)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .help(addressHelp)
    }

    private var addressTint: Color {
        if !groupFact.defect.isEmpty { return HubInk.orange }
        if !groupFact.address.isEmpty { return HubInk.tableHead }
        return HubInk.warnText
    }

    private var addressHelp: String {
        let fact = groupFact
        var lines: [String] = []
        if fact.isEmptyGroup {
            lines.append("这条连接还没有模型，所以没有可展示的线路地址。")
        } else if !fact.address.isEmpty {
            lines.append("\(fact.address) —— 组里 \(fact.lineCount) 条模型线路都走这个地址。")
        } else {
            lines.append("\(fact.lineCount) 条模型线路里：\(fact.variantCount) 种地址、\(fact.missingCount) 条没写地址。")
        }
        if !fact.defect.isEmpty { lines.append("地址要修：\(fact.defect)") }
        lines.append("地址可以写在连接上，也可以写在每条线路行上；行里写了就用行里的，行里没写才用连接的。")
        return lines.joined(separator: "\n")
    }

    private var summary: String {
        if group.onlineCount == group.connections.count { return "已连接" }
        if group.onlineCount > 0 { return "部分可用" }
        if group.uncheckedCount == group.connections.count { return "待测速" }
        return "不可用"
    }

    private var summaryTint: Color {
        if group.onlineCount == group.connections.count { return HubInk.okText }
        if group.onlineCount > 0 { return HubInk.warnText }
        if group.uncheckedCount == group.connections.count { return HubInk.warnText }
        return HubInk.badText
    }

    private func modelRows(_ connection: HubModel.Connection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if connection.models.isEmpty {
                modelLine(connection, entry: nil)
            } else {
                ForEach(connection.models) { entry in
                    modelLine(connection, entry: entry)
                }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 42)
                HubGhostButton(title: model.isBusy("probe:\(connection.id)") ? "探测中…" : "探测",
                               systemImage: "dot.radiowaves.left.and.right",
                               enabled: !model.isBusy("probe:\(connection.id)")) {
                    model.probe(connectionID: connection.id)
                }
                HubGhostButton(title: "详情", systemImage: "chevron.right") {
                    model.detailConnectionID = connection.id
                    model.onOpenPage?(.routerDetail)
                }
                HubGhostButton(title: "编辑", systemImage: "slider.horizontal.3") {
                    onEdit(connection)
                }
                Spacer(minLength: 16)
            }
            .padding(.vertical, 5)
        }
    }

    private func modelLine(_ connection: HubModel.Connection,
                           entry: HubModel.Model?) -> some View {
        let isPlaceholder = entry == nil
        let modelText = entry?.model ?? (connection.kind == "dsh_bridge" ? "本地桥接" : "未发现模型")
        // 组里地址一致时行上不重复写（标题已经说清）；一旦组里有分歧或缺口，
        // 每条线路真正会用到的地址就逐行标出来，省得再猜哪条走哪儿。
        let fact = entry.map { model.addressFact(of: $0) }
        let rowAddress = fact?.effective ?? ""
        let showRowAddress = groupFact.isUniform
            ? (groupFact.address.isEmpty ? !rowAddress.isEmpty : rowAddress != groupFact.address)
            : true
        return HStack(spacing: 10) {
            Rectangle().fill(HubInk.line).frame(width: 1).padding(.leading, 30)
            Text(modelText)
                .font(.system(size: 12, design: isPlaceholder ? .default : .monospaced))
                .foregroundStyle(isPlaceholder ? HubInk.muted : HubInk.ink)
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            if let rank = entry?.rank { HubTag(text: rank.uppercased(), tint: HubInk.accent) }
            if let entry, model.agentCount(providerID: entry.id) > 0 {
                HubTag(text: "\(model.agentCount(providerID: entry.id)) 个 Agent 在用", tint: HubInk.green)
            }
            if showRowAddress, !isPlaceholder, let fact {
                rowAddressText(fact)
            }
            if !connection.enabled { HubTag(text: "已停用", tint: HubInk.faint) }
            Spacer(minLength: 8)
            if let entry {
                HubGhostButton(title: "移除", tint: HubInk.red) {
                    model.removeModelFromPool(providerID: entry.id)
                }
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 16)
        .frame(minHeight: 42)
    }

    /// 单条线路真正会被用到的地址；没写地址就直接说出来，不再显示成空白。
    @ViewBuilder
    private func rowAddressText(_ fact: HubModel.AddressFact) -> some View {
        if fact.effective.isEmpty {
            HubTag(text: "没写地址", tint: HubInk.orange)
                .help("这条线路行和它归属的连接都没写地址，网关发请求时没有地址可用。")
        } else {
            Text(fact.effective)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(fact.lineOverridesConnection ? HubInk.warnText : HubInk.tableHead)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 210, alignment: .trailing)
                .help(rowAddressHelp(fact))
        }
    }

    private func rowAddressHelp(_ fact: HubModel.AddressFact) -> String {
        var lines = ["\(fact.effective)（\(fact.origin)；网关真正发的就是它）"]
        if fact.lineOverridesConnection {
            lines.append("线路行里的地址和连接上的不一样，网关按行里的走，所以这里显示行里的。")
        }
        if let defect = HubModel.addressDefect(fact.raw) {
            lines.append("地址要修：\(defect)")
        } else if let defect = HubModel.addressDefect(fact.connectionRaw) {
            lines.append("连接上的地址要修：\(defect)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 供应商连接详情

struct HubConnectionDetailPage: View {
    @ObservedObject var model: HubModel
    @State private var editing: HubConnectionDraft?
    @State private var confirmDelete = false
    @State private var manualModel = ""

    private var connection: HubModel.Connection? { model.connection(id: model.detailConnectionID) }

    /// 这次「已连接 / 未连接」是怎么来的：读列表，还是发一次 1 token 生成。
    /// 空串表示老数据（没记过方式），就不显示这一行。
    private func healthMethodText(_ connection: HubModel.Connection) -> String {
        switch connection.healthMethod {
        case "generation":
            return connection.healthModel.isEmpty
                ? "1 token 生成探测（该接口不提供 GET /models）"
                : "1 token 生成探测 · 模型 \(connection.healthModel)"
        case "catalog":
            return "读 GET /models 列表"
        default:
            return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HubPageHeader(
                title: connection?.name ?? "供应商连接详情",
                subtitle: "供应商连接详情：地址、凭据、超时、模型清单都在这一页。"
            ) {
                HStack(spacing: 8) {
                    HubGhostButton(title: "返回线路列表", systemImage: "chevron.left") {
                        model.detailConnectionID = nil
                        model.onOpenPage?(.router)
                    }
                    if let connection {
                        HubGhostButton(title: "编辑", systemImage: "slider.horizontal.3") {
                            editing = HubConnectionDraft(connection: connection)
                        }
                        HubGhostButton(title: "删除", systemImage: "trash", tint: HubInk.red) {
                            confirmDelete = true
                        }
                    }
                }
            }

            if let connection {
                HubCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            HubTag(text: connection.isLocal ? "本地" : "云端",
                                   tint: connection.isLocal ? HubInk.green : HubInk.accent)
                            HubStatusTag(ok: connection.healthOK, latency: connection.latencyMS,
                                         error: connection.healthError, method: connection.healthMethod)
                            Spacer(minLength: 8)
                            Text("最近检查 \(model.checkedAt)").font(.system(size: 11)).foregroundStyle(HubInk.sub)
                        }
                        HubDivider()
                        HubKeyValue(label: "接入方式", value: connection.baseURL)
                        HubKeyValue(label: "凭据", value: connection.apiKey.isEmpty ? "无（本地线路）" : mask(connection.apiKey))
                        HubKeyValue(label: "协议", value: connection.wireAPI)
                        HubKeyValue(label: "超时", value: "\(Int(connection.timeout)) 秒")
                        HubKeyValue(label: "统计", value: connection.statsLabel, mono: false, tint: HubInk.sub)
                        if !healthMethodText(connection).isEmpty {
                            HubKeyValue(label: "检查方式", value: healthMethodText(connection), mono: false, tint: HubInk.sub)
                        }
                        if !connection.healthError.isEmpty {
                            HubKeyValue(label: "最近错误", value: connection.healthError, mono: false, tint: HubInk.red)
                        }
                        HubDivider()
                        HStack(spacing: 8) {
                            HubPrimaryButton(title: model.isBusy("probe:\(connection.id)") ? "探测中…" : "探测连通",
                                             systemImage: "dot.radiowaves.left.and.right",
                                             enabled: !model.isBusy("probe:\(connection.id)")) {
                                model.probe(connectionID: connection.id)
                            }
                            HubGhostButton(title: "重新拉取模型", systemImage: "arrow.clockwise") {
                                refreshCatalog(connection)
                            }
                        }
                    }
                }

                HubCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("模型清单").font(.system(size: 13, weight: .semibold)).foregroundStyle(HubInk.ink)
                            Text("池子里 \(connection.models.count) 个")
                                .font(.system(size: 11)).foregroundStyle(HubInk.sub)
                            Spacer()
                        }
                        if connection.models.isEmpty {
                            Text("这条线路还没有模型进池子。点「编辑」勾选，或手动加一个模型名。")
                                .font(.system(size: 12)).foregroundStyle(HubInk.sub)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .leading)],
                                      alignment: .leading, spacing: 8) {
                                ForEach(connection.models) { entry in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(entry.model)
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundStyle(HubInk.ink)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                        HStack(spacing: 5) {
                                            if let rank = entry.rank { HubTag(text: rank.uppercased(), tint: HubInk.accent) }
                                            let bound = model.agentCount(providerID: entry.id)
                                            HubTag(text: bound == 0 ? "未绑定 Agent" : "\(bound) 个 Agent 在用",
                                                   tint: bound == 0 ? HubInk.faint : HubInk.green)
                                            Spacer(minLength: 0)
                                            HubGhostButton(title: "移除", tint: HubInk.red) {
                                                model.removeModelFromPool(providerID: entry.id)
                                            }
                                        }
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HubInk.band))
                                }
                            }
                        }
                        HubDivider()
                        HStack(spacing: 8) {
                            TextField("手动加模型名，例如 gpt-5.6-codex", text: $manualModel)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            HubGhostButton(title: "加入池子", systemImage: "plus") {
                                let name = manualModel.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty else { return }
                                manualModel = ""
                                model.addModelsToPool(connectionID: connection.id, models: [name])
                            }
                        }
                    }
                }
            } else {
                HubCard {
                    Text("这条线路已经被删掉了。")
                        .font(.system(size: 12)).foregroundStyle(HubInk.sub)
                }
            }

            Spacer(minLength: 0)
        }
        .onAppear { model.refresh() }
        .sheet(item: $editing) { draft in
            HubConnectionEditor(model: model, draft: draft)
        }
        .confirmationDialog("删除供应商？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除 \(connection?.name ?? "")", role: .destructive) {
                if let id = connection?.id { model.removeConnection(id: id) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            let names = connection.map { model.agentNamesUsingConnection(id: $0.id) } ?? []
            let impact = names.isEmpty
                ? "当前没有 Agent 引用它。"
                : "受影响的 Agent：\(names.joined(separator: "、"))。"
            Text("会移除它的模型线路，并从 Agent 线路中解除引用；不会删除其它供应商。\n\(impact)\nrouter.json 会立刻写盘。")
        }
    }

    private func mask(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: max(key.count, 4)) }
        return "\(key.prefix(4))…\(key.suffix(4))"
    }

    private func refreshCatalog(_ connection: HubModel.Connection) {
        model.fetchCatalog(baseURL: connection.baseURL, apiKey: connection.apiKey, timeout: min(connection.timeout, 15)) { result in
            switch result {
            case .success(let names):
                let existing = Set(connection.models.map { $0.model })
                let fresh = names.filter { !existing.contains($0) }
                if fresh.isEmpty {
                    model.notify("接口返回 \(names.count) 个模型，都已在线路里")
                } else {
                    model.addModelsToPool(connectionID: connection.id, models: fresh)
                }
            case .failure(let error):
                model.notify("拉取模型失败：\(error.localizedDescription)", ok: false)
            }
        }
    }
}

// MARK: - 添加 / 编辑供应商

struct HubConnectionDraft: Identifiable {
    var id = UUID()
    var connectionID: String?
    var name = ""
    var baseURL = ""
    var apiKey = ""
    var wireAPI = "chat_completions"
    var timeout: Double = 120
    var catalog: [String] = []
    var selected: Set<String> = []

    init() {}

    init(connection: HubModel.Connection) {
        connectionID = connection.id
        name = connection.name
        baseURL = connection.baseURL
        apiKey = connection.apiKey
        wireAPI = connection.wireAPI
        timeout = connection.timeout
        catalog = connection.catalog.isEmpty ? connection.models.map { $0.model } : connection.catalog
        selected = Set(connection.models.map { $0.model })
    }
}

struct HubConnectionEditor: View {
    @ObservedObject var model: HubModel
    @State var draft: HubConnectionDraft
    @Environment(\.dismiss) private var dismiss
    @State private var pulling = false
    @State private var pullError = ""
    @State private var manual = ""
    @State private var saveError = ""

    private let presets: [(String, String, String)] = [
        ("本地 llama.cpp", "http://127.0.0.1:8080/v1", "local"),
        ("本地 Ollama", "http://127.0.0.1:11434/v1", "ollama"),
        ("OpenAI 兼容", "https://api.openai.com/v1", "cloud"),
        ("DeepSeek", "https://api.deepseek.com/v1", "deepseek"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.connectionID == nil ? "添加供应商" : "编辑供应商")
                .font(.system(size: 16, weight: .semibold))
            Text("地址、密钥、超时都只存在本机 router.json（权限 0600），不会上传。")
                .font(.system(size: 11.5)).foregroundStyle(HubInk.sub)

            HStack(spacing: 8) {
                ForEach(presets, id: \.1) { preset in
                    HubGhostButton(title: preset.0) {
                        draft.name = preset.0
                        draft.baseURL = preset.1
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                labelled("名称", TextField("例如 本地 llama.cpp", text: $draft.name))
                labelled("接口地址", TextField("http://127.0.0.1:8080/v1", text: $draft.baseURL))
                labelled("API Key", SecureField("本地线路可以留空", text: $draft.apiKey))
                HStack(spacing: 12) {
                    labelled("协议", Picker("", selection: $draft.wireAPI) {
                        Text("chat_completions").tag("chat_completions")
                        Text("responses").tag("responses")
                    }.labelsHidden().frame(width: 180))
                    labelled("超时（秒）", TextField("120", value: $draft.timeout, format: .number)
                        .frame(width: 90))
                    Spacer()
                }
            }

            HubDivider()

            HStack(spacing: 8) {
                HubGhostButton(title: pulling ? "拉取中…" : "拉取模型清单",
                               systemImage: "arrow.down.circle", enabled: !pulling) {
                    pull()
                }
                if !pullError.isEmpty {
                    ScrollView {
                        Text(pullError)
                            .font(.system(size: 11))
                            .foregroundStyle(HubInk.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: 360, maxHeight: 72, alignment: .leading)
                }
                Spacer()
                Text("已勾选 \(draft.selected.count) / \(draft.catalog.count)")
                    .font(.system(size: 11)).foregroundStyle(HubInk.sub)
            }

            if draft.catalog.isEmpty {
                Text("还没拉到模型。可以先保存供应商，之后再回到详情添加模型。")
                    .font(.system(size: 11.5)).foregroundStyle(HubInk.sub)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(draft.catalog, id: \.self) { name in
                            Toggle(isOn: binding(for: name)) {
                                Text(name).font(.system(size: 12, design: .monospaced))
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
            }

            HStack(spacing: 8) {
                TextField("手动加模型名", text: $manual)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                HubGhostButton(title: "加入清单", systemImage: "plus") {
                    let name = manual.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    manual = ""
                    if !draft.catalog.contains(name) { draft.catalog.append(name) }
                    draft.selected.insert(name)
                }
            }

            HubDivider()

            HStack {
                Text(saveError.isEmpty
                     ? "保存后立刻写盘，旧配置会被覆盖；模型池只增不减。"
                     : saveError)
                    .font(.system(size: 11))
                    .foregroundStyle(saveError.isEmpty ? HubInk.sub : HubInk.red)
                Spacer()
                HubGhostButton(title: "取消") { dismiss() }
                HubPrimaryButton(title: "保存", systemImage: "checkmark") {
                    saveError = ""
                    let saved = model.saveConnection(
                        id: draft.connectionID,
                        name: draft.name,
                        baseURL: draft.baseURL,
                        apiKey: draft.apiKey,
                        wireAPI: draft.wireAPI,
                        timeout: draft.timeout,
                        catalog: draft.catalog,
                        selected: draft.catalog.filter { draft.selected.contains($0) }
                    )
                    if saved {
                        dismiss()
                    } else {
                        saveError = model.notice?.text ?? "供应商保存失败，请检查填写内容。"
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(HubInk.page)
    }

    private func labelled<Content: View>(_ title: String, _ content: Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(HubInk.sub)
            content.textFieldStyle(.roundedBorder).font(.system(size: 12))
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { draft.selected.contains(name) },
            set: { isOn in
                if isOn { draft.selected.insert(name) } else { draft.selected.remove(name) }
            }
        )
    }

    private func pull() {
        pulling = true
        pullError = ""
        model.fetchCatalog(baseURL: draft.baseURL, apiKey: draft.apiKey, timeout: min(draft.timeout, 15)) { result in
            pulling = false
            switch result {
            case .success(let names):
                for name in names where !draft.catalog.contains(name) { draft.catalog.append(name) }
                draft.catalog.sort()
                if draft.selected.isEmpty { draft.selected = Set(names) }
            case .failure(let error):
                pullError = error.localizedDescription
            }
        }
    }
}

// MARK: - Agent 管理（Lunacy：双策略 + 客户端配置表）

/// 新增一个 Agent 客户端：只登记「叫什么、配置在哪、允不允许写模型」。
private struct HubClientEditor: View {
    let draft: HubClientSpec
    /// 已经在清单里的名字，用来挡住重名（重名会被清单按 id 去重，等于白填一遍）。
    let existingNames: [String]
    let onSave: (HubClientSpec) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var path: String
    @State private var editable: Bool

    init(draft: HubClientSpec, existingNames: [String], onSave: @escaping (HubClientSpec) -> Void) {
        self.draft = draft
        self.existingNames = existingNames
        self.onSave = onSave
        _name = State(initialValue: draft.name)
        _path = State(initialValue: draft.path)
        _editable = State(initialValue: draft.editable)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPath: String { path.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isEditing: Bool { !draft.id.isEmpty }

    private var nameError: String? {
        if trimmedName.isEmpty { return "名字不能空" }
        let key = HubModel.normalizedKey(trimmedName)
        if existingNames.contains(where: { HubModel.normalizedKey($0) == key }) { return "这个客户端已经在清单里了" }
        return nil
    }

    private var pathError: String? {
        if trimmedPath.isEmpty { return "配置路径不能空" }
        guard trimmedPath.hasPrefix("/") || trimmedPath.hasPrefix("~") else {
            return "请填绝对路径或 ~ 开头的路径"
        }
        return nil
    }

    /// 按当前填的路径说真话：文件在不在、模型能不能写。认不出的格式一律说不支持，
    /// 因为写进去等于往别人的配置文件里乱塞字段。
    private var probe: (found: Bool, writable: Bool, note: String) {
        guard pathError == nil else { return (false, false, "先把路径填对") }
        guard let url = HubAgentSync.detect(path: trimmedPath) else {
            return (false, false, "这个路径上还没有文件；先让该客户端生成自己的配置，再回来写模型。")
        }
        guard editable else { return (true, false, "已找到 \(url.path)，按只读登记。") }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            return (true, false, "已找到 \(url.path)，但文件本身不可写，按只读登记。")
        }
        do {
            let plan = try HubAgentSync.plan(agentName: trimmedName, fileURL: url)
            return (true, true, "已找到 \(url.path)，格式 \(plan.format.rawValue)，可以把模型写进去。")
        } catch {
            return (true, false, "已找到 \(url.path)，但这个格式没法安全改模型：\(error.localizedDescription)")
        }
    }

    var body: some View {
        let probe = self.probe
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "编辑 Agent 客户端" : "新增 Agent 客户端")
                .font(.system(size: 16, weight: .semibold))
            Text("只登记客户端和它的配置文件位置。模型由该文件自己说了算，认不出的格式不会硬写。")
                .font(.system(size: 11.5)).foregroundStyle(HubInk.sub)

            VStack(alignment: .leading, spacing: 8) {
                labelled("客户端名字", TextField("例如 Cursor", text: $name))
                labelled("配置文件路径", TextField("~/Library/Application Support/Cursor/settings.json", text: $path))
                Toggle(isOn: $editable) {
                    Text("允许写入模型").font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
            }

            if let error = nameError ?? pathError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(HubInk.red)
            } else {
                Text(probe.note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(probe.writable ? HubInk.sub : HubInk.warnText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HubDivider()

            HStack {
                Text(isEditing ? "这里只保存该 Agent 的独立权限和路径，不会改客户端配置。"
                               : "新增只写这份客户端清单，不会改任何客户端配置。")
                    .font(.system(size: 11)).foregroundStyle(HubInk.sub)
                Spacer()
                HubGhostButton(title: "取消") { dismiss() }
                HubPrimaryButton(title: isEditing ? "保存" : "添加",
                                 systemImage: isEditing ? "checkmark" : "plus",
                                 enabled: nameError == nil && pathError == nil) {
                    onSave(HubClientSpec(id: draft.id, name: trimmedName, path: trimmedPath, editable: editable))
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(HubInk.page)
    }

    private func labelled<Content: View>(_ title: String, _ content: Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(HubInk.sub)
            content.textFieldStyle(.roundedBorder).font(.system(size: 12))
        }
    }
}

private struct HubDetectedAgent: Identifiable {
    let id: String
    let name: String
    let model: String
    /// 真正从客户端配置文件里读出来的模型名；读不出来是 nil（界面据此显示灰色占位）。
    let currentModel: String?
    /// Models advertised by the client's own provider configuration (for
    /// example every model key in a ZCode provider), not just the active one.
    let configuredModels: [HubAgentSync.Plan.ConfiguredModel]
    /// 这个客户端已经从本地路由模型池里选走的模型。
    let addedModels: [HubModel.Model]
    /// 它能不能一次登记多个模型（决定右侧「添加模型」是写入客户端列表，还是只加入 default）。
    let holdsModelList: Bool
    /// 它配置里那条线路指向哪个 Agent（`…/agents/<名字>/v1` 里的名字），读不出来是 nil。
    let modelRoute: String?
    let path: String
    let configURL: URL?
    let editable: Bool
}

private struct HubAgentDisplayModel: Identifiable {
    let id: String
    let model: String
    let supplier: String
    let isNative: Bool
    let locked: Bool
    let lockReason: String?
    let option: HubModel.SwitchOption?
}

private struct HubPageButton: View {
    let title: String
    let width: CGFloat
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(filled ? Color.white : HubInk.ink)
                .frame(width: width, height: 36)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(filled ? HubInk.accent : Color.white))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(filled ? HubInk.accent : Color(red: 0.882, green: 0.898, blue: 0.937), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct HubAgentsPage: View {
    @ObservedObject var model: HubModel
    @State private var pendingSync: HubAgentSync.Plan?
    @State private var pendingModel = ""
    /// 正在填写的「新增客户端」草稿；非 nil 就弹表单。
    @State private var newClient: HubClientSpec?
    /// 正在编辑权限/路径的既有客户端。
    @State private var editingClient: HubClientSpec?
    /// 待确认移除的客户端 id。
    @State private var pendingRemoval: String?

    /// 读不出配置时的占位文案。绝不能写具体模型名 ——
    /// 否则界面会把猜测当成「当前正在用」展示。
    private static let unknownModelText = "尚未配置"

    private var detectedAgents: [HubDetectedAgent] {
        let rows = model.clientSpecs.map { spec -> HubDetectedAgent in
            // 先按清单里登记的路径找；找不到再按名字猜常见位置（老清单只写了名字的那种）。
            let file = HubAgentSync.detect(path: spec.path) ?? HubAgentSync.detect(agentName: spec.name)
            let plan = file.flatMap { try? HubAgentSync.plan(agentName: spec.name, fileURL: $0) }
            let current = plan?.currentModel
            let trimmed = current?.trimmingCharacters(in: .whitespaces)
            let real = (trimmed?.isEmpty == false) ? trimmed : nil
            let displayModel = real == "dsh" ? "AI助手本地路由（Jev）" : real
            let relativePath = file.map { "~" + $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "") } ?? spec.path
            let route: String? = plan?.modelRoute
            let routeKey = route ?? spec.id
            return HubDetectedAgent(
                id: spec.id,
                name: spec.name,
                model: displayModel ?? HubAgentsPage.unknownModelText,
                currentModel: real,
                configuredModels: plan?.configuredModels ?? [],
                addedModels: model.assignedModels(agentID: routeKey, agentName: routeKey, currentModel: real),
                holdsModelList: plan?.holdsModelList ?? true,
                modelRoute: route,
                path: relativePath,
                configURL: file,
                editable: spec.editable && file != nil
            )
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HubPageHeader(
                title: "Agent 管理",
                subtitle: "按客户端分类：当前模型始终读取客户端自己的最新配置；添加模型只扩充统一 default 允许列表，不替换客户端当前模型。"
            )

            strategySection
            routesSection
            clientsSection
            bottomActions
            safetyBanner

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 26)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { model.refresh() }
        .confirmationDialog("写入 \(pendingSync?.agentName ?? "") 的配置？",
                            isPresented: Binding(get: { pendingSync != nil }, set: { if !$0 { pendingSync = nil } }),
                            titleVisibility: .visible) {
            Button("备份并写入") {
                if let plan = pendingSync { _ = model.applySync(plan: plan, model: pendingModel) }
                pendingSync = nil
            }
            Button("取消", role: .cancel) { pendingSync = nil }
        } message: {
            if let plan = pendingSync {
                Text("文件：\(plan.fileURL.path)\n格式：\(plan.format.rawValue)\n改动：\(plan.changeSummary)\n会先备份到 router 支持目录的 config-backups。")
            }
        }
        .confirmationDialog("从列表移除 \(removalName)？",
                            isPresented: Binding(get: { pendingRemoval != nil },
                                                 set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("只从列表移除", role: .destructive) {
                if let id = pendingRemoval { _ = model.removeClient(id: id) }
                pendingRemoval = nil
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("只改这份客户端清单，\(removalName) 自己的配置文件不会被改动，随时可以再加回来。")
        }
        .sheet(item: $newClient) { draft in
            HubClientEditor(draft: draft, existingNames: model.clientSpecs.map(\.name)) { spec in
                model.addClient(name: spec.name, path: spec.path, editable: spec.editable)
            }
        }
        .sheet(item: $editingClient) { draft in
            HubClientEditor(
                draft: draft,
                existingNames: model.clientSpecs.filter { $0.id != draft.id }.map(\.name)
            ) { spec in
                model.updateClient(id: draft.id, name: spec.name, path: spec.path, editable: spec.editable)
            }
        }
    }

    private var removalName: String {
        guard let id = pendingRemoval else { return "" }
        return model.clientSpecs.first { $0.id == id }?.name ?? id
    }

    /// `editable` 是客户端适配器能力；运行时是否真的能写，还要经过当前策略。
    private func canWrite(_ agent: HubDetectedAgent) -> Bool {
        agent.id == "codex" || agent.editable || isGatewayManaged(agent)
    }

    private func isCodexRouteOnly(_ agent: HubDetectedAgent) -> Bool {
        // 尚未接入 4230 时，Codex 才是 4202 分配模式；统一网关接管后
        // 和其它 Agent 一样由 4230 管理。
        agent.id == "codex" && agent.editable && !isGatewayManaged(agent) && !model.isReadOnlyMode
    }

    private func isGatewayManaged(_ agent: HubDetectedAgent) -> Bool {
        guard model.strategy == .gateway else { return false }
        return HubStrategySync.gatewayTargets().contains {
            $0.client.rawValue == agent.id && $0.isWritable
        }
    }

    private var strategySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "配置权限",
                          detail: "这里决定中枢能不能写客户端配置，不会改变客户端当前连接的线路。")
            strategyCards
        }
    }

    private var routesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "中枢线路",
                          detail: "每个 Agent 展示自己的模型池和当前模型；普通模型只切同名线路，Jev 自动决策单独保留。")
            if model.agents.isEmpty {
                Text("尚未找到 Agent")
                    .font(.system(size: 12))
                    .foregroundStyle(HubInk.warnText)
            } else {
                ForEach(model.agents) { route in
                    routeSummaryCard(route)
                }
            }
        }
    }

    private func routeSummaryCard(_ route: HubModel.Agent) -> some View {
        let models = model.assignedModels(agentID: route.id, agentName: route.name, currentModel: nil)
        let hasJev = route.providerIDs.contains(HubModel.jevProviderID)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(route.id == "default" ? "Agent 模型池 default" : "Agent 模型池 \(route.name)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HubInk.ink)
                HubTag(text: "router.json", tint: HubInk.sub)
                Spacer(minLength: 8)
                Text("\(models.count) 个允许模型")
                    .font(.system(size: 11))
                    .foregroundStyle(HubInk.sub)
                Menu("添加模型") {
                    let selected = Set(models.map(\.id))
                    if model.poolModels.isEmpty {
                        Text("当前模型池为空")
                    } else {
                        ForEach(model.poolModels) { entry in
                            let alreadyAdded = selected.contains(entry.id)
                            Button {
                                if !alreadyAdded { model.assignModel(providerID: entry.id, toAgent: route.id) }
                            } label: {
                                Label(
                                    "\(entry.supplier ?? "本地路由") · \(entry.model)"
                                        + (alreadyAdded ? "（已添加）" : ""),
                                    systemImage: alreadyAdded ? "checkmark.circle.fill" : "plus.circle"
                                )
                            }
                            .disabled(alreadyAdded)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
                .disabled(model.isReadOnlyMode)
            }
            Text(route.name)
                .font(.system(size: 11))
                .foregroundStyle(HubInk.muted)
            if hasJev {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                    Text("Jev 自动决策已保留：按档位选择模型，不作为普通模型条目显示")
                }
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.50, green: 0.33, blue: 0.80))
            }
            if models.isEmpty {
                Text("暂无模型池引用")
                    .font(.system(size: 11))
                    .foregroundStyle(HubInk.muted)
            } else {
                HubFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(models) { entry in
                        modelChip(model: entry.model,
                                  supplier: entry.supplier ?? "本地路由",
                                  remove: model.isReadOnlyMode ? nil : {
                                      model.removeModelFromAgent(providerID: entry.id, agentID: route.id)
                                  })
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HubInk.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(HubInk.line, lineWidth: 1))
    }

    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(alignment: .top, spacing: 12) {
                sectionHeader(title: "Agent 客户端",
                              detail: "这里分开显示三件事：客户端当前模型、Agent 模型池、客户端配置模型。当前模型直接读自客户端配置文件；普通模型故障时只切同名线路，Jev 才允许换模型。添加或切换前会预览并备份，清单可以自己增删。")
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    HubGhostButton(title: "新增客户端", systemImage: "plus") {
                        newClient = HubClientSpec(id: "", name: "", path: "~/", editable: true)
                    }
                    HubGhostButton(title: "恢复默认", systemImage: "arrow.counterclockwise") {
                        model.restoreDefaultClients()
                    }
                }
            }
            agentTable
        }
    }

    private func sectionHeader(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 17)).foregroundStyle(HubInk.ink)
            Text(detail).font(.system(size: 12)).foregroundStyle(HubInk.muted)
        }
    }

    private var strategyCards: some View {
        let gatewayUnavailable = model.gatewayWriteUnavailableReason
        let gatewayDetail = gatewayUnavailable
            ?? "尝试让已授权的 Agent 使用 4230；语音助手策略链继续使用 4202。"
        let gatewayFootnote = gatewayUnavailable == nil ? "权限：确认后可写" : "当前不可用"
        // 两张卡等分宽度；再窄就上下堆叠，绝不互相压。
        return Group {
            // 实测：两张卡并排至少各要 ~352pt，加 16 间距和左右各 40 内边距 ≈ 800pt。
            // 阈值给低了右卡就会被推出窗口右边界（900 宽窗口下实测跑到 x=983）。
            if model.viewportWidth >= 800 {
                HStack(spacing: 16) {
                    strategyCard(
                        title: "只读监测",
                        detail: "不接管 4230；每个 Agent 的独立权限仍按卡片设置。",
                        footnote: "权限：只读",
                        selected: model.strategy == .readOnly
                    ) { model.applyStrategy(.readOnly) }
                    strategyCard(
                        title: "AI助手接管路由",
                        detail: gatewayDetail,
                        footnote: gatewayFootnote,
                        selected: model.strategy == .gateway
                    ) { model.applyStrategy(.gateway) }
                }
            } else {
                VStack(spacing: 16) {
                    strategyCard(
                        title: "只读监测",
                        detail: "不接管 4230；每个 Agent 的独立权限仍按卡片设置。",
                        footnote: "权限：只读",
                        selected: model.strategy == .readOnly
                    ) { model.applyStrategy(.readOnly) }
                    strategyCard(
                        title: "AI助手接管路由",
                        detail: gatewayDetail,
                        footnote: gatewayFootnote,
                        selected: model.strategy == .gateway
                    ) { model.applyStrategy(.gateway) }
                }
            }
        }
    }

    private func strategyCard(title: String, detail: String, footnote: String,
                              selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Text(selected ? "●" : "○")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(selected ? HubInk.accent : HubInk.faint)
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(selected ? HubInk.tintInk : HubInk.ink)
                }
                Spacer().frame(height: 9)
                Text(detail).font(.system(size: 12)).foregroundStyle(HubInk.sub)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer().frame(height: 7)
                Text(footnote).font(.system(size: 11)).foregroundStyle(selected ? HubInk.accent : HubInk.muted)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? HubInk.tint : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(selected ? Color(red: 0.863, green: 0.886, blue: 1.0) : HubInk.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var agentTable: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(detectedAgents) { agent in
                agentCard(agent)
            }
        }
    }

    /// 一个 Agent 客户端一张卡：客户端名 + 现在正在用的模型 + 已添加的本地路由模型 + 「＋」添加。
    private func agentCard(_ agent: HubDetectedAgent) -> some View {
        let writable = canWrite(agent)
        let codexRouteOnly = isCodexRouteOnly(agent)
        let gatewayManaged = isGatewayManaged(agent)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text(agent.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(HubInk.ink)
                HubTag(text: gatewayManaged ? "网关托管" : (codexRouteOnly ? "可分配" : (writable ? "可写" : "只读")),
                       tint: writable ? HubInk.green : HubInk.warnText)
                Spacer(minLength: 8)
                // layoutPriority 让路径先被压缩：窄窗口时截断路径，而不是把这一行撑出卡片。
                Text(agent.path).font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(HubInk.tableHead)
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(-1)
                HubCircleIconButton(systemImage: "minus.circle") { pendingRemoval = agent.id }
                    .help("从列表移除（不动它的配置文件）")
                HubCircleIconButton(systemImage: "pencil") {
                    editingClient = model.clientSpecs.first { $0.id == agent.id }
                }
                .help("编辑这个 Agent 的路径和独立写入权限")
            }

            // 线路和权限是两个独立维度：default 是客户端当前连接的线路 ID，
            // 不会因为上面切换只读/接管策略而消失；写入口则由当前策略统一门控。
            HStack(spacing: 10) {
                Text("当前线路").font(.system(size: 11.5)).foregroundStyle(HubInk.sub)
                Text(agent.modelRoute ?? "未检测到")
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(agent.modelRoute == nil ? HubInk.muted : HubInk.accent)
                if agent.modelRoute != nil {
                    HubTag(text: "router.json", tint: HubInk.sub)
                }
                Spacer(minLength: 8)
            }

            // 「现在正在用的模型」：直接读客户端配置文件，读不出来就说清楚原因。
            HStack(spacing: 10) {
                Text("当前正在用").font(.system(size: 11.5)).foregroundStyle(HubInk.sub)
                    .layoutPriority(1)
                Text(agent.model)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(agent.currentModel == nil ? HubInk.muted : HubInk.ink)
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                // 只存一格模型的客户端（Codex 的 config.toml 就是）没有下面的标签墙，
                // 供应商只在这一个模型名上看得出来，就跟着写在这一行后面。
                if !agent.holdsModelList,
                   let current = agent.currentModel,
                   let supplier = agent.configuredModels.first(where: { $0.model == current })?.supplier {
                    Text("· \(supplier)")
                        .font(.system(size: 11))
                        .foregroundStyle(HubInk.muted)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                if agent.id == "codex", model.isReadOnlyMode,
                   let current = agent.currentModel, agent.modelRoute == nil {
                    Text(HubModel.isOfficialCodexModel(current) ? "· 官方账号" : "· API 直连")
                        .font(.system(size: 11))
                        .foregroundStyle(HubInk.muted)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 8)
                if !writable {
                    Text("这个客户端的配置由它自己管理，只读展示。")
                        .font(.system(size: 11)).foregroundStyle(HubInk.muted)
                        .lineLimit(1)
                        .layoutPriority(-1)
                } else if gatewayManaged {
                    Text("网关托管；确认后可写入 4230 客户端配置。")
                        .font(.system(size: 11)).foregroundStyle(HubInk.muted)
                        .lineLimit(1)
                        .layoutPriority(-1)
                } else if codexRouteOnly {
                    Text("只读监测不改 Codex 配置；仍可切换 4202 路由分配。")
                        .font(.system(size: 11)).foregroundStyle(HubInk.muted)
                        .lineLimit(1)
                        .layoutPriority(-1)
                } else if hasAddableModel(agent) {
                    modelMenu(for: agent)
                } else {
                    Label("已全部添加", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HubInk.green)
                }
            }

            if let current = agent.currentModel, !current.isEmpty {
                let inPool = model.poolModels.contains { HubModel.isCurrentModel($0, currentModel: current) }
                let inRoute = agent.addedModels.contains { HubModel.isCurrentModel($0, currentModel: current) }
                let internalJev = model.isInternalJevModel(current)
                if (!inPool && !internalJev) || (!inRoute && !internalJev) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(HubInk.warnText)
                        Text(!inPool
                             ? "当前模型 (current) 不在全局模型池；请到「本地路由」把它加入供应商模型池。"
                             : "当前模型 (current) 已在模型池，但还未加入 default 通用配置。")
                            .font(.system(size: 11))
                            .foregroundStyle(HubInk.warnText)
                            .fixedSize(horizontal: false, vertical: true)
                        if let entry = model.poolModels.first(where: { HubModel.isCurrentModel($0, currentModel: current) }),
                           inPool, !inRoute {
                            Button("加入 default") {
                                model.addModelToDefault(providerID: entry.id)
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(HubInk.accent)
                            .disabled(model.isReadOnlyMode)
                        }
                    }
                }
            }

            // 合并为一组：客户端原生模型在前，default 新增模型在后。
            // 原生模型只读；新增模型在可写策略下可点击切换，只读策略只展示，
            // 且不再提供拖拽排序，避免“可切换列表”和“Agent 线路列表”重复表达同一件事。
            let nativeModels = agent.configuredModels.filter { !$0.isAIManaged }
            let nativeKeys = Set(nativeModels.map { displayModelKey($0.model) })
            let addedModels = switchCandidates(agent).filter {
                !nativeKeys.contains(displayModelKey($0.model.model))
            }
            if !nativeModels.isEmpty || !addedModels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("客户端模型 · 原生优先，新增模型置后")
                        .font(.system(size: 11)).foregroundStyle(HubInk.sub)
                    HubFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        ForEach(groupedAgentModels(native: nativeModels, added: addedModels)) { row in
                            if row.isNative {
                                modelChip(model: row.model,
                                          supplier: row.supplier,
                                          locked: row.locked,
                                          lockReason: row.lockReason)
                            } else if let option = row.option {
                                switchChip(option,
                                           enabled: writable,
                                           routeOnly: agent.id == "codex" && !gatewayManaged && !model.isReadOnlyMode) {
                                    beginSync(agent, providerID: option.model.id, model: option.model.model)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HubInk.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(HubInk.line, lineWidth: 1))
    }

    private func modelChip(model: String,
                           supplier: String,
                           remove: (() -> Void)? = nil,
                           locked: Bool = false,
                           lockReason: String? = nil) -> some View {
        HStack(spacing: 5) {
            if locked { Image(systemName: "lock.fill").font(.system(size: 8)) }
            Text(model)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(locked ? HubInk.muted.opacity(0.12) : modelTint(for: supplier).opacity(0.15)))
        .foregroundStyle(locked ? HubInk.muted : modelTint(for: supplier))
        // 不再强行给每个模型 chip 132pt 最小宽度；模型少时不会凭空撑出大片空白，
        // 模型多时由 HubFlowLayout 自然换行，避免卡片内出现错位/重叠。
        .frame(minWidth: 0, alignment: .leading)
        .help(lockReason ?? "供应商：\(supplier)")
    }

    /// 先按供应商颜色分组，再在同组内把原生模型放前面。
    /// 这样蓝色 GPT、紫色 Jev、绿色 AI助手等不会被交错到各处。
    private func groupedAgentModels(
        native: [HubAgentSync.Plan.ConfiguredModel],
        added: [HubModel.SwitchOption]
    ) -> [HubAgentDisplayModel] {
        let rows = native.map { entry in
            HubAgentDisplayModel(id: "native:\(entry.id)", model: entry.model,
                                 supplier: entry.supplier, isNative: true,
                                 locked: entry.isLocked, lockReason: entry.lockReason,
                                 option: nil)
        } + added.map { entry in
            HubAgentDisplayModel(id: "added:\(entry.id)", model: entry.model.model,
                                 supplier: entry.model.supplier ?? "本地路由", isNative: false,
                                 locked: false, lockReason: nil, option: entry)
        }
        return rows.sorted {
            let leftKey = supplierColorKey($0.supplier)
            let rightKey = supplierColorKey($1.supplier)
            if leftKey != rightKey { return leftKey < rightKey }
            if $0.isNative != $1.isNative { return $0.isNative && !$1.isNative }
            return $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending
        }
    }

    private func modelTint(for supplier: String) -> Color {
        let key = supplierColorKey(supplier)
        switch key {
        case "deepseek":
            return Color(red: 0.08, green: 0.53, blue: 0.62)
        case "jev":
            return Color(red: 0.50, green: 0.33, blue: 0.80)
        case "teamorouter":
            return HubInk.orange
        case "codex":
            return HubInk.accent
        case "zcode":
            return Color(red: 0.84, green: 0.56, blue: 0.20)
        case "ai-assistant":
            return HubInk.green
        default:
            let palette: [Color] = [HubInk.accent, HubInk.green, HubInk.orange,
                                    Color(red: 0.50, green: 0.33, blue: 0.80),
                                    Color(red: 0.08, green: 0.53, blue: 0.62)]
            let index = key.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % palette.count }
            return palette[index]
        }
    }

    private func supplierColorKey(_ supplier: String) -> String {
        let value = supplier.lowercased()
        if value.contains("deepseek") { return "deepseek" }
        if value.contains("jev") || value.contains("4202") { return "jev" }
        if value.contains("teamorouter") { return "teamorouter" }
        if value.contains("ai助手") { return "ai-assistant" }
        if value.contains("zcode") || value.contains("z.ai") || value.contains("bigmodel") || value.contains("glm") {
            return "zcode"
        }
        if value.contains("codex") { return "codex" }
        return value
    }

    private func displayModelKey(_ model: String) -> String {
        let value = model.lowercased()
        if value == "jev/auto" { return "jev-auto" }
        if value.hasPrefix("deepseek/") { return String(value.dropFirst("deepseek/".count)) }
        return value
    }

    /// 客户端右侧的「添加模型」按钮。两种客户端共用这一个菜单、这一个标题 —— 往这个客户端里
    /// 写模型本来就是同一件事（从本地路由的模型池里挑一个写进去），区别只在写进去以后的效果：
    ///
    /// * 能列一串模型的（ZCode 的 `provider.<id>.models`）：多加一个；
    /// * 只存一格模型的（Codex 的 `model = "…"`）：只加入 default，不改当前值。
    ///
    /// 单格客户端不能靠这个菜单切换当前值；当前值由客户端自己产生并在刷新时重新读取。
    @ViewBuilder
    private func modelMenu(for agent: HubDetectedAgent) -> some View {
        addingModelMenu(for: agent)
    }

    /// 把模型池里的模型挑一个写进这个客户端。
    ///
    /// 已经出现在客户端卡片“客户端模型”列表里的模型（包括原生模型和 default
    /// 中已经加入的模型）必须置灰，不能再次写入；菜单只让用户选择尚未出现在
    /// 客户端列表里的模型。这里不能只看客户端配置文件：卡片后半段的 default
    /// 模型是由统一路由投影出来的，真实配置文件里未必会逐条保存它们。
    private func addingModelMenu(for agent: HubDetectedAgent) -> some View {
        let current = agent.currentModel?.trimmingCharacters(in: .whitespaces) ?? ""
        // 菜单的“已添加”判定必须和卡片可见列表共用数据源：
        // configuredModels 是客户端原生/真实配置模型，switchCandidates 是 default
        // 投影到客户端卡片上的新增模型。只检查前者会让已显示的 DeepSeek / jev-auto
        // 仍然可点，最终造成重复添加。
        let configuredModelNames = Set(agent.configuredModels.map {
            $0.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let visibleCandidates = switchCandidates(agent)
        let visibleModelIDs = Set(visibleCandidates.map { $0.model.id })
        let visibleModelNames = Set(visibleCandidates.map {
            $0.model.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let pool = model.poolModels
        return styledMenu(icon: "plus", title: "添加模型",
                          help: agent.holdsModelList
                                ? "从全局模型池里挑一个尚未加入这个客户端的模型"
                                : "把模型加入 default 统一路由，但不改这个客户端当前正在使用的模型") {
            if !current.isEmpty {
                Text("\(agent.name) 现在写着：\(current)")
            }
            if pool.isEmpty {
                Text("当前全局模型池为空")
                Button("去「本地路由」添加供应商") { model.onOpenPage?(.router) }
            } else {
                Section(agent.holdsModelList
                        ? "从全局模型池中选"
                        : "加入 default（不改客户端当前模型）") {
                    ForEach(pool) { entry in
                        let normalizedName = entry.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        let isAlreadyAdded = visibleModelIDs.contains(entry.id)
                            || visibleModelNames.contains(normalizedName)
                            || configuredModelNames.contains(normalizedName)
                        let isCurrent = HubModel.isCurrentModel(entry, currentModel: agent.currentModel)
                        Button(model.modelName(providerID: entry.id)
                               + (isCurrent ? "（当前正在用）" : (isAlreadyAdded ? "（已添加）" : ""))
                               + (model.providerEnabled(entry.id) ? "" : "（已停用）")) {
                            // Codex 只有一个 model 字段。添加模型时只把它加入
                            // default 允许列表，不能把客户端正在使用的模型替换掉；
                            // 当前模型始终从 Codex 自己的配置重新读取。
                            if agent.holdsModelList {
                                beginSync(agent, providerID: entry.id, model: entry.model)
                            } else {
                                model.addModelToDefault(providerID: entry.id)
                            }
                        }
                        .disabled(isAlreadyAdded)
                        .help(isAlreadyAdded
                              ? (isCurrent ? "这个模型客户端里现在写的就是它，不用再加一遍"
                                           : "这个模型已经在客户端配置中，不用重复添加")
                              : (model.providerEnabled(entry.id)
                                 ? (agent.holdsModelList
                                    ? "把这个模型加入 \(agent.name) 的模型列表"
                                    : "加入 default 统一路由，不改 \(agent.name) 当前正在使用的模型")
                                 : "已停用：先在「本地路由」重新启用这一行"))
                    }
                }
            }
        }
    }

    /// 所有菜单按钮长同一样子，粉底白字；样式集中在这里改一次就够。
    private func styledMenu<Content: View>(icon: String, title: String, help: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HubInk.accent))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
    }

    /// 一条线路上能切的模型（含当前用的那个）。判定规则在数据层，界面只管画。
    private func switchCandidates(_ agent: HubDetectedAgent) -> [HubModel.SwitchOption] {
        model.switchableModels(route: agent.modelRoute,
                               currentModel: agent.currentModel,
                               clientID: agent.id)
    }

    private func hasAddableModel(_ agent: HubDetectedAgent) -> Bool {
        let visible = switchCandidates(agent)
        let visibleIDs = Set(visible.map { $0.model.id })
        let visibleNames = Set(visible.map {
            $0.model.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let configuredNames = Set(agent.configuredModels.map {
            $0.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return model.poolModels.contains { entry in
            let name = entry.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !visibleIDs.contains(entry.id)
                && !visibleNames.contains(name)
                && !configuredNames.contains(name)
        }
    }

    /// 这条线路上能切的一个模型：正在用的那个加选中标记且不可点，其余点一下就切。
    ///
    /// 「哪个是当前」「哪个没绑在这条线路上」由数据层判定（`SwitchOption.isCurrent` /
    /// `.isUnbound`），这里不再自己拿模型名去比线路 id —— 那种比法永远不相等，
    /// 当前那一行会连标记都不显示。
    @ViewBuilder
    private func switchChip(_ entry: HubModel.SwitchOption,
                            enabled: Bool = true,
                            routeOnly: Bool = false,
                            onSwitch: @escaping () -> Void) -> some View {
        let supplier = entry.model.supplier ?? "本地路由"
        let label = HStack(spacing: 5) {
            if entry.isCurrent {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
            }
            Text(entry.model.model).font(.system(size: 11, design: .monospaced))
            // 「未绑定」不再逐片挂在名字后面：15 片里 12 片都挂着它，看着像这一排全有毛病，
            // 而它只是「不属于这条线路、网关按名字也接得上」，切过去还会自动绑进来。这条信息
            // 降级到 tooltip 和列表下面那一行说一次，颜色还给供应商 —— 和下面 ZCode 那张卡的
            // 「客户端模型」标签用同一套色（`modelTint`），两张卡看着才是一台机器上的东西。
            if entry.isDisabled {
                Text("已停用")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(HubInk.muted.opacity(0.18)))
                    .foregroundStyle(HubInk.sub)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .frame(minWidth: 132, alignment: .leading)

        if entry.isCurrent {
            // 当前这一片用同一个供应商色、只把底色压深一档，再加勾：换个色会像是另一种东西。
            label
                .background(Capsule().fill(modelTint(for: supplier).opacity(0.26)))
                .foregroundStyle(modelTint(for: supplier))
                .help(entry.isDisabled
                      ? "当前正在用（这一行在网关那边是停用的，客户端会因为取不到模型而报错）· 供应商：\(supplier)"
                      : (entry.isUnbound
                         ? "当前正在用（没绑在这条线路上，网关按名字从池里接的）· 供应商：\(supplier)"
                         : "当前正在用 · 供应商：\(supplier)"))
        } else if !enabled {
            label
                .background(Capsule().fill(HubInk.muted.opacity(0.08)))
                .overlay(Capsule().stroke(HubInk.muted.opacity(0.35),
                                          style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .foregroundStyle(HubInk.muted)
                .help("当前为只读监测，切换到 AI助手接管路由后才能修改")
        } else if entry.isDisabled {
            Button(action: onSwitch) {
                label
                    .background(Capsule().fill(HubInk.muted.opacity(0.08)))
                    .overlay(Capsule().stroke(HubInk.muted.opacity(0.45),
                                              style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .foregroundStyle(HubInk.muted)
            }
            .buttonStyle(.plain)
            .help((routeOnly
                   ? "加入 4202 分配：\(entry.model.model)（已停用 · 供应商：\(supplier)）\n"
                     + "Codex 当前配置不改；重新启用这条线路后 4202 才会发它"
                   : "切到 \(entry.model.model)（已停用 · 供应商：\(supplier)）\n"
                     + "切过去之后要去「本地路由」重新启用这一行，网关才会发它"))
        } else {
            // 和 ZCode 那张卡的「客户端模型」标签同一种画法：供应商色淡底 + 同色字。
            Button(action: onSwitch) {
                label
                    .background(Capsule().fill(modelTint(for: supplier).opacity(0.15)))
                    .foregroundStyle(modelTint(for: supplier))
            }
                .buttonStyle(.plain)
                .help(entry.isUnbound
                  ? (routeOnly
                     ? "加入 4202 分配：\(entry.model.model)（供应商：\(supplier)）\n"
                       + "Codex 当前配置不改；只更新 router.json 的 client_assignments.codex"
                     : "切到 \(entry.model.model)（供应商：\(supplier)）\n"
                       + "没绑在这条线路上：网关会按名字在池里找到它、发它，默认还会把它绑进这条线路")
                  : (routeOnly
                     ? "加入 4202 分配：\(entry.model.model)（供应商：\(supplier)）\n"
                       + "Codex 当前配置不改；只更新 router.json 的 client_assignments.codex"
                     : "切到 \(entry.model.model)（供应商：\(supplier)）"))
        }
    }

    private var bottomActions: some View {
        HStack(spacing: 10) {
            // 「扫描配置文件」和「重新扫描」原本是同一个动作（都只调 model.refresh()），
            // 两个按钮并排却没有区别，属于冗余入口，这里合并成一个。
            HubPageButton(title: "重新扫描客户端配置", width: 168, filled: true) {
                model.refresh()
                model.notify("已重新扫描客户端配置文件")
            }
            HubPageButton(title: "查看备份记录", width: 148, filled: false) {
                let directory = HubAgentSync.backupsDirectory
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(directory)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var safetyBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("安全提示").font(.system(size: 12)).foregroundStyle(HubInk.tintInk)
            Text("同步会先备份，并预览即将修改的字段。")
                .font(.system(size: 12)).foregroundStyle(HubInk.tintInk)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubInk.tint))
    }

    private func beginSync(_ agent: HubDetectedAgent, providerID: String?, model newModel: String) {
        guard canWrite(agent) else {
            model.notify("\(agent.name) 当前为只读：未修改客户端配置", ok: false)
            return
        }
        if agent.id == "codex", model.isReadOnlyMode, let fileURL = agent.configURL {
            model.applyReadOnlyCodexModel(fileURL: fileURL, model: newModel)
            return
        }
        // Codex / ZCode 走统一适配器：预览真实 diff、写前备份、写后读回验证。
        if let providerID,
           let client = HubStrategySync.client(id: agent.id, name: agent.name,
                                               path: agent.configURL?.path ?? "") {
            model.addModelToClient(clientID: client.rawValue,
                                   clientName: agent.name,
                                   clientPath: agent.configURL?.path ?? agent.path,
                                   providerID: providerID,
                                   modelID: newModel)
            return
        }
        if providerID != nil {
            model.notify("\(agent.name) 暂不支持安全同步（需要 Codex 或 ZCode 配置适配器）", ok: false)
            return
        }
        guard let url = agent.configURL else {
            model.notify("\(agent.name) 没有可写配置文件", ok: false)
            return
        }
        do {
            pendingSync = try HubAgentSync.plan(agentName: agent.name, fileURL: url)
            pendingModel = newModel
        } catch {
            model.notify(error.localizedDescription, ok: false)
        }
    }
}

private struct HubAgentModelDropDelegate: DropDelegate {
    let item: String
    @Binding var items: [String]
    @Binding var draggedItem: String?

    func dropEntered(info: DropInfo) {
        guard let draggedItem, draggedItem != item,
              let from = items.firstIndex(of: draggedItem),
              let to = items.firstIndex(of: item) else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }
}

private struct HubAgentRouteDropDelegate: DropDelegate {
    let item: String
    @Binding var items: [String]
    let commit: () -> Void
    @Binding var draggedItem: String?

    func dropEntered(info: DropInfo) {
        guard let draggedItem, draggedItem != item,
              let from = items.firstIndex(of: draggedItem),
              let to = items.firstIndex(of: item) else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        commit()
        draggedItem = nil
        return true
    }
}

// MARK: - Jev 档位映射

struct HubJevPage: View {
    @ObservedObject var model: HubModel
    @State private var draft: [String: [String]] = [:]
    @State private var draggedByTier: [String: String] = [:]

    private let captions: [String: String] = [
        "luna": "轻量、快速任务",
        "terra": "日常开发任务",
        "sol": "复杂编码任务",
        "astra": "最强推理任务",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubPageHeader(
                title: "Jev 档位",
                subtitle: "把 Jev 自动选择的 Luna / Terra / Sol / Astra 档位映射到本地路由模型。"
            )
            Spacer().frame(height: 24)
            mappingNotice
            Spacer().frame(height: 20)
            ForEach(model.tierNames, id: \.self) { tier in
                tierCard(tier)
                if tier != model.tierNames.last { Spacer().frame(height: 20) }
            }
            Spacer().frame(height: 32)
            HStack(spacing: 10) {
                HubPageButton(title: "保存映射", width: 148, filled: true) { model.saveTiers(draft) }
                HubPageButton(title: "恢复默认", width: 148, filled: false) { draft = model.defaultTierCandidates }
                Spacer(minLength: 0)
                Text("每档可选择多个模型；从上到下依次尝试。整档失败后返回 Jev 重新决策。")
                    .font(.system(size: 11)).foregroundStyle(HubInk.tableHead)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 26)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            model.refresh()
            draft = model.defaultTierCandidates
        }
    }

    private var mappingNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("映射策略").font(.system(size: 13, weight: .medium)).foregroundStyle(HubInk.tintInk)
            Text("Jev 根据任务复杂度选择档位；映射变更写入 router.json，运行中的 Jev 下一次决策读取。")
                .font(.system(size: 12)).foregroundStyle(HubInk.tintInk)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubInk.tint))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(Color(red: 0.863, green: 0.886, blue: 1.0), lineWidth: 1))
    }

    private func tierCard(_ tier: String) -> some View {
        let providerIDs = draft[tier] ?? model.defaultTierCandidates[tier] ?? []
        let entries = providerIDs.compactMap { id in
            model.internalJevModels.first(where: { $0.id == id })
        }
        let letter = String(tier.prefix(1)).uppercased()
        return HStack(spacing: 18) {
            Text(letter).font(.system(size: 19, weight: .medium)).foregroundStyle(HubInk.accent)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(HubInk.tint))
            VStack(alignment: .leading, spacing: 4) {
                Text(tier.capitalized).font(.system(size: 14)).foregroundStyle(HubInk.ink)
                Text(captions[tier] ?? "").font(.system(size: 11)).foregroundStyle(HubInk.muted)
            }
            .frame(minWidth: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                Menu {
                    ForEach(model.internalJevModels) { item in
                        Button {
                            toggle(item.id, in: tier)
                        } label: {
                            Label(model.modelName(providerID: item.id),
                                  systemImage: providerIDs.contains(item.id) ? "checkmark.square" : "square")
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(entries.isEmpty ? "未设置模型" : "已选 \(entries.count) 个模型")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(HubInk.ink)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(HubInk.accent)
                    }
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)

                ForEach(entries) { entry in
                    tierModelRow(entry, tier: tier)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(HubInk.line, lineWidth: 1))
    }

    private func toggle(_ id: String, in tier: String) {
        var values = draft[tier] ?? []
        if let index = values.firstIndex(of: id) {
            values.remove(at: index)
        } else {
            values.append(id)
        }
        draft[tier] = values
    }

    private func tierModelRow(_ entry: HubModel.Model, tier: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HubInk.faint)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.model).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(HubInk.ink)
                Text(entry.supplier ?? "本地路由").font(.system(size: 10)).foregroundStyle(HubInk.muted)
            }
            Spacer(minLength: 4)
            Button { toggle(entry.id, in: tier) } label: {
                Image(systemName: "xmark.circle").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(HubInk.faint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(HubInk.band))
        .onDrag {
            draggedByTier[tier] = entry.id
            return NSItemProvider(object: entry.id as NSString)
        }
        .onDrop(of: [.text], delegate: HubTierDropDelegate(
            item: entry.id,
            items: tierBinding(tier),
            draggedItem: Binding(
                get: { draggedByTier[tier] },
                set: { draggedByTier[tier] = $0 }
            )
        ))
    }

    private func tierBinding(_ tier: String) -> Binding<[String]> {
        Binding(
            get: { draft[tier] ?? [] },
            set: { draft[tier] = $0 }
        )
    }
}

private struct HubTierDropDelegate: DropDelegate {
    let item: String
    @Binding var items: [String]
    @Binding var draggedItem: String?

    func dropEntered(info: DropInfo) {
        guard let draggedItem, draggedItem != item,
              let from = items.firstIndex(of: draggedItem),
              let to = items.firstIndex(of: item) else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }
}
