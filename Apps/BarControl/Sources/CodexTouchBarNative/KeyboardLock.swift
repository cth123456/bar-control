import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.ps

/// 锁定状态在 Touch Bar 胶囊里显示的文字、图标与配色。
struct KeyboardLockPresentation: Equatable {
    let title: String
    let symbol: String
    let locked: Bool
    let permissionMissing: Bool
}

enum KeyboardLockPolicy {
    static let lockedDefaultsKey = "keyboardLocked.v1"
    static let autoUnlockDefaultsKey = "keyboardLock.autoUnlockOnPower.v1"

    static func presentation(locked: Bool, permissionGranted: Bool = true) -> KeyboardLockPresentation {
        guard permissionGranted else {
            return KeyboardLockPresentation(
                title: "键盘未授权",
                symbol: "lock.slash.fill",
                locked: false,
                permissionMissing: true
            )
        }
        return locked
            ? KeyboardLockPresentation(title: "键盘已锁定", symbol: "lock.fill",
                                       locked: true, permissionMissing: false)
            : KeyboardLockPresentation(title: "键盘可输入", symbol: "lock.open.fill",
                                       locked: false, permissionMissing: false)
    }

    /// 只在「电池 → 外接电源」这一瞬间自动解锁；一直插着电不重复触发。
    static func shouldAutoUnlock(
        wasOnExternalPower: Bool,
        isOnExternalPower: Bool,
        locked: Bool,
        automationEnabled: Bool
    ) -> Bool {
        automationEnabled && locked && !wasOnExternalPower && isOnExternalPower
    }
}

/// 事件回调运行在主运行循环上；用锁保护共享状态，避免数据竞争。
final class KeyboardLockSuppressor: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var tap: CFMachPort?

    var isSuppressing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return locked
    }

    func attach(tap: CFMachPort?) {
        lock.lock()
        self.tap = tap
        lock.unlock()
    }

    func setLocked(_ value: Bool) {
        lock.lock()
        locked = value
        lock.unlock()
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            lock.lock()
            let current = tap
            lock.unlock()
            if let current { CGEvent.tapEnable(tap: current, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .flagsChanged:
            return isSuppressing ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// 键盘锁：只吞掉硬件键盘事件，鼠标、触控板与 Touch Bar 输入保持可用，
/// 因此触控栏胶囊本身就是解锁入口。接上电源时按策略自动解锁。
@MainActor
final class KeyboardLockController {
    static let shared = KeyboardLockController()
    static let powerSourceDidChange = Notification.Name("BarControlPowerSourceDidChange")

    private let suppressor = KeyboardLockSuppressor()
    private var runLoopSource: CFRunLoopSource?
    private var powerRunLoopSource: CFRunLoopSource?
    private var powerObserver: NSObjectProtocol?
    private var lastExternalPower = false

    private(set) var isLocked = false
    private(set) var permissionGranted = AXIsProcessTrusted()
    var onChange: (() -> Void)?

    var autoUnlockOnPower: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: KeyboardLockPolicy.autoUnlockDefaultsKey) == nil { return true }
        return defaults.bool(forKey: KeyboardLockPolicy.autoUnlockDefaultsKey)
    }

    var presentation: KeyboardLockPresentation {
        KeyboardLockPolicy.presentation(locked: isLocked, permissionGranted: permissionGranted)
    }

    private init() {}

    func start() {
        permissionGranted = AXIsProcessTrusted()
        lastExternalPower = Self.isOnExternalPower()
        installPowerSourceObserver()
        powerObserver = NotificationCenter.default.addObserver(
            forName: Self.powerSourceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.powerSourceChanged() }
        }
        let persisted = UserDefaults.standard.bool(forKey: KeyboardLockPolicy.lockedDefaultsKey)
        if persisted {
            // 无法恢复（权限被撤销/事件监听不可用）时必须保持解锁，避免把键盘锁死。
            if !setLocked(true, reason: "restore") {
                UserDefaults.standard.set(false, forKey: KeyboardLockPolicy.lockedDefaultsKey)
            }
        }
        AppLog.write(
            "keyboard lock start persisted=\(persisted) locked=\(isLocked) "
            + "trusted=\(permissionGranted) externalPower=\(lastExternalPower)"
        )
    }

    @discardableResult
    func setLocked(_ value: Bool, reason: String) -> Bool {
        if value {
            permissionGranted = AXIsProcessTrusted()
            guard permissionGranted else {
                AppLog.write("keyboard lock blocked: accessibility permission missing")
                onChange?()
                return false
            }
            guard installTap() else {
                permissionGranted = false
                AppLog.write("keyboard lock blocked: event tap creation failed")
                onChange?()
                return false
            }
            suppressor.setLocked(true)
            isLocked = true
        } else {
            suppressor.setLocked(false)
            isLocked = false
            removeTap()
        }
        UserDefaults.standard.set(isLocked, forKey: KeyboardLockPolicy.lockedDefaultsKey)
        AppLog.write("keyboard lock \(isLocked ? "on" : "off") reason=\(reason)")
        onChange?()
        return true
    }

    func toggle(reason: String) -> Bool {
        setLocked(!isLocked, reason: reason)
    }

    func setAutoUnlockOnPower(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: KeyboardLockPolicy.autoUnlockDefaultsKey)
        AppLog.write("keyboard lock auto-unlock-on-power=\(enabled)")
        onChange?()
    }

    func requestPermission() {
        // 全局常量 kAXTrustedCheckOptionPrompt 在 Swift 6 下被判为非并发安全，
        // 直接用它文档化的字符串值。
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        permissionGranted = AXIsProcessTrusted()
        onChange?()
    }

    func refreshPermission() {
        let previous = permissionGranted
        permissionGranted = AXIsProcessTrusted()
        if previous != permissionGranted { onChange?() }
    }

    // MARK: - Event tap

    private func installTap() -> Bool {
        if runLoopSource != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: keyboardLockEventCallback,
            userInfo: Unmanaged.passUnretained(suppressor).toOpaque()
        ) else { return false }
        suppressor.attach(tap: tap)
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSource = source
        return true
    }

    private func removeTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        suppressor.attach(tap: nil)
    }

    // MARK: - Power source

    private func installPowerSourceObserver() {
        guard powerRunLoopSource == nil,
              let source = IOPSNotificationCreateRunLoopSource({ _ in
                  NotificationCenter.default.post(name: KeyboardLockController.powerSourceDidChange, object: nil)
              }, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerRunLoopSource = source
    }

    private func powerSourceChanged() {
        let now = Self.isOnExternalPower()
        let was = lastExternalPower
        lastExternalPower = now
        guard now != was else { return }
        AppLog.write("keyboard lock power external=\(now)")
        if KeyboardLockPolicy.shouldAutoUnlock(
            wasOnExternalPower: was,
            isOnExternalPower: now,
            locked: isLocked,
            automationEnabled: autoUnlockOnPower
        ) {
            setLocked(false, reason: "power-connected")
        }
    }

    static func isOnExternalPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue {
                return true
            }
        }
        return false
    }
}

