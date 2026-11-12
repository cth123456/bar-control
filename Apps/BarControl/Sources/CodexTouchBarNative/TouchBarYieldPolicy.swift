import AppKit
import ApplicationServices

/// 决定模块栏何时给前台应用让出 Touch Bar 中间区域。
///
/// Touch Bar 没有跨应用的后备层，也没有“中间是否被占用”的公开查询接口，
/// 所以这里用两条可解释的规则：
/// 1. 前台应用在让位名单里（它会往中间放自己的控件）；
/// 2. 前台应用的焦点在文本输入框里（系统输入建议会占据中间）。
enum TouchBarYieldPolicy {
    static let textFocusKey = "touchBarTextFocusYield.v1"
    static let extraIDsKey = "touchBarYieldExtraBundleIDs.v1"
    static let disabledIDsKey = "touchBarYieldDisabledBundleIDs.v1"
    static let learnedIDsKey = "touchBarYieldLearnedBundleIDs.v1"
    static let autoLearnKey = "touchBarAutoLearn.v1"

    /// 会往 Touch Bar 中间放自己控件的应用。
    ///
    /// 收录标准：应用确实创建了 NSTouchBar（带 App Controls），而不是只在
    /// 菜单里提到 Touch Bar。来源：本机二进制扫描（NSTouchBar / DFRFoundation /
    /// makeTouchBar / NSTouchBarDelegate 符号）、Apple 支持文档，以及
    /// iMore「Best Touch Bar apps」、Affinity/iTerm2/DaVinci 官方说明。
    /// Finder 这类只在选中文件时出现少量控件的应用不默认让位；
    /// 名单外的应用可在「让位应用」窗口里手动添加。
    static let defaultBundleIDs: [String] = [
        // ── 系统内置 ──
        "com.apple.Safari",
        "com.apple.mail",
        "com.apple.MobileSMS",
        "com.apple.Notes",
        "com.apple.Photos",
        "com.apple.Preview",
        "com.apple.QuickTimePlayerX",
        "com.apple.iCal",
        "com.apple.Maps",
        "com.apple.reminders",
        "com.apple.Terminal",
        "com.apple.calculator",
        "com.apple.iBooksX",
        "com.apple.TV",
        "com.apple.AppStore",
        "com.apple.VoiceMemos",
        "com.apple.Music",
        "com.apple.FaceTime",
        "com.apple.mobilephone",
        "com.apple.AddressBook",
        "com.apple.findmy",
        "com.apple.ActivityMonitor",
        "com.apple.Automator",
        "com.apple.Console",
        "com.apple.audio.AudioMIDISetup",
        "com.apple.ScreenSharing",
        "com.apple.iWork.Pages",
        "com.apple.iWork.Numbers",
        "com.apple.iWork.Keynote",
        "com.apple.dt.Xcode",
        "com.apple.FinalCut",
        "com.apple.logic10",
        "com.apple.garageband10",
        "com.apple.iMovieApp",
        // ── 第三方 ──
        "com.microsoft.Word",
        "com.microsoft.Excel",
        "com.microsoft.Powerpoint",
        "com.adobe.Photoshop",
        "com.adobe.illustrator",
        "com.adobe.PremierePro",
        "com.adobe.AfterEffects",
        "com.bohemiancoding.sketch3",
        "com.bohemiancoding.sketch3.appstore",
        "com.barebones.bbedit",
        "com.googlecode.iterm2",
        "com.pixelmatorteam.pixelmator.x",
        "com.seriflabs.affinitydesigner2",
        "com.seriflabs.affinityphoto2",
        "com.seriflabs.affinitypublisher2",
        "com.blackmagic-design.DaVinciResolve",
        "com.blackmagic-design.DaVinciResolveLite",
        "com.blackmagic-design.DaVinciResolveAppStore",
        "uk.co.tla-systems.pcalc",
        "com.algoriddim.djay",
        "com.algoriddim.djay-iphone-free",
    ]

