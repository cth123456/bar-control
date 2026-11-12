import XCTest
@testable import CodexTouchBarNative

final class TouchBarYieldPolicyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: TouchBarYieldPolicy.extraIDsKey)
        UserDefaults.standard.removeObject(forKey: TouchBarYieldPolicy.disabledIDsKey)
        UserDefaults.standard.removeObject(forKey: TouchBarYieldPolicy.learnedIDsKey)
        UserDefaults.standard.removeObject(forKey: TouchBarYieldPolicy.autoLearnKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TouchBarYieldPolicy.extraIDsKey)
        UserDefaults.standard.removeObject(forKey: TouchBarYieldPolicy.disabledIDsKey)
        UserDefaults.standard.removeObject(forKey: TouchBarYieldPolicy.learnedIDsKey)
        UserDefaults.standard.removeObject(forKey: TouchBarYieldPolicy.autoLearnKey)
        super.tearDown()
    }

    func testKnownTouchBarAppsYieldByDefault() {
        XCTAssertTrue(TouchBarYieldPolicy.shouldYield(bundleID: "com.apple.Safari"))
        XCTAssertTrue(TouchBarYieldPolicy.shouldYield(bundleID: "com.apple.dt.Xcode"))
        XCTAssertFalse(TouchBarYieldPolicy.shouldYield(bundleID: "local.codex.CodexTouchBarNative"))
        XCTAssertFalse(TouchBarYieldPolicy.shouldYield(bundleID: nil))
        XCTAssertFalse(TouchBarYieldPolicy.shouldYield(bundleID: ""))
    }

    func testFinderIsNotADefaultYieldApp() {
        XCTAssertFalse(TouchBarYieldPolicy.isDefault("com.apple.finder"))
        XCTAssertFalse(TouchBarYieldPolicy.shouldYield(bundleID: "com.apple.finder"))
    }

    func testDefaultAppCanBeDisabledAndReEnabled() {
        TouchBarYieldPolicy.setEnabled(false, for: "com.apple.Safari")
        XCTAssertFalse(TouchBarYieldPolicy.shouldYield(bundleID: "com.apple.Safari"))
        TouchBarYieldPolicy.setEnabled(true, for: "com.apple.Safari")
        XCTAssertTrue(TouchBarYieldPolicy.shouldYield(bundleID: "com.apple.Safari"))
    }

    func testUnknownAppCanBeAddedAndRemoved() {
        let bundleID = "com.example.UnknownEditor"
        XCTAssertFalse(TouchBarYieldPolicy.shouldYield(bundleID: bundleID))
        TouchBarYieldPolicy.setEnabled(true, for: bundleID)
        XCTAssertTrue(TouchBarYieldPolicy.shouldYield(bundleID: bundleID))
        XCTAssertTrue(TouchBarYieldPolicy.extraIDs().contains(bundleID))
        TouchBarYieldPolicy.setEnabled(false, for: bundleID)
        XCTAssertFalse(TouchBarYieldPolicy.shouldYield(bundleID: bundleID))
        XCTAssertFalse(TouchBarYieldPolicy.extraIDs().contains(bundleID))
    }

    func testTextFocusOnlyYieldsWhileTyping() {
        XCTAssertTrue(TouchBarYieldPolicy.shouldYieldForTextFocus(isEditing: true, isTyping: true))
        XCTAssertFalse(TouchBarYieldPolicy.shouldYieldForTextFocus(isEditing: true, isTyping: false))
        XCTAssertFalse(TouchBarYieldPolicy.shouldYieldForTextFocus(isEditing: false, isTyping: true))
        XCTAssertFalse(TouchBarYieldPolicy.shouldYieldForTextFocus(isEditing: false, isTyping: false))
        XCTAssertGreaterThan(TouchBarYieldPolicy.typingWindow, 0)
    }

    func testDefaultListHasNoDuplicatesOrBlankEntries() {
        let ids = TouchBarYieldPolicy.defaultBundleIDs
        XCTAssertEqual(ids.count, Set(ids).count, "让位名单里存在重复的 bundle id")
        XCTAssertFalse(ids.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }))
        XCTAssertTrue(ids.allSatisfy { $0.contains(".") && !$0.contains("{{") })
    }

    /// 系统内置与第三方各留几条锚点，避免以后整理名单时被误删。
    func testDefaultListCoversSystemAndThirdPartyTouchBarApps() {
        let ids = Set(TouchBarYieldPolicy.defaultBundleIDs)
        let system = [
            "com.apple.Safari", "com.apple.Music", "com.apple.FaceTime",
            "com.apple.mobilephone", "com.apple.AddressBook", "com.apple.Terminal",
            "com.apple.reminders", "com.apple.calculator", "com.apple.dt.Xcode",
        ]
        let thirdParty = [
            "com.microsoft.Word", "com.adobe.Photoshop", "com.adobe.illustrator",
            "com.adobe.PremierePro", "com.adobe.AfterEffects", "com.bohemiancoding.sketch3",
            "com.googlecode.iterm2", "com.seriflabs.affinityphoto2",
            "com.blackmagic-design.DaVinciResolve", "uk.co.tla-systems.pcalc",
            "com.algoriddim.djay", "com.barebones.bbedit",
        ]
        for id in system + thirdParty {
            XCTAssertTrue(ids.contains(id), "缺少 \(id)")
        }
        XCTAssertTrue(ids.contains(where: { !$0.hasPrefix("com.apple.") }))
    }

    /// 自动识别：把“它自己占了触控栏”的应用记下来，下次直接让位。
    func testLearnedAppYieldsWithoutManualConfiguration() {
        let bundleID = "com.example.SomeTouchBarApp"
        XCTAssertFalse(TouchBarYieldPolicy.shouldYield(bundleID: bundleID))
        XCTAssertTrue(TouchBarYieldPolicy.learn(bundleID))
        XCTAssertTrue(TouchBarYieldPolicy.isLearned(bundleID))
        XCTAssertTrue(TouchBarYieldPolicy.shouldYield(bundleID: bundleID))
        // 重复学习不会重复写入
        XCTAssertFalse(TouchBarYieldPolicy.learn(bundleID))
        XCTAssertEqual(TouchBarYieldPolicy.learnedIDs().filter { $0 == bundleID }.count, 1)
    }

    func testLearnedAppCanStillBeTurnedOff() {
        let bundleID = "com.example.LearnedEditor"
        TouchBarYieldPolicy.learn(bundleID)
        XCTAssertTrue(TouchBarYieldPolicy.shouldYield(bundleID: bundleID))
        TouchBarYieldPolicy.setEnabled(false, for: bundleID)
        XCTAssertFalse(TouchBarYieldPolicy.shouldYield(bundleID: bundleID))
        TouchBarYieldPolicy.setEnabled(true, for: bundleID)
        XCTAssertTrue(TouchBarYieldPolicy.shouldYield(bundleID: bundleID))
    }

    func testBuiltInAppsAreNotDuplicatedAsLearned() {
        XCTAssertFalse(TouchBarYieldPolicy.learn("com.apple.Safari"))
        XCTAssertFalse(TouchBarYieldPolicy.learnedIDs().contains("com.apple.Safari"))
        TouchBarYieldPolicy.learn("com.example.RemoveMe")
        XCTAssertTrue(TouchBarYieldPolicy.isLearned("com.example.RemoveMe"))
        TouchBarYieldPolicy.forget("com.example.RemoveMe")
        XCTAssertFalse(TouchBarYieldPolicy.isLearned("com.example.RemoveMe"))
    }

    func testOwnHelpersNeverYieldEvenIfLearned() {
        TouchBarYieldPolicy.learn("local.codex.SidecarPilot")
        XCTAssertFalse(TouchBarYieldPolicy.shouldYield(bundleID: "local.codex.SidecarPilot"))
        TouchBarYieldPolicy.purgeOwnHelpers()
        XCTAssertFalse(TouchBarYieldPolicy.learnedIDs().contains("local.codex.SidecarPilot"))
    }

    func testAutoLearnDefaultsOn() {
        XCTAssertTrue(TouchBarYieldPolicy.autoLearnEnabled)
        TouchBarYieldPolicy.autoLearnEnabled = false
        XCTAssertFalse(TouchBarYieldPolicy.autoLearnEnabled)
    }
}