private func keyboardLockEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let suppressor = Unmanaged<KeyboardLockSuppressor>.fromOpaque(userInfo).takeUnretainedValue()
    return suppressor.handle(type: type, event: event)
}

// MARK: - 诊断探针（--keyboard-lock-probe）

/// 自检：同一个进程里先量“合成按键能进事件链”，再量“装上拦截后进不来”。
/// 两次用的发送方式、权限完全相同，因此可以排除“没权限所以没事件”的假阳性。
/// 只发 F13（不产生文字），不影响前台 App。
final class ProbeEventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private func probeVerifierCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<ProbeEventCounter>.fromOpaque(userInfo).takeUnretainedValue().increment()
    }
    return Unmanaged.passUnretained(event)
}

enum KeyboardLockProbe {
    static func run() -> Int32 {
        let counter = ProbeEventCounter()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let verifier = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: probeVerifierCallback,
            userInfo: Unmanaged.passUnretained(counter).toOpaque()
        ), let verifierSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, verifier, 0) else {
            print("probe: verifier tap unavailable (accessibility=\(AXIsProcessTrusted()))")
            return 2
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), verifierSource, .commonModes)
        CGEvent.tapEnable(tap: verifier, enable: true)

        func postF13() {
            let source = CGEventSource(stateID: .hidSystemState)
            CGEvent(keyboardEventSource: source, virtualKey: 0x69, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 0x69, keyDown: false)?.post(tap: .cghidEventTap)
            CFRunLoopRunInMode(.defaultMode, 0.25, false)
        }

        let baseline = counter.value
        postF13()
        let delivered = counter.value - baseline

        // 拦截 tap 晚于验证 tap 创建 → 排在链头，先于验证 tap 执行。
        let suppressor = KeyboardLockSuppressor()
        suppressor.setLocked(true)
        guard let blocking = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardLockEventCallback,
            userInfo: Unmanaged.passUnretained(suppressor).toOpaque()
        ), let blockingSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, blocking, 0) else {
            print("probe: blocking tap unavailable (accessibility=\(AXIsProcessTrusted()))")
            return 3
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), blockingSource, .commonModes)
        CGEvent.tapEnable(tap: blocking, enable: true)
        suppressor.attach(tap: blocking)

        let beforeBlocked = counter.value
        postF13()
        let leaked = counter.value - beforeBlocked

        CFRunLoopRemoveSource(CFRunLoopGetMain(), blockingSource, .commonModes)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), verifierSource, .commonModes)

        let trusted = AXIsProcessTrusted()
        let verdict: String
        if delivered < 1 {
            verdict = "inconclusive(合成事件未送达，无法判定)"
        } else if leaked == 0 {
            verdict = "pass(拦截生效)"
        } else {
            verdict = "fail(按键仍能穿过)"
        }
        let summary = "keyboard lock probe delivered=\(delivered) leaked=\(leaked) "
            + "trusted=\(trusted) verdict=\(verdict)"
        AppLog.write(summary)
        print(summary)
        return verdict.hasPrefix("pass") ? 0 : 1
    }
}
