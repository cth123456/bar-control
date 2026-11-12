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
