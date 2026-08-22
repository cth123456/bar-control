import AppKit
import Darwin
import ObjectiveC.runtime

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

    @discardableResult
    static func present(_ touchBar: NSTouchBar, from identifier: NSTouchBarItem.Identifier) -> Bool {
        symbol("DFRSystemModalShowsCloseBoxWhenFrontMost", as: CloseBoxFunction.self)?(true)
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

    func maximizeIfVisible() -> Bool {
        guard readInteger(selectorName: "displayState") == 2 else { return false }
        guard currentDimmingStep() != 1 else { return true }
        guard let client else { return false }
        let selector = NSSelectorFromString("dimToStep:")
        guard client.responds(to: selector) else { return false }
        let dimToStep = unsafeBitCast(client.method(for: selector), to: DimToStep.self)
        return dimToStep(client, selector, 1)
    }

    private func readInteger(selectorName: String) -> Int? {
        guard let client else { return nil }
        let selector = NSSelectorFromString(selectorName)
        guard client.responds(to: selector) else { return nil }
        let readInteger = unsafeBitCast(client.method(for: selector), to: ReadInteger.self)
        return readInteger(client, selector)
    }
}
