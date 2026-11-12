import XCTest
@testable import CodexTouchBarNative

final class ServiceRegistryTests: XCTestCase {
    func testTemplateCreatesDeclarativeServiceWithFolderAction() throws {
        let template = ServiceMonitor.ServiceTemplate(
            name: "示例服务", role: "测试用途", kind: "launchAgent",
            label: "com.example.service", processName: nil, port: nil, path: nil,
            isScheduled: true, appPath: nil,
            revealPath: "Library/Logs/ExampleService",
            logDirectory: "Library/Logs/ExampleService"
        )
        let service = try XCTUnwrap(template.service)
        XCTAssertEqual(service.action, .reveal(path: "Library/Logs/ExampleService"))
        XCTAssertEqual(service.actionTitle, "打开功能文件夹")
        XCTAssertTrue(service.isScheduled)
        XCTAssertEqual(service.scheduleLabel, "定时")
        XCTAssertEqual(service.diagnosticSubject, "com.example.service")
    }

    func testInvalidTemplateDoesNotCrash() {
        let template = ServiceMonitor.ServiceTemplate(
            name: "坏配置", role: "", kind: "unknown", label: nil, processName: nil,
            port: nil, path: nil, isScheduled: false, appPath: nil,
            revealPath: nil, logDirectory: nil
        )
        XCTAssertNil(template.service)
    }

    func testRegistryEntriesAreHiddenWhenNothingIsInstalled() {
        let home = URL(fileURLWithPath: "/Users/fresh")
        let services = MainActor.assumeIsolated { ServiceMonitor.registry() }
        for service in services {
            XCTAssertFalse(service.isInstalled(home: home, exists: { _ in false }),
                           "\(service.name) should not appear on a clean Mac")
        }
    }

    func testLaunchAgentIsShownWhenPlistOrLogDirectoryExists() {
        let home = URL(fileURLWithPath: "/Users/fresh")
        let service = MainActor.assumeIsolated { ServiceMonitor.registry() }
            .first { if case .launchAgent = $0.kind { return true }; return false }!
        let plist = home.appendingPathComponent("Library/LaunchAgents/com.global-memory.plist").path
        XCTAssertTrue(service.isInstalled(home: home, exists: { $0 == plist }))
        XCTAssertFalse(service.isInstalled(home: home, exists: { _ in false }))
    }

    func testBuiltInRegistryUsesDeclarativeActions() {
        for service in MainActor.assumeIsolated({ ServiceMonitor.registry() }) {
            if service.action != nil {
                XCTAssertTrue(service.actionTitle?.isEmpty == false)
            }
            switch service.action {
            case .app(let path):
                XCTAssertTrue(path.hasPrefix("/Applications/"))
            case .reveal(let path):
                // 功能文件夹可以是用户主目录下的任意相对路径（如 .config/magpie），
                // 不能是绝对路径或越出主目录的 .. 引用。
                XCTAssertTrue(!path.hasPrefix("/") && !path.contains(".."))
            case nil:
                break
            }
        }
    }
}
