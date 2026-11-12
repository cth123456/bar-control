import AppKit
import Darwin

/// 只读取系统当前连接，不启动随航管家，也不执行连接、断开或通用控制修复。
@MainActor
enum SidecarConnectionMonitor {
    static private(set) var connectedDevices: [String]?
    private static var refreshing = false
    private static var lastRefresh = Date.distantPast

    static func refreshIfNeeded(onUpdate: @escaping @MainActor () -> Void) {
        guard !refreshing, Date().timeIntervalSince(lastRefresh) >= 5 else { return }
        refreshing = true
        Task {
            let names = await Task.detached(priority: .utility) { SidecarConnectionReader.read() }.value
            connectedDevices = names
            lastRefresh = Date()
            refreshing = false
            onUpdate()
        }
    }
}

private enum SidecarConnectionReader {
    private static let frameworkLoaded = dlopen(
        "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_NOW
    ) != nil

    static func read() -> [String]? {
        // 与随航管家使用相同的只读 connectedDevices 接口，可识别外部快捷指令的连接。
        let shared = NSSelectorFromString("sharedManager")
        let connected = NSSelectorFromString("connectedDevices")
        guard frameworkLoaded,
              let type = NSClassFromString("SidecarDisplayManager") as? NSObject.Type,
              type.responds(to: shared),
              let manager = type.perform(shared)?.takeUnretainedValue() as? NSObject,
              manager.responds(to: connected),
              let devices = manager.perform(connected)?.takeUnretainedValue() as? [NSObject] else {
            return nil
        }
        return devices.map { device in
            let name = NSSelectorFromString("name")
            guard device.responds(to: name),
                  let value = device.perform(name)?.takeUnretainedValue() as? String,
                  !value.isEmpty else { return "iPad" }
            return value
        }
    }
}
