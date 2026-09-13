import Foundation
import PowerTelemetrySupport

/// Shared storage for the panel's three-state power policy. The value is the
/// user's standing preference and survives restarts.
enum PowerFlowPolicyStore {
    static let defaultsKey = "powerFlowPolicy.v2"

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
    /// Maps the selected policy plus live battery numbers onto the single
    /// system lever. When the Mac cannot read an external battery the
    /// balanced policy simply keeps the healthy 80% hold.
    func chargingLimitDecision(
        macBatteryPercent: Int?,
        externalBatteryPercent: Int?
    ) -> ChargingLimitDecision {
        switch self {
        case .charging:
            return .allowFullCharge
        case .discharging:
            return .hold(percent: ChargingLimitConstants.minimumHoldPercent)
        case .balanced:
            if let macBatteryPercent, macBatteryPercent < 20 {
                return .allowFullCharge
            }
            return .hold(percent: ChargingLimitConstants.minimumHoldPercent)
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
        let target = decision.limitPercent
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
