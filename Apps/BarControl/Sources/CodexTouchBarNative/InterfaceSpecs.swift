import Foundation
import IOKit

// MARK: - Models

/// One fixed supply (PDO) advertised by the charger.
struct PDOPowerOption: Equatable, Sendable {
    let volts: Double
    let amps: Double

    var watts: Double { volts * amps }

    var label: String {
        String(format: "%.0f V · %.2f A · %.1f W", volts, amps, watts)
    }
}

/// Charger details from AppleSmartBattery plus the winning USB-PD option.
struct ChargerSpecs: Equatable, Sendable {
    var name: String?
    var manufacturer: String?
    var model: String?
    var serial: String?
    var firmware: String?
    var hardware: String?
    var ratedWatts: Double?
    var options: [PDOPowerOption] = []
    var negotiated: PDOPowerOption?
    var liveVolts: Double?
    var liveAmps: Double?
    var liveWatts: Double?
    var portNumber: Int?

    var brandLabel: String? {
        guard let manufacturer else { return nil }
        return manufacturer
            .replacingOccurrences(of: " Inc.", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Compact "Apple 20W · 9V/2.22A" form for the panel row.
    var summary: String {
        var parts: [String] = []
        let brand = brandLabel
        let watts = ratedWatts.map { String(format: "%.0fW", $0) }
        let head = [brand, watts].compactMap { $0 }.joined(separator: " ")
        if !head.isEmpty { parts.append(head) }
        if let negotiated {
            parts.append(String(format: "%.0fV/%.2fA", negotiated.volts, negotiated.amps))
        }
        return parts.joined(separator: " · ")
    }
}

/// Decoded cable e-marker capabilities (USB-PD R3.2 Table 6.42).
///
/// The speed encoding is shown conservatively on purpose: values 3 and 4
/// differ between USB-PD 3.0 and 3.1, so the higher claim is never made
/// without also exposing the raw field in the detail view.
struct CableCapabilities: Equatable, Sendable {
    let speedRaw: Int
    let currentRaw: Int
    let maxVoltsRaw: Int
    let plugRaw: Int
    let eprCapable: Bool

    var maxAmps: Double {
        switch currentRaw {
        case 2: 5
        default: 3
        }
    }

    var maxVolts: Int { maxVoltsRaw == 3 ? 50 : 20 }

    /// Highest power USB-PD can actually deliver through this cable. Capped
    /// at the spec's 48 V EPR ceiling, so 50 V × 5 A reports 240 W rather
    /// than the insulation headroom value.
    var maxWatts: Int { Int(min(48.0, Double(maxVolts)) * maxAmps) }

    var speedLabel: String {
        switch speedRaw {
        case 0: "USB 2.0 (480 Mbps)"
        case 1: "USB 3.2 Gen 1 (5 Gbps)"
        case 2: "USB 3.2 Gen 2 (10 Gbps)"
        case 3: "USB4 级 · ≥20 Gbps"
        case 4: "USB4 级 · ≥40 Gbps"
        default: "保留编码 \(speedRaw)"
        }
    }

    var shortSpeedLabel: String {
        switch speedRaw {
        case 0: "USB2.0"
        case 1: "5Gbps"
        case 2: "10Gbps"
        case 3: "≥20Gbps"
        case 4: "≥40Gbps"
        default: "编码\(speedRaw)"
        }
    }

    /// Raw field note for the detail page, so the conservative wording is
    /// auditable against the actual e-marker bytes.
    var speedRawNote: String {
        switch speedRaw {
        case 0, 1, 2:
            "速率字段原始值 \(speedRaw)，USB-PD 3.0/3.1 定义一致"
        case 3:
            "速率字段原始值 3：USB-PD 3.0 为 20 Gbps，3.1 为 40 Gbps（编码歧义），此处按保守值显示"
        case 4:
            "速率字段原始值 4：USB-PD 3.1 为 80 Gbps，3.0 无此编码，此处按保守值显示"
        default:
            "速率字段为保留编码 \(speedRaw)"
        }
    }

    var currentLabel: String {
        switch currentRaw {
        case 0: "默认 (3 A)"
        case 1: "3 A"
        case 2: "5 A"
        default: "保留编码 \(currentRaw)"
        }
    }

    var powerLabel: String {
        "\(maxVolts) V / \(Int(maxAmps)) A · 最高 \(maxWatts) W"
    }

    var eprLabel: String { eprCapable ? "支持 EPR（48/50 V）" : "不支持 EPR" }

    var plugLabel: String {
        switch plugRaw {
        case 0: "Type-A（已废弃）"
        case 1: "Type-B（已废弃）"
        case 2: "Type-C"
        default: "固定线（设备自带）"
        }
    }
}

/// One USB-C port and whatever is attached on the other end.
struct PortSpecs: Equatable, Sendable {
    let portNumber: Int
    var isChargerPort = false
    var deviceName: String?
    var deviceVendorID: Int?
    var deviceProductID: Int?
    var cableProductType: String?
    var cableSpecRevision: Int?
    var cableVendorID: Int?
    var cableProductID: Int?
    var cableCertXID: UInt32?
    var cable: CableCapabilities?
    var notes: [String] = []

    var hasCable: Bool { cable != nil }

    /// Conservative one-line cable summary for the panel: "240W · ≥40Gbps".
    var cableSummary: String? {
        guard let cable else { return nil }
        return "\(cable.maxWatts)W · \(cable.shortSpeedLabel)"
    }
}

/// Everything the interface panel and detail page need, independent from
/// the live power snapshot.
struct InterfaceSpecs: Equatable, Sendable {
    var charger: ChargerSpecs?
    var ports: [PortSpecs] = []

    static let empty = InterfaceSpecs()

    /// Prefer the cable that can carry the most power when several are
    /// attached; the panel only has room for one summary.
    var primaryCablePort: PortSpecs? {
        ports.filter(\.hasCable).max { left, right in
            (left.cable?.maxWatts ?? 0) < (right.cable?.maxWatts ?? 0)
        }
    }

    var hasPanelContent: Bool {
        charger != nil || primaryCablePort != nil
    }
}

// MARK: - Diagnosis

/// Plain-language verdict for the detail page footer.
struct PowerVerdict: Equatable, Sendable {
    enum Severity: Equatable, Sendable {
        case ok
        case warning
        case info
    }

    let severity: Severity
    let title: String
    let detail: String
}

enum PowerDiagnosis {
    /// True when the adapter cannot cover the whole-machine load, so the
    /// battery has to make up the difference.
    static func isUnderpowered(_ metrics: SystemMetrics) -> Bool {
        guard metrics.externalPower,
              let input = metrics.inputWatts, input.isFinite,
              let load = metrics.systemWatts ?? metrics.sourceWatts, load.isFinite,
              let battery = metrics.batteryWatts, battery.isFinite else {
            return false
        }
        return battery < -0.5 && input + 0.5 < load
    }

    static func recommendedChargerWatts(forLoad load: Double) -> Int {
        max(45, Int((((load + 15) / 5).rounded(.up)) * 5))
    }

    static func verdict(specs: InterfaceSpecs, metrics: SystemMetrics) -> PowerVerdict {
        let load = metrics.systemWatts ?? metrics.sourceWatts
        let input = metrics.inputWatts
        let batterySupply = metrics.batterySupplyWatts

        guard metrics.externalPower else {
            return PowerVerdict(
                severity: .info,
                title: "未连接充电器",
                detail: "当前由电池供电，接入充电器后可查看充电器与线缆规格。"
            )
        }

        if isUnderpowered(metrics), let load, let input {
            if let cable = specs.primaryCablePort?.cable,
               cable.maxWatts + 1 < Int(load.rounded(.up)) {
                return PowerVerdict(
                    severity: .warning,
                    title: "瓶颈在线缆",
                    detail: String(
                        format: "线缆最高 %d W，低于整机 %.1f W 的负载；换一条 5 A 线缆并搭配足够功率的充电器。",
                        cable.maxWatts,
                        load
                    )
                )
            }
            let recommended = recommendedChargerWatts(forLoad: load)
            return PowerVerdict(
                severity: .warning,
                title: "瓶颈在充电器",
                detail: String(
                    format: "输入 %.1f W < 整机 %.1f W，电池正在放电释放 %.1f W。建议使用 ≥%d W 充电器。",
                    input,
                    load,
                    batterySupply,
                    recommended
                )
            )
        }

        // The charger is fine, but a slow cable still caps what the Mac can
        // draw even when the adapter advertises more.
        if let cable = specs.primaryCablePort?.cable {
            let chargerWatts = specs.charger?.negotiated?.watts
                ?? specs.charger?.ratedWatts
                ?? metrics.adapterLimitWatts
            if let chargerWatts,
               Double(cable.maxWatts) + 1 < chargerWatts {
                return PowerVerdict(
                    severity: .warning,
                    title: "线缆可能限制充电速度",
                    detail: String(
                        format: "线缆最高 %d W < 充电器 %.0f W；换 5 A 线缆可解锁全部功率。",
                        cable.maxWatts,
                        chargerWatts
                    )
                )
            }
        }

        let loadText = load.map { String(format: "整机 %.1f W", $0) } ?? "整机负载未知"
        let inputText = input.map { String(format: "输入 %.1f W", $0) } ?? "输入未知"
        return PowerVerdict(
            severity: .ok,
            title: "供电正常",
            detail: "\(inputText)、\(loadText)；充电器功率充足。"
        )
    }
}

// MARK: - Reader

/// Reads charger and cable details from IOKit. All calls are unprivileged
/// and fast enough to run alongside the 1 s metrics refresh.
enum InterfaceSpecsReader {
    private static let cableClass = "IOPortTransportComponentCCUSBPDSOPp"
    private static let deviceClass = "IOPortTransportComponentCCUSBPDSOP"
    private static let powerSourceClass = "IOPortFeaturePowerSource"
    private static let batteryClass = "AppleSmartBattery"

    static func read() -> InterfaceSpecs {
        var specs = InterfaceSpecs()
        specs.charger = readCharger()
        specs.ports = readPorts()
        return specs
    }

    // MARK: Charger

    private static func readCharger() -> ChargerSpecs? {
        guard let battery = serviceProperties(className: batteryClass).first,
              let adapter = dictionary(battery["AdapterDetails"]) else {
            return nil
        }
        var charger = ChargerSpecs()
        charger.name = string(adapter["Name"])
        charger.manufacturer = string(adapter["Manufacturer"])
        charger.model = string(adapter["Model"])
        charger.serial = string(adapter["SerialString"])
        charger.firmware = string(adapter["FwVersion"])
        charger.hardware = string(adapter["HwVersion"])
        charger.ratedWatts = number(adapter["Watts"])

        if let menu = adapter["UsbHvcMenu"] as? [[String: Any]] {
            charger.options = menu.compactMap { entry in
                guard let voltsMV = number(entry["MaxVoltage"]),
                      let ampsMA = number(entry["MaxCurrent"]),
                      voltsMV > 0 else { return nil }
                return PDOPowerOption(volts: voltsMV / 1_000, amps: ampsMA / 1_000)
            }
        }

        if let telemetry = dictionary(battery["PowerTelemetryData"]) {
            charger.liveVolts = number(telemetry["SystemVoltageIn"]).map { $0 / 1_000 }
            charger.liveAmps = number(telemetry["SystemCurrentIn"]).map { $0 / 1_000 }
            charger.liveWatts = number(telemetry["SystemPowerIn"]).map { $0 / 1_000 }
        }

        for entry in serviceProperties(className: powerSourceClass) {
            guard string(entry["PowerSourceName"]) == "USB-PD" else { continue }
            charger.portNumber = int(entry["ParentBuiltInPortNumber"])
                ?? int(entry["ParentPortNumber"])
            if let winning = dictionary(entry["WinningPowerSourceOption"]),
               let voltsMV = number(winning["Voltage (mV)"]),
               let ampsMA = number(winning["Max Current (mA)"]) {
                charger.negotiated = PDOPowerOption(
                    volts: voltsMV / 1_000,
                    amps: ampsMA / 1_000
                )
            }
            break
        }

        // Negotiated wattage is the PDO's ceiling; when the live measurement
        // is missing, fall back to it so the panel still has a number.
        if charger.liveWatts == nil {
            charger.liveWatts = charger.negotiated?.watts
        }
        return charger
    }

    // MARK: Ports

    private static func readPorts() -> [PortSpecs] {
        var ports: [Int: PortSpecs] = [:]

        func portEntry(_ number: Int) -> PortSpecs {
            if let existing = ports[number] { return existing }
            let fresh = PortSpecs(portNumber: number)
            ports[number] = fresh
            return fresh
        }

        func mutate(_ number: Int, _ body: (inout PortSpecs) -> Void) {
            var entry = portEntry(number)
            body(&entry)
            ports[number] = entry
        }

        for entry in serviceProperties(className: cableClass) {
            guard let number = int(entry["ParentBuiltInPortNumber"])
                ?? int(entry["ParentPortNumber"]) else { continue }
            let metadata = dictionary(entry["Metadata"]) ?? [:]
            let vdos = (metadata["VDOs"] as? [Data]) ?? []
            mutate(number) { port in
                port.cableProductType = string(metadata["Product Type Description"])
                port.cableSpecRevision = int(entry["Specification Revision"])
                port.cableVendorID = int(metadata["Vendor ID"]) ?? int(entry["Vendor ID"])
                port.cableProductID = int(metadata["Product ID"]) ?? int(entry["Product ID"])
                if vdos.count > 1 {
                    port.cableCertXID = vdoFromData(vdos[1])
                }
                if vdos.count > 3, let raw = vdoFromData(vdos[3]) {
                    port.cable = decodeCableCapabilities(raw)
                }
                if (port.cableVendorID ?? 0) == 0 {
                    port.notes.append("厂商 ID 为 0（未标识，白牌 e-marker 常见）")
                }
                if let cable = port.cable, cable.currentRaw == 3 {
                    port.notes.append("电流字段为保留编码")
                }
            }
        }

        for entry in serviceProperties(className: deviceClass) {
            guard let number = int(entry["ParentBuiltInPortNumber"])
                ?? int(entry["ParentPortNumber"]) else { continue }
            let metadata = dictionary(entry["Metadata"]) ?? [:]
            mutate(number) { port in
                port.deviceVendorID = int(metadata["Vendor ID"]) ?? int(entry["Vendor ID"])
                port.deviceProductID = int(metadata["Product ID"]) ?? int(entry["Product ID"])
            }
        }

        for entry in serviceProperties(className: powerSourceClass) {
            guard string(entry["PowerSourceName"]) == "USB-PD" else { continue }
            guard let number = int(entry["ParentBuiltInPortNumber"])
                ?? int(entry["ParentPortNumber"]) else { continue }
            mutate(number) { $0.isChargerPort = true }
        }

        return ports.values.sorted { $0.portNumber < $1.portNumber }
    }

    // MARK: Decoding helpers

    static func decodeCableCapabilities(_ vdo: UInt32) -> CableCapabilities {
        CableCapabilities(
            speedRaw: Int(vdo & 0b111),
            currentRaw: Int((vdo >> 5) & 0b11),
            maxVoltsRaw: Int((vdo >> 9) & 0b11),
            plugRaw: Int((vdo >> 18) & 0b11),
            eprCapable: (vdo >> 17) & 1 == 1
        )
    }

    static func vdoFromData(_ data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    private static func serviceProperties(className: String) -> [[String: Any]] {
        guard let matching = IOServiceMatching(className) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var results: [[String: Any]] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dictionary = properties?.takeRetainedValue() as? [String: Any] {
                results.append(dictionary)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return results
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        // IORegistry hands these back as CFDictionary bridged to
        // NSDictionary/[AnyHashable: Any]; normalise the key type.
        if let dictionary = value as? [String: Any] { return dictionary }
        if let dictionary = value as? NSDictionary {
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                if let key = key as? String { result[key] = value }
            }
            return result
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Int { return number }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

// MARK: - Fixtures

extension InterfaceSpecs {
    /// Fixture mirroring the live Mac on 2026-09-13: an Apple 20 W charger on
    /// port 2 and a 240 W / USB4-class passive cable feeding an iPad on port 1.
    static let preview = InterfaceSpecs(
        charger: {
            var charger = ChargerSpecs()
            charger.name = "20W USB-C Power Adapter"
            charger.manufacturer = "Apple Inc."
            charger.model = "0x7004"
            charger.serial = "F1630963LVTPMG9DD"
            charger.firmware = "01040044"
            charger.hardware = "1.0"
            charger.ratedWatts = 20
            charger.options = [
                PDOPowerOption(volts: 5, amps: 3),
                PDOPowerOption(volts: 9, amps: 2.22),
            ]
            charger.negotiated = PDOPowerOption(volts: 9, amps: 2.22)
            charger.liveVolts = 8.54
            charger.liveAmps = 2.16
            charger.liveWatts = 18.5
            charger.portNumber = 2
            return charger
        }(),
        ports: [
            PortSpecs(
                portNumber: 1,
                deviceName: "iPad",
                deviceVendorID: 1452,
                deviceProductID: 28951,
                cableProductType: "被动线",
                cableSpecRevision: 3,
                cableVendorID: 0,
                cableProductID: 0,
                cableCertXID: 0,
                cable: CableCapabilities(
                    speedRaw: 4,
                    currentRaw: 2,
                    maxVoltsRaw: 3,
                    plugRaw: 2,
                    eprCapable: true
                ),
                notes: ["厂商 ID 为 0（未标识，白牌 e-marker 常见）"]
            ),
            PortSpecs(
                portNumber: 2,
                isChargerPort: true,
                deviceName: nil,
                cableProductType: nil,
                cableSpecRevision: nil,
                cableVendorID: nil,
                cableProductID: nil,
                cableCertXID: nil,
                cable: nil,
                notes: []
            ),
        ]
    )
}

extension SystemMetrics {
    /// Live underpowered case: 20 W charger feeding a 27.4 W load with the
    /// iPad drawing 14.9 W, so the battery supplies the missing 8.9 W.
    static let previewUnderpowered = SystemMetrics(
        externalPower: true,
        adapterLimitWatts: 20,
        inputWatts: 18.5,
        inputVoltage: 8.54,
        inputCurrent: 2.16,
        systemWatts: 27.4,
        batteryWatts: -8.9,
        batteryPercent: 67,
        batteryTemperature: 38.5,
        memoryPercent: 73,
        gpuPercent: 54,
        usbOutputs: [
            USBPowerFlow(portIndex: 1, name: "iPad", watts: 14.9, voltage: 5.0, current: 2.9),
        ],
        fanRPMs: [0],
        gpuTemperature: 40.0,
        externalBatteryPercent: 60
    )
}
