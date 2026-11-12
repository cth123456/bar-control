import XCTest
@testable import CodexTouchBarNative

final class MenuSummaryTextTests: XCTestCase {
    func testSummaryUsesShortSupplierNameInsteadOfAccountEmail() {
        XCTAssertEqual(MenuSummaryText.suppliers(accounts: [
            account("Codex · test@example.invalid", percent: 40, provider: "plus")
        ]), "Codex Plus 余 40%")
    }

    func testSupplierBalancesKeepCurrencyAndDoNotCountWalletTwice() {
        let usd = account("供应商 A", balance: 12.34, unit: "USD")
        let cny = account("供应商 B", balance: -0.5, unit: "CNY")
        XCTAssertEqual(MenuSummaryText.suppliers(accounts: [usd, usd, cny]),
                       "供应商 A $12.34\n供应商 B -¥0.50")
    }

    func testMissingBalancesDoNotUseSpendingAsBalance() {
        XCTAssertEqual(MenuSummaryText.suppliers(accounts: [account("供应商 A")]),
                       "供应商 A 余额未读取")
        XCTAssertEqual(MenuSummaryText.suppliers(accounts: [account("订阅", percent: 68)]),
                       "订阅 余 68%")
    }

    func testSidecarUsesLiveConnectionInsteadOfOldOperationResult() {
        XCTAssertEqual(MenuSummaryText.sidecar(state: "idle", message: "", connectedDevices: ["CTHPAD"]),
                       "已连接 · CTHPAD")
        XCTAssertEqual(MenuSummaryText.sidecar(state: "failure", message: "上次连接失败", connectedDevices: ["CTHPAD"]),
                       "已连接 · CTHPAD")
        XCTAssertEqual(MenuSummaryText.sidecar(state: "success", message: "随航连接成功", connectedDevices: []),
                       "随航未连接")
        XCTAssertEqual(MenuSummaryText.sidecar(state: "connecting", message: "", connectedDevices: []),
                       "随航连接中…")
        XCTAssertEqual(MenuSummaryText.sidecar(state: "idle", message: "", connectedDevices: nil),
                       "正在读取随航状态…")
    }

    private func account(_ name: String, balance: Double? = nil, unit: String? = nil,
                         percent: Double? = nil, provider: String = "API") -> UsageAccount {
        UsageAccount(key: name, clientID: "codex", clientLabel: "Codex",
                     accountLabel: name, providerLabel: provider, isCurrent: true,
                     showByDefault: nil, iconID: nil, isOfficial: false, metricKind: "balance",
                     remainingBalance: balance, balanceUnit: unit, remainingPercent: percent,
                     secondaryRemainingPercent: nil, todayCost: 99, monthCost: 100,
                     todayRequests: 1, todayTokens: 1, cacheHitPercent: nil, successPercent: nil,
                     modelLabel: "", metricsScope: "", chartTitle: "", chartUnit: "",
                     latestAt: 0, history: [])
    }
}
