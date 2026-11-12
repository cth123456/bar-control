import AppKit
import Darwin
import ObjectiveC.runtime
import PowerTelemetrySupport

@MainActor
enum ControlStrip {
    private typealias PresenceFunction = @convention(c) (NSString, Bool) -> Void
    private typealias CloseBoxFunction = @convention(c) (Bool) -> Void

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/Versions/A/DFRFoundation",
        RTLD_NOW
    )

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let value = dlsym(handle, name) else { return nil }
        return unsafeBitCast(value, to: T.self)
    }

    static var isSupported: Bool {
        (NSTouchBarItem.self as AnyObject).responds(to: NSSelectorFromString("addSystemTrayItem:"))
    }

    @discardableResult
    static func add(_ item: NSTouchBarItem) -> Bool {
        let selector = NSSelectorFromString("addSystemTrayItem:")
        guard (NSTouchBarItem.self as AnyObject).responds(to: selector) else { return false }
        _ = (NSTouchBarItem.self as AnyObject).perform(selector, with: item)
        symbol("DFRElementSetControlStripPresenceForIdentifier", as: PresenceFunction.self)?(
            item.identifier.rawValue as NSString,
            true
        )
        return true
    }

    static func remove(_ item: NSTouchBarItem) {
        symbol("DFRElementSetControlStripPresenceForIdentifier", as: PresenceFunction.self)?(
            item.identifier.rawValue as NSString,
            false
        )
        let selector = NSSelectorFromString("removeSystemTrayItem:")
        guard (NSTouchBarItem.self as AnyObject).responds(to: selector) else { return }
        _ = (NSTouchBarItem.self as AnyObject).perform(selector, with: item)
    }

    /// 控制关闭钮是否在前台应用时显示在模态栏左侧。
    static func setShowsCloseBoxWhenFrontMost(_ shows: Bool) {
        symbol("DFRSystemModalShowsCloseBoxWhenFrontMost", as: CloseBoxFunction.self)?(shows)
    }

    /// 永久固定关闭钮策略。只在进程启动时调用一次：
    /// 反复调用这个全局 DFR 开关，会连带触发系统重建模态，使内容 item 与
    /// Control Strip 托盘项短暂脱钩，表现为“只剩叉号、中间整段空白”。
    static func fixCloseBoxPolicy(shows: Bool) {
        setShowsCloseBoxWhenFrontMost(shows)
    }

    /// 以系统模态呈现。关闭钮显隐会改变模态起始偏移，调用方应尽量保持不变，
    /// 避免整排模块随关闭钮出现/消失而左右平移。
    @discardableResult
    static func present(
        _ touchBar: NSTouchBar,
        from identifier: NSTouchBarItem.Identifier,
        showsCloseBox: Bool? = nil
    ) -> Bool {
        if let showsCloseBox {
            setShowsCloseBoxWhenFrontMost(showsCloseBox)
        }
        for name in [
            "presentSystemModalTouchBar:systemTrayItemIdentifier:",
            "presentSystemModalFunctionBar:systemTrayItemIdentifier:"
        ] {
            let selector = NSSelectorFromString(name)
            guard (NSTouchBar.self as AnyObject).responds(to: selector) else { continue }
            _ = (NSTouchBar.self as AnyObject).perform(
                selector,
                with: touchBar,
                with: identifier.rawValue
            )
            return true
        }
        return false
    }

    static func dismiss(_ touchBar: NSTouchBar) {
        for name in ["dismissSystemModalTouchBar:", "dismissSystemModalFunctionBar:"] {
            let selector = NSSelectorFromString(name)
            guard (NSTouchBar.self as AnyObject).responds(to: selector) else { continue }
            _ = (NSTouchBar.self as AnyObject).perform(selector, with: touchBar)
            return
        }
    }

    /// 把系统 Touch Bar 从原生 F1–F12 模式切回“App 控制条”，再重新挂载我们的模态。
    /// 用户按 Fn、切到原生功能键、或在设置里选择功能键显示时，系统会整体替换
    /// Touch Bar 内容；此时我们的模态仍然存在，但中间区不显示任何模块。
    @discardableResult
    static func restoreAppControlMode() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = [
            "write", "com.apple.touchbar.agent",
            "PresentationModeGlobal", "appWithControlStrip"
        ]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        if process.terminationStatus != 0 { return false }
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        restart.arguments = ["ControlStrip"]
        do {
            try restart.run()
            restart.waitUntilExit()
        } catch {
            return false
        }
        return restart.terminationStatus == 0
    }
}

@MainActor
final class TouchBarPower {
    private typealias TurnOn = @convention(c) (AnyObject, Selector) -> Bool
    private typealias ReadInteger = @convention(c) (AnyObject, Selector) -> Int
    private typealias DimToStep = @convention(c) (AnyObject, Selector, Int) -> Bool

    private let client: NSObject?

    init() {
        let bundle = Bundle(path: "/System/Library/PrivateFrameworks/DFRBrightness.framework")
        let loaded = bundle?.load() == true
        let brightnessClass = NSClassFromString("DFRBrightnessClient") as? NSObject.Type
        client = loaded ? brightnessClass?.init() : nil
    }

    func ensureVisible() -> Bool {
        guard let client else { return false }
        let selector = NSSelectorFromString("turnOn")
        guard client.responds(to: selector) else { return false }
        let turnOn = unsafeBitCast(client.method(for: selector), to: TurnOn.self)
        return turnOn(client, selector)
    }

    func currentDimmingStep() -> Int? {
        readInteger(selectorName: "getDimmingStep")
    }

    var displayState: Int? {
        readInteger(selectorName: "displayState")
    }

    func maximizeIfVisible() -> Bool {
        dimIfVisible(to: Self.maximumBrightnessStep)
    }

    /// 0 仅表示没有额外空闲调暗，不能代表实际背光已达最高。
    static let maximumBrightnessStep = 0

    func actualBrightness() -> BCPTTouchBarBrightness? {
        var snapshot = BCPTTouchBarBrightness()
        return bcpt_touchbar_brightness_read(&snapshot) ? snapshot : nil
    }

    func setActualBrightness(_ level: Double) -> Bool {
        bcpt_touchbar_brightness_set(level)
    }

    /// 仅在 Touch Bar 已点亮时调节调光档位：数字越小越亮，0 最亮。
    @discardableResult
    func dimIfVisible(to step: Int, force: Bool = false) -> Bool {
        guard displayState == 2 else { return false }
        guard force || currentDimmingStep() != step else { return true }
        guard let client else { return false }
        let selector = NSSelectorFromString("dimToStep:")
        guard client.responds(to: selector) else { return false }
        let dimToStep = unsafeBitCast(client.method(for: selector), to: DimToStep.self)
        return dimToStep(client, selector, step)
    }

    private func readInteger(selectorName: String) -> Int? {
        guard let client else { return nil }
        let selector = NSSelectorFromString(selectorName)
        guard client.responds(to: selector) else { return nil }
        let readInteger = unsafeBitCast(client.method(for: selector), to: ReadInteger.self)
        return readInteger(client, selector)
    }
}
