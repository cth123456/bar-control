import AppKit
import SwiftUI

/// 菜单栏快捷面板：开麦 / 打字 / 最近一次，一屏说完，点「中枢」回到完整窗口。
///
/// 面板不自己存状态：状态、文案、阶段、麦克风电平全部读 `HubHomeBridge`
/// （它同时也是中枢首页的来源），所以面板和窗口永远说的是同一件事。
struct VoicePopoverView: View {
    @ObservedObject var bridge: HubHomeBridge
    @State private var tab = Tab.voice
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    enum Tab: String, CaseIterable, Identifiable {
        case voice
        case typing

        var id: String { rawValue }
        var title: String { self == .voice ? "语音" : "打字" }
        var icon: String { self == .voice ? "mic.fill" : "keyboard.fill" }
        var hint: String {
            self == .voice
                ? "点麦克风开麦，说完停约 2 秒自动结束；⌘D 也能开麦"
                : "回车发送，和语音走同一条流水线"
        }
    }

    /// 阶段行直接读对话页那套枚举，名字和顺序都跟着它走，免得两边各写一份慢慢对不上。
    private static let stages = ChatPanelView.Stage.allCases

    /// 0 = 待机，1 = 聆听（唯一有电平的阶段）。
    private var isRecording: Bool { bridge.stageIndex == ChatPanelView.Stage.listening.rawValue }
    private var busy: Bool { bridge.busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            picker
            if tab == .voice { voiceZone } else { typingZone }
            lastExchange
            footer
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
        .background(HubInk.page)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubInk.tint)
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HubInk.accent)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("AI助手")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(HubInk.ink)
                Text("本地中枢 · 麦克风默认关闭")
                    .font(.system(size: 10.5))
                    .foregroundStyle(HubInk.muted)
            }

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                // 忙碌时状态点跟着状态色变红，扫一眼就知道现在别重复开麦。
                Circle().fill(busy ? HubInk.dotBad : bridge.tint).frame(width: 7, height: 7)
                Text(bridge.status)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(HubInk.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(HubInk.band))
            .overlay(Capsule().stroke(HubInk.line, lineWidth: 1))

            iconButton("arrow.up.forward.app", help: "打开中枢窗口") {
                bridge.onOpenPage?(.voice)
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HubInk.accent)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HubInk.tint))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var picker: some View {
        HStack(spacing: 3) {
            ForEach(Tab.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { tab = item }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon).font(.system(size: 10.5, weight: .semibold))
                        Text(item.title).font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tab == item ? HubInk.card : Color.clear)
                            .shadow(color: tab == item ? Color.black.opacity(0.07) : .clear, radius: 3, y: 1)
                    )
                    .foregroundStyle(tab == item ? HubInk.accent : HubInk.sub)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HubInk.tint))
    }

    // MARK: - 语音

    private var voiceZone: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                micButton
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(bridge.status.isEmpty ? "待机" : bridge.status)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(HubInk.onDark)
                            .lineLimit(1)
                        if !shortRoute.isEmpty {
                            Text(shortRoute)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.white.opacity(0.10)))
                                .foregroundStyle(HubInk.onDarkSub)
                                .lineLimit(1)
                        }
                    }
                    Text(bridge.detail.isEmpty ? Tab.voice.hint : bridge.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(HubInk.onDarkSub)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(bridge.detail)
                }
            }

            if busy { levelBar }
            stages

            HStack(spacing: 8) {
                primaryButton
                Spacer(minLength: 0)
                Text(Tab.voice.hint)
                    .font(.system(size: 10))
                    .foregroundStyle(HubInk.onDarkSub.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .padding(14)
        .background(
            ZStack {
                // 麦克风后面一点微光，让「这里就是可以说话的地方」一眼可见。
                RadialGradient(
                    colors: [HubInk.accent.opacity(isRecording ? 0.32 : 0.16), Color.clear],
                    center: .init(x: 0.16, y: 0.28),
                    startRadius: 4,
                    endRadius: 150
                )
                HubInk.hero
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var micButton: some View {
        Button {
            bridge.onToggleVoice?()
        } label: {
            ZStack {
                Circle()
                    .fill((isRecording ? HubInk.red : HubInk.accent).opacity(0.16))
                    .frame(width: 54, height: 54)
                Circle()
                    .fill(isRecording ? HubInk.red : HubInk.accent)
                    .frame(width: 40, height: 40)
                Image(systemName: isRecording ? "stop.fill" : (busy ? "xmark" : "mic.fill"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .scaleEffect(isRecording ? 1 + CGFloat(min(max(bridge.level, 0), 1)) * 0.10 : 1)
            .animation(.easeOut(duration: 0.14), value: bridge.level)
        }
        .buttonStyle(.plain)
        .help(isRecording ? "说完了（再点一次也会结束）" : busy ? "取消本次对话" : "开始说话（⌘D）")
    }

    private var primaryButton: some View {
        Button {
            if busy { bridge.onCancelVoice?() } else { bridge.onToggleVoice?() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: busy ? "xmark" : "mic.fill").font(.system(size: 11, weight: .semibold))
                Text(busy ? "取消本次对话" : "开始说话").font(.system(size: 12.5, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(busy ? Color.white.opacity(0.14) : HubInk.accent)
            )
            .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
    }

    private var levelBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(isRecording ? HubInk.red.opacity(0.9) : HubInk.accent)
                    .frame(width: max(2, geo.size.width * CGFloat(min(max(bridge.level, 0), 1))))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.12), value: bridge.level)
    }

    private var stages: some View {
        HStack(spacing: 6) {
            ForEach(Self.stages, id: \.rawValue) { stage in
                let active = stage.rawValue == bridge.stageIndex
                let passed = stage.rawValue < bridge.stageIndex
                HStack(spacing: 4) {
                    if stage != Self.stages[0] {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(HubInk.onDarkSub.opacity(0.45))
                    }
                    Text(stage.title)
                        .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? HubInk.onDark : HubInk.onDarkSub.opacity(passed ? 0.9 : 0.5))
                        .padding(.horizontal, active ? 7 : 0)
                        .padding(.vertical, active ? 2 : 0)
                        .background(Capsule().fill(active ? Color.white.opacity(0.14) : Color.clear))
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 打字

    private var typingZone: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("打字问一句，回车发送", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(HubInk.ink)
                    .focused($draftFocused)
                    .onSubmit { send() }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubInk.card))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(HubInk.line, lineWidth: 1))

                Button {
                    send()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "paperplane.fill").font(.system(size: 10.5, weight: .semibold))
                        Text("发送").font(.system(size: 12, weight: .semibold))
                    }
                    .frame(width: 74, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubInk.accent))
                    .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }

            Text(busy ? bridge.detail : Tab.typing.hint)
                .font(.system(size: 10.5))
                .foregroundStyle(busy ? HubInk.muted : HubInk.hint)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HubInk.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(HubInk.line, lineWidth: 1))
        .onAppear { draftFocused = true }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        bridge.onAsk?(text)
    }

    // MARK: - 最近一次

    private var lastExchange: some View {
        HubCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("最近一次")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HubInk.muted)
                    Spacer(minLength: 0)
                    if !bridge.lastAnswer.isEmpty {
                        smallAction("复制回答", icon: "doc.on.doc") { bridge.onCopyAnswer?() }
                        smallAction("重播", icon: "speaker.wave.2") { bridge.onReplayAnswer?() }
                    }
                }

                if bridge.lastQuestion.isEmpty && bridge.lastAnswer.isEmpty {
                    Text("还没有对话。用上面的语音或打字问一句，这里会留下最后一次问答。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(HubInk.faint)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if !bridge.lastQuestion.isEmpty {
                        exchangeLine("你", bridge.lastQuestion, tint: HubInk.accent)
                    }
                    if !bridge.lastAnswer.isEmpty {
                        exchangeLine("中枢", bridge.lastAnswer, tint: HubInk.green)
                    }
                    if !bridge.lastRoute.isEmpty {
                        Text(bridge.lastRoute)
                            .font(.system(size: 10))
                            .foregroundStyle(HubInk.hint)
                            .lineLimit(2)
                            .help(bridge.lastRoute)
                    }
                }
            }
        }
    }

    private func exchangeLine(_ label: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, alignment: .leading)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(HubInk.ink)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func smallAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(HubInk.band))
            .foregroundStyle(HubInk.sub)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 页脚

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(HubInk.line)
                .frame(height: 1)
            HStack(spacing: 6) {
                footerButton("中枢首页") { bridge.onOpenPage?(.home) }
                footerButton("运行状态") { bridge.onOpenPage?(.status) }
                footerButton("配置目录") { bridge.onRevealSupportDirectory?() }
                Spacer(minLength: 0)
                footerButton("退出", tint: HubInk.badText) { bridge.onQuit?() }
            }
        }
        .padding(.top, 2)
    }

    private func footerButton(_ title: String, tint: Color = HubInk.sub, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(HubInk.band))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    /// 线路文案太长，面板里只留「哪条线路」，完整事实仍然在最近一次的灰字里。
    private var shortRoute: String {
        var text = bridge.lastRoute
        if text.hasPrefix("线路：") { text.removeFirst("线路：".count) }
        if let arrow = text.range(of: " → ") { text = String(text[text.startIndex..<arrow.lowerBound]) }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "" : "线路 \(text)"
    }
}
