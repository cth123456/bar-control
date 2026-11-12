import Foundation
import PowerTelemetrySupport

/// Shared storage for the panel's three-state power policy. The value is the
/// user's standing preference and survives restarts.
enum PowerFlowPolicyStore {
    static let maximumChargeKey = "maximumChargePercent.v1"
    static var maximumChargePercent: Int {
        get {
            guard UserDefaults.standard.object(forKey: maximumChargeKey) != nil else { return 100 }
            return min(100, max(80, UserDefaults.standard.integer(forKey: maximumChargeKey)))
        }
        set { UserDefaults.standard.set(min(100, max(80, newValue)), forKey: maximumChargeKey) }
    }
    static let defaultsKey = "powerFlowPolicy.v2"
    static let balancedLowerKey = "balancedChargeLower.v1"
    static let balancedUpperKey = "balancedChargeUpper.v1"
    static let balancedPercentRange = 80...90
    static let autoReturnThresholdKey = "deviceAutoReturnPercent.v1"
    static let macLowPercentKey = "lowBatteryMacPercent.v1"
    static let deviceLowPercentKey = "lowBatteryDevicePercent.v1"
    static let autoReturnEnabledKey = "deviceAutoReturnEnabled.v1"

    /// 优先充电 / 优先放电时，接入设备充到该百分比后自动回到负载均衡。
    /// 低电量阈值：本机与有线设备各自默认 30%。
    static var macLowPercent: Int {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: macLowPercentKey) != nil else { return 30 }
            return min(60, max(10, defaults.integer(forKey: macLowPercentKey)))
        }
        set { UserDefaults.standard.set(min(60, max(10, newValue)), forKey: macLowPercentKey) }
    }

    static var deviceLowPercent: Int {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: deviceLowPercentKey) != nil else { return 30 }
            return min(60, max(10, defaults.integer(forKey: deviceLowPercentKey)))
        }
        set { UserDefaults.standard.set(min(60, max(10, newValue)), forKey: deviceLowPercentKey) }
    }

    static var autoReturnThreshold: Int {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: autoReturnThresholdKey) != nil else { return 80 }
            return min(100, max(50, defaults.integer(forKey: autoReturnThresholdKey)))
        }
        set { UserDefaults.standard.set(min(100, max(50, newValue)), forKey: autoReturnThresholdKey) }
    }

    static var autoReturnEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: autoReturnEnabledKey) != nil else { return true }
            return defaults.bool(forKey: autoReturnEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoReturnEnabledKey) }
    }

    /// 读取某个区间端点；未设置或越界时退回默认值。
    private static func storedPercent(_ key: String, fallback: Int) -> Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return fallback }
        let stored = defaults.integer(forKey: key)
        return balancedPercentRange.contains(stored) ? stored : fallback
    }

    /// 负载均衡（航海模式）区间下限：降到这一档才重新充电。
    static var balancedLowerPercent: Int {
        get {
            let lower = storedPercent(balancedLowerKey, fallback: 80)
            let upper = storedPercent(balancedUpperKey, fallback: 90)
            return min(lower, upper - 1)
        }
        set {
            let clamped = min(balancedPercentRange.upperBound - 1,
                              max(balancedPercentRange.lowerBound, newValue))
            UserDefaults.standard.set(clamped, forKey: balancedLowerKey)
        }
    }

    /// 负载均衡（航海模式）区间上限：充到这一档就停止充电。
    static var balancedUpperPercent: Int {
        get {
            let lower = storedPercent(balancedLowerKey, fallback: 80)
            let upper = storedPercent(balancedUpperKey, fallback: 90)
            return max(upper, lower + 1)
        }
        set {
            let clamped = min(balancedPercentRange.upperBound,
                              max(balancedPercentRange.lowerBound + 1, newValue))
            UserDefaults.standard.set(clamped, forKey: balancedUpperKey)
        }
    }

    static var current: PowerFlowPolicy {
        get {
            guard UserDefaults.standard.object(forKey: defaultsKey) != nil else {
                return .balanced
            }
            return PowerFlowPolicy(
                rawValue: UserDefaults.standard.integer(forKey: defaultsKey)
            ) ?? .balanced
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}

enum ChargingLimitConstants {
    /// Lowest limit the system accepts. Below 80% the firmware keeps
    /// charging regardless of any app request.
    static let minimumHoldPercent = 80
    static let fullChargePercent = 100

    static func effectiveLimit(policyLimit: Int, maximum: Int) -> Int {
        min(policyLimit, min(100, max(80, maximum)))
    }
}

/// The concrete charge-control action taken on the Mac.
///
/// macOS 27 firmware removed the writable "suspend charging" SMC keys on
/// Apple Silicon, so the only remaining lever is the system Manual Charge
/// Limit whose lowest accepted value is 80%. "Stop charging" therefore means
/// "hold at 80%"; below 80% the system keeps charging no matter which app
/// asks it not to.
enum ChargingLimitDecision: Equatable, Sendable {
    case allowFullCharge
    case hold(percent: Int)

    var limitPercent: Int {
        switch self {
        case .allowFullCharge: ChargingLimitConstants.fullChargePercent
        case .hold(let percent): percent
        }
    }
}

extension PowerFlowPolicy {
    /// 优先充电 / 优先放电时，有线设备（iPad 等）充到阈值后回到负载均衡。
    /// 阈值和开关都可在菜单里调整；未知电量不触发。
    enum LowBatteryPriority: Equatable {
        case keep
        case charging
        case discharging
        case bothLow
    }

    /// 谁的电量最低就优先保谁：本机低 → 优先充电；
    /// 只有外接设备低 → 优先放电；都低 → 优先保本机并提示；
    /// 都回到阈值以上 → 回负载均衡。
    static func lowBatteryPriority(
        macBattery: Int?,
        deviceBattery: Int?,
        macLow: Int = PowerFlowPolicyStore.macLowPercent,
        deviceLow: Int = PowerFlowPolicyStore.deviceLowPercent
    ) -> LowBatteryPriority {
        let macLowNow = macBattery.map { $0 < macLow } ?? false
        let deviceLowNow = deviceBattery.map { $0 < deviceLow } ?? false
        switch (macLowNow, deviceLowNow) {
        case (true, true): return .bothLow
        case (true, false): return .charging
        case (false, true): return .discharging
        case (false, false): return .keep
        }
    }

    /// Maps the selected policy plus live battery numbers onto the single
    /// system lever. When the Mac cannot read an external battery the
    /// balanced policy simply keeps the healthy 80% hold.
    /// 三种模式共用系统 Manual Charge Limit：
    /// - 优先充电：放开上限，正常充满；
    /// - 负载均衡（航海模式）：把电量维持在 80–90%（可配置）；
    /// - 优先放电：保持适配器供电，把上限压到当前电量，停止给电池充电。
    func chargingLimitDecision(
        macBatteryPercent: Int?,
        externalBatteryPercent: Int?,
        balancedLower: Int = PowerFlowPolicyStore.balancedLowerPercent,
        balancedUpper: Int = PowerFlowPolicyStore.balancedUpperPercent
    ) -> ChargingLimitDecision {
        let lower = min(ChargingLimitConstants.fullChargePercent,
                        max(ChargingLimitConstants.minimumHoldPercent, balancedLower))
        let upper = min(ChargingLimitConstants.fullChargePercent,
                        max(lower + 1, balancedUpper))
        switch self {
        case .charging:
            return .allowFullCharge
        case .balanced:
            // 航海模式：区间内来回循环，而不是钉死在某个数值。
            // 低于下限 → 放开到上限把电充回去；到达/高于上限 → 停在上限不再充；
            // 区间中间 → 保持下限，等自然掉到下限以下再补。
            guard let percent = macBatteryPercent else { return .hold(percent: upper) }
            if percent < 20 { return .allowFullCharge }
            if percent >= upper { return .hold(percent: upper) }
            if percent <= lower { return .hold(percent: upper) }
            return .hold(percent: lower)
        case .discharging:
            // 停止充电但保持适配器连接：上限压到当前电量；低于固件下限时保持 80%。
            let current = macBatteryPercent ?? ChargingLimitConstants.minimumHoldPercent
            return .hold(percent: max(ChargingLimitConstants.minimumHoldPercent,
                                      min(ChargingLimitConstants.fullChargePercent, current)))
        }
    }
}

/// Applies the panel policy to the system Manual Charge Limit through the
/// private PowerUI framework. Reads are safe anywhere; writes only happen
/// when the computed target actually changes, so the app does not fight a
/// limit configured outside the panel.
@MainActor
final class ChargingLimitController {
    static let shared = ChargingLimitController()
    static let minimumHoldPercent = ChargingLimitConstants.minimumHoldPercent
    static let fullChargePercent = ChargingLimitConstants.fullChargePercent

    struct Snapshot: Equatable {
        var isSupported = false
        var isEnabled = false
        var limitPercent: Int?
    }

    private(set) var snapshot = Snapshot()
    private(set) var lastAppliedLimit: Int?
    /// True once the panel (or an already-present system limit of our
    /// target value) owns the limit, so auto rules may change it.
    private(set) var isActive = false
    private(set) var lastError: String?

    private init() {
        refreshSnapshot()
        if snapshot.isEnabled, snapshot.limitPercent == Self.minimumHoldPercent {
            // The system already holds the balanced target; adopt it without
            // writing anything so the panel can show "已接入" immediately.
            lastAppliedLimit = Self.minimumHoldPercent
            isActive = true
        }
    }

    func refreshSnapshot() {
        let supported = bcpt_charge_limit_supported() == 1
        var limit: Int32 = 0
        let readState = bcpt_charge_limit_read(&limit)
        snapshot = Snapshot(
            isSupported: supported,
            isEnabled: readState == 1,
            limitPercent: readState == 1 ? Int(limit) : nil
        )
    }

    /// Computes and applies the needed change. Pass `userInitiated: true`
    /// when the user just picked a policy segment in the panel; auto rules
    /// (20% thresholds) run with `false`.
    func update(
        policy: PowerFlowPolicy,
        metrics: SystemMetrics,
        userInitiated: Bool
    ) {
        if userInitiated {
            isActive = true
        }
        guard isActive else { return }
        let decision = policy.chargingLimitDecision(
            macBatteryPercent: metrics.batteryPercent,
            externalBatteryPercent: metrics.externalBatteryPercent
        )
        apply(decision, reason: userInitiated ? "policy" : "auto")
    }

    @discardableResult
    private func apply(_ decision: ChargingLimitDecision, reason: String) -> Bool {
        guard snapshot.isSupported else {
            lastError = "本机不支持系统充电控制"
            return false
        }
        let target = ChargingLimitConstants.effectiveLimit(
            policyLimit: decision.limitPercent, maximum: PowerFlowPolicyStore.maximumChargePercent
        )
        guard target != lastAppliedLimit else { return true }
        let success = bcpt_charge_limit_set(Int32(target)) == 1
        if success {
            lastAppliedLimit = target
            lastError = nil
            refreshSnapshot()
        } else {
            lastError = "设置充电上限 \(target)% 失败"
        }
        AppLog.write(
            "charging-limit apply target=\(target) reason=\(reason) success=\(success)"
        )
        return success
    }

    /// Short suffix for the "Mac 供电" label.
    var summaryText: String {
        guard snapshot.isSupported else { return "不支持控制" }
        if isActive, let applied = lastAppliedLimit {
            return "上限\(applied)%"
        }
        if let limit = snapshot.limitPercent {
            return "系统上限\(limit)%"
        }
        return "点选接入"
    }

    /// One-line detail for the accessibility value.
    var accessibilityText: String {
        guard snapshot.isSupported else {
            return "本机系统不支持充电上限控制"
        }
        if isActive, let applied = lastAppliedLimit {
            return "已接入系统充电上限 \(applied)%"
        }
        if let limit = snapshot.limitPercent {
            return "系统已有充电上限 \(limit)%，选择策略后由本应用接管"
        }
        return "点选策略即可接入系统充电上限控制"
    }
}
