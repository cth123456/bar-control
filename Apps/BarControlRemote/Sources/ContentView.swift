import QuickLook
import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var model: RemoteViewModel
    @ObservedObject private var speech: SpeechInputController
    @State private var showingSettings = false
    @State private var previewFile: PreviewFile?
    @State private var shareFile: PreviewFile?

    init(model: RemoteViewModel) {
        self.model = model
        speech = model.speech
    }

    var body: some View {
        NavigationStack {
            if model.selectedThreadID != nil || model.isNewConversation {
                chatDetailView
            } else {
                conversationListView
            }
        }
        .sheet(isPresented: $showingSettings) { settingsSheet }
        .sheet(item: $previewFile) { QuickLookPreview(url: $0.url) }
        .sheet(item: $shareFile) { ActivityView(items: [$0.url]) }
    }

    private var conversationListView: some View {
        List {
            connectionCard
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 4, trailing: 14))
            if let notice = model.switchNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                    Text(notice)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        model.switchNotice = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
            }
            if !model.systemItems.isEmpty {
                ForEach(model.systemItems.prefix(4)) { item in
                    SystemEventRow(item: item)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
                }
            }
            if model.filteredConversations.isEmpty {
                ContentUnavailableView(
                    "还没有会话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("发送第一条指令后会在这里生成会话。")
                )
                .listRowSeparator(.hidden)
                .padding(.top, 60)
            } else {
                ForEach(model.filteredConversations) { conversation in
                    Button {
                        model.openConversation(conversation.id, title: conversation.title)
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            model.togglePin(conversation)
                        } label: {
                            Label(
                                conversation.pinned ? "取消置顶" : "置顶",
                                systemImage: conversation.pinned ? "pin.slash" : "pin"
                            )
                        }
                        .tint(conversation.pinned ? .gray : .orange)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("远程 Codex")
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                providerMenu
                projectMenu
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    model.startNewConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("新建会话")
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .refreshable { await model.refresh() }
    }

    private var chatDetailView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let approval = model.pendingApproval {
                        approvalCard(approval)
                    }
                    if model.threadDisplayItems.isEmpty {
                        ContentUnavailableView(
                            "还没有消息",
                            systemImage: "text.bubble",
                            description: Text("输入指令开始对话。")
                        )
                        .padding(.top, 80)
                    } else {
                        ForEach(model.threadDisplayItems) { item in
                            MessageRow(item: item)
                                .id(item.id)
                        }
                    }
                    if !model.threadFiles.isEmpty {
                        fileSection
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: model.threadDisplayItems.last?.id) { _, identifier in
                guard let identifier else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(identifier, anchor: .bottom)
                }
            }
        }
        .navigationTitle(model.selectedConversationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.closeConversation()
                } label: {
                    Label("会话列表", systemImage: "chevron.left")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let selected = model.selectedConversation {
                    Button {
                        model.togglePin(selected)
                    } label: {
                        Image(systemName: selected.pinned ? "pin.fill" : "pin")
                    }
                    .accessibilityLabel(selected.pinned ? "取消置顶" : "置顶")
                }
                conversationModelMenu
                Button {
                    Task { await model.stopCurrentTurn() }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .accessibilityLabel("停止当前任务")
                Button {
                    model.startNewConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("新会话")
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
    }

    private var providerMenu: some View {
        Menu {
            if model.providerNames.isEmpty {
                Button("正在读取供应商…") {}
                    .disabled(true)
            } else {
                ForEach(model.providerNames, id: \.self) { name in
                    Button {
                        Task { await model.switchProvider(name) }
                    } label: {
                        if name == model.currentProviderName {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
        } label: {
            Label(model.currentProviderName ?? "供应商", systemImage: "arrow.triangle.2.circlepath")
        }
    }

    private var projectMenu: some View {
        Menu {
            Button {
                model.filterProject = nil
            } label: {
                if model.filterProject == nil {
                    Label("全部项目", systemImage: "checkmark")
                } else {
                    Text("全部项目")
                }
            }
            ForEach(model.projectFolders, id: \.self) { folder in
                Button {
                    model.filterProject = folder
                } label: {
                    if model.filterProject == folder {
                        Label(folder, systemImage: "checkmark")
                    } else {
                        Text(folder)
                    }
                }
            }
        } label: {
            Label(model.filterProject ?? "项目", systemImage: "folder")
        }
    }

    private var conversationModelMenu: some View {
        Menu {
            if model.modelNames.isEmpty {
                Button("正在读取模型…") {}
                    .disabled(true)
            } else {
                ForEach(model.modelNames, id: \.self) { name in
                    Button {
                        model.switchThreadModel(name)
                    } label: {
                        if name == model.currentThreadModelName {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
        } label: {
            Label(model.currentThreadModelName ?? "模型", systemImage: "cpu")
        }
    }

    private var connectionCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isConnected ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.connectionText)
                    .font(.subheadline.weight(.semibold))
                if let modelName = model.currentModelName, !modelName.isEmpty {
                    Text("模型：\(modelName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(model.latestThreadID.map { "会话 …\($0.suffix(8))" } ?? "新建会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isSending {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .offset(y: 18)
            }
        }
        .padding(.bottom, model.errorMessage == nil ? 0 : 16)
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("文件")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(model.threadFiles) { file in
                FileCard(model: model, file: file) { url in
                    previewFile = PreviewFile(url: url)
                } onShare: { url in
                    shareFile = PreviewFile(url: url)
                }
            }
        }
        .padding(.top, 8)
    }

    private func approvalCard(_ event: RemoteEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("等待确认", systemImage: "exclamationmark.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            if !event.text.isEmpty {
                Text(event.text)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            HStack {
                Button {
                    Task { await model.answerApproval(event, accepted: true) }
                } label: {
                    Text("允许").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                Button {
                    Task { await model.answerApproval(event, accepted: false) }
                } label: {
                    Text("拒绝").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                if model.isNewConversation {
                    Menu {
                        ForEach(model.projectFolders, id: \.self) { folder in
                            Button {
                                model.workingDirectory = model.projectPaths[folder] ?? model.workingDirectory
                            } label: {
                                if folder == model.currentProjectFolderName {
                                    Label(folder, systemImage: "checkmark")
                                } else {
                                    Text(folder)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("选择项目文件夹")
                }
                Button {
                    Task { await model.toggleSpeech() }
                } label: {
                    Image(systemName: speech.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
                TextField("输入指令", text: $model.prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.11), in: RoundedRectangle(cornerRadius: 16))
                Button {
                    Task { await model.sendPrompt() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                }
                .buttonStyle(.plain)
                .disabled(model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
            }
            if let error = speech.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Mac 工作目录") {
                    TextField("路径", text: $model.workingDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("同步") {
                    Button("立即刷新") { Task { await model.refresh() } }
                    Button("清除手机时间线", role: .destructive) { model.clearLocalTimeline() }
                }
                Section {
                    Text("账号凭据始终保存在 Mac。iPhone 只通过你的 iCloud 私有数据库发送指令和接收事件。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("远程设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showingSettings = false }
                }
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: RemoteConversation

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 20))
                .foregroundStyle(.blue)
                .frame(width: 40, height: 40)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if conversation.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(conversation.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                if !conversation.subtitle.isEmpty {
                    Text(conversation.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !conversation.projectFolder.isEmpty {
                    Label(conversation.projectFolder, systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(conversation.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("\(conversation.messageCount) 条")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct MessageRow: View {
    let item: RemoteDisplayItem

    var body: some View {
        switch item.kind {
        case .userInput:
            HStack {
                Spacer(minLength: 60)
                bubble
                    .padding(10)
                    .background(Color.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .agentMessageDelta:
            HStack {
                bubble
                    .padding(10)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer(minLength: 60)
            }
        default:
            SystemEventRow(item: item)
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if item.kind == .agentMessageDelta,
           let attributed = try? AttributedString(markdown: item.text) {
            Text(attributed)
                .font(.callout)
                .textSelection(.enabled)
        } else {
            Text(item.text)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}

private struct SystemEventRow: View {
    let item: RemoteDisplayItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(item.title.isEmpty ? item.kind.rawValue : item.title)
                .font(.caption)
                .foregroundStyle(color)
            if !item.text.isEmpty {
                Text(item.text)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer()
            Text(item.createdAt, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch item.kind {
        case .turnCompleted, .providerChanged, .approvalResolved: return .green
        case .turnFailed, .error: return .red
        case .approvalRequired, .warning: return .orange
        case .commandOutputDelta: return .teal
        case .modelChanged: return .blue
        default: return .secondary
        }
    }

    private var icon: String {
        switch item.kind {
        case .connection: return "link"
        case .userInput, .transcript: return "person.crop.circle"
        case .localIntent: return "brain.head.profile"
        case .planDelta, .reasoningSummaryDelta: return "list.bullet.clipboard"
        case .commandOutputDelta: return "terminal"
        case .fileChange: return "doc.badge.gearshape"
        case .toolActivity, .actionStarted, .actionProgress: return "wrench.and.screwdriver"
        case .approvalRequired: return "exclamationmark.shield"
        case .approvalResolved: return "checkmark.shield.fill"
        case .providerChanged: return "arrow.triangle.2.circlepath"
        case .turnStarted: return "play.fill"
        case .turnCompleted: return "checkmark.circle.fill"
        case .turnFailed, .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .agentMessageDelta: return "sparkles"
        case .modelChanged: return "cpu"
        }
    }
}

private struct FileCard: View {
    let model: RemoteViewModel
    let file: RemoteFileInfo
    let onPreview: (URL) -> Void
    let onShare: (URL) -> Void
    @State private var isDownloading = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) · \(file.mimeType)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isDownloading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    download(onPreview)
                } label: {
                    Image(systemName: "eye.fill")
                }
                .accessibilityLabel("预览")
                Button {
                    download(onShare)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享")
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func download(_ action: @escaping (URL) -> Void) {
        isDownloading = true
        Task {
            let url = await model.downloadFile(file)
            await MainActor.run { isDownloading = false }
            if let url {
                action(url)
            }
        }
    }

    private var icon: String {
        switch (file.mimeType.split(separator: "/").first ?? "") {
        case "image": return "photo"
        case "video": return "film"
        case "audio": return "waveform"
        case "text": return "doc.text"
        default: return "doc"
        }
    }
}

private struct PreviewFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
