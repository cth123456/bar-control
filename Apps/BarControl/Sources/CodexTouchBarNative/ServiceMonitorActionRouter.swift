import AppKit

/// Routes declarative service actions from the services window and menu.
/// New services only declare a target path; no controller changes needed.
@MainActor
final class ServiceMonitorActionRouter: NSObject {
    static let shared = ServiceMonitorActionRouter()

    private var actions: [String: ServiceMonitor.Service] = [:]

    func register(id: String, service: ServiceMonitor.Service) {
        actions[id] = service
    }

    func perform(service: ServiceMonitor.Service) {
        guard let action = service.action else { return }
        switch action {
        case .app(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .reveal(let relativePath):
            openFolder(service.folderPath ?? relativePath)
        }
    }

    func openApp(service: ServiceMonitor.Service) {
        guard let path = service.appPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openFolder(_ relativePath: String) {
        let url = resolve(path: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "功能文件夹不存在"
            alert.informativeText = url.path
            alert.runModal()
            return
        }
        if url.hasDirectoryPath {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func resolve(path: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(path)
    }

    @objc func open(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let service = actions[id] else { return }
        perform(service: service)
    }

    @objc func openApp(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let service = actions[id] else { return }
        openApp(service: service)
    }

    @objc func runMenuItem(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? ServiceMonitor.Service else { return }
        perform(service: service)
    }
}
