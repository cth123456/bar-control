import XCTest
@testable import CodexTouchBarNative

final class PowerNotificationTests: XCTestCase {
    func testOnlyPolicyTransitionsNotify() {
        XCTAssertTrue(PowerNotification.shouldPost(previous: .balanced, next: .charging, priority: .bothLow))
        XCTAssertFalse(PowerNotification.shouldPost(previous: .charging, next: .charging, priority: .bothLow),
                       "电量继续下降但策略没变时不应再通知")
        XCTAssertFalse(PowerNotification.shouldPost(previous: .balanced, next: .charging, priority: .charging),
                       "仅本机低电量不弹窗")
        XCTAssertFalse(PowerNotification.shouldPost(previous: .charging, next: .balanced, priority: .keep),
                       "回到负载均衡不弹窗")
    }
}