    static var textFocusYieldEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: textFocusKey) != nil else { return true }
            return defaults.bool(forKey: textFocusKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: textFocusKey) }
    }

    /// 自动识别：当我们以系统模态呈现的模块栏被前台应用挤掉（DFR 把窗口压成 0 宽），
    /// 说明这个应用自己往 Touch Bar 放了内容。记下来，下次它到前台就直接让位，
    /// 不必再人工查它支不支持 Touch Bar。
    static var autoLearnEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: autoLearnKey) != nil else { return true }
            return defaults.bool(forKey: autoLearnKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoLearnKey) }
    }

    static var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 停止输入后多久把模块栏还回来。输入建议只在打字时最有用，
    /// 一直让位会让模块栏在编辑器里永远看不见。
    static let typingWindow: TimeInterval = 3

    static func shouldYieldForTextFocus(isEditing: Bool, isTyping: Bool) -> Bool {
        isEditing && isTyping
    }

    /// 最近 3 秒内是否有按键（系统级空闲时间，不需要额外权限）。
    static func isActivelyTyping() -> Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < typingWindow
    }

    static func isDefault(_ bundleID: String) -> Bool {
        defaultBundleIDs.contains(bundleID)
    }

    /// 我们自己的辅助进程（随航管家等）永远不让位：
    /// 它们在无头/iPad 主屏布局下不会创建自己的 Touch Bar，
    /// 让位只会让整条触控栏空白。
    static func isOwnHelper(_ bundleID: String) -> Bool {
        bundleID.hasPrefix("local.codex.")
    }

    static func isEnabled(_ bundleID: String) -> Bool {
        if isOwnHelper(bundleID) { return false }
        if disabledIDs().contains(bundleID) { return false }
        if extraIDs().contains(bundleID) { return true }
        return isDefault(bundleID) || isLearned(bundleID)
    }

    static func setEnabled(_ enabled: Bool, for bundleID: String) {
        var extra = extraIDs()
        var disabled = disabledIDs()
        if enabled {
            disabled.remove(bundleID)
            if !isDefault(bundleID) { extra.insert(bundleID) }
        } else {
            extra.remove(bundleID)
            if isDefault(bundleID) || isLearned(bundleID) { disabled.insert(bundleID) }
        }
        UserDefaults.standard.set(Array(extra), forKey: extraIDsKey)
        UserDefaults.standard.set(Array(disabled), forKey: disabledIDsKey)
    }

    static func isLearned(_ bundleID: String) -> Bool {
        learnedIDs().contains(bundleID)
    }

    static func learnedIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: learnedIDsKey) ?? [])
    }

    static func installedLearnedIDs() -> [String] {
        learnedIDs().filter { applicationURL(for: $0) != nil }.sorted()
    }

    /// 记下“它自己会占 Touch Bar”这件事。已经在内置/手动名单里的不重复记。
    @discardableResult
    static func learn(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty, !isDefault(bundleID), !extraIDs().contains(bundleID) else {
            return false
        }
        var learned = learnedIDs()
        guard learned.insert(bundleID).inserted else { return false }
        UserDefaults.standard.set(Array(learned), forKey: learnedIDsKey)
        return true
    }

    static func forget(_ bundleID: String) {
        var learned = learnedIDs()
        learned.remove(bundleID)
        UserDefaults.standard.set(Array(learned), forKey: learnedIDsKey)
    }

    static func shouldYield(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return isEnabled(bundleID)
    }

    /// 老版本可能把 SidecarPilot 自动学进让位名单，启动时清掉。
    static func purgeOwnHelpers() {
        let defaults = UserDefaults.standard
        for key in [extraIDsKey, disabledIDsKey, learnedIDsKey] {
            guard let list = defaults.stringArray(forKey: key) else { continue }
            let filtered = list.filter { !isOwnHelper($0) }
            if filtered.count != list.count {
                defaults.set(filtered, forKey: key)
            }
        }
    }

    static func extraIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: extraIDsKey) ?? [])
    }

    static func disabledIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: disabledIDsKey) ?? [])
    }

    static func installedDefaultIDs() -> [String] {
        defaultBundleIDs.filter { applicationURL(for: $0) != nil }
    }

    static func applicationURL(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func displayName(for bundleID: String) -> String {
        guard let url = applicationURL(for: bundleID) else {
            return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    /// 让位窗口里显示真实应用图标，比统一的方块更能一眼认出是哪个 App。
    static func icon(for bundleID: String) -> NSImage? {
        guard let url = applicationURL(for: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 20, height: 20)
        return icon
    }

    /// 前台应用的焦点是否在可编辑文本控件上。仅读取，不修改任何 App。
    static func focusedElementIsTextInput(pid: pid_t) -> Bool {
        guard accessibilityTrusted else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return false }
        let element = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard let role = stringAttribute(element, kAXRoleAttribute) else { return false }
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
            return true
        default:
            if let subrole = stringAttribute(element, kAXSubroleAttribute),
               subrole == "AXSecureTextField" {
                return true
            }
            return false
        }
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
