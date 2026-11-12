import Foundation
import PowerTelemetrySupport

/// MobileDevice sessions are serialized and sampled at most once per 10 seconds.
/// A disconnected/replaced iPad immediately invalidates the cached percentage.
final class ExternalBatterySampler: @unchecked Sendable {
    static let shared = ExternalBatterySampler()
    private let lock = NSLock()
    private var serial: String?
    private var sampledAt = Date.distantPast
    private var percent: Int?

    func read(devices: [USBDeviceDescriptor]) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let candidates = devices.filter { $0.name.lowercased().contains("ipad") }
        // Multiple iPads have no single safe battery target for the automatic rule.
        guard candidates.count == 1, let target = candidates.first?.serial, !target.isEmpty else {
            serial = nil
            percent = nil
            return nil
        }
        if serial == target, Date().timeIntervalSince(sampledAt) < 10 { return percent }
        serial = target
        let raw = target.withCString { bcpt_read_external_battery($0) }
        percent = (0...100).contains(raw) ? Int(raw) : nil
        sampledAt = Date()
        return percent
    }
}
