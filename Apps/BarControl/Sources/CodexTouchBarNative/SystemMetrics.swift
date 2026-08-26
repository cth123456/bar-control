import AppKit
import Darwin
import IOKit
import PowerTelemetrySupport

struct USBPowerFlow: Equatable, Sendable {
    let portIndex: Int
    let name: String
    let watts: Double
    let voltage: Double?
    let current: Double?
}

struct USBDeviceDescriptor: Equatable, Sendable {
    let name: String
    let locationID: UInt32
}

struct ProcessPowerSample: Equatable, Sendable {
    let name: String
    /// Best-effort watts derived from macOS' per-process billed-energy counter.
    let billedWatts: Double
}

struct HardwarePowerSample: Equatable, Sendable {
    let cpuWatts: Double?
    let gpuWatts: Double?
    let processes: [ProcessPowerSample]

    static let unavailable = HardwarePowerSample(
        cpuWatts: nil,
        gpuWatts: nil,
        processes: []
    )
}

struct SystemMetrics: Equatable, Sendable {
    let externalPower: Bool
    let adapterLimitWatts: Double?
    /// Live power entering the Mac from the selected charger.
    let inputWatts: Double?
    let inputVoltage: Double?
    let inputCurrent: Double?
    let systemWatts: Double?
    /// Positive while charging, negative while discharging.
    let batteryWatts: Double?
    let batteryPercent: Int?
    let batteryTemperature: Double?
    let memoryPercent: Double?
    let gpuPercent: Double?
    let usbOutputs: [USBPowerFlow]
    let cpuWatts: Double?
    let gpuWatts: Double?
    let processPower: [ProcessPowerSample]
    let fanRPMs: [Double]
    let gpuTemperature: Double?

    init(
        externalPower: Bool,
        adapterLimitWatts: Double?,
        inputWatts: Double?,
        inputVoltage: Double?,
        inputCurrent: Double?,
        systemWatts: Double?,
        batteryWatts: Double?,
        batteryPercent: Int?,
        batteryTemperature: Double?,
        memoryPercent: Double?,
        gpuPercent: Double?,
        usbOutputs: [USBPowerFlow],
        cpuWatts: Double? = nil,
        gpuWatts: Double? = nil,
        processPower: [ProcessPowerSample] = [],
        fanRPMs: [Double] = [],
        gpuTemperature: Double? = nil
    ) {
        self.externalPower = externalPower
        self.adapterLimitWatts = adapterLimitWatts
        self.inputWatts = inputWatts
        self.inputVoltage = inputVoltage
        self.inputCurrent = inputCurrent
        self.systemWatts = systemWatts
        self.batteryWatts = batteryWatts
        self.batteryPercent = batteryPercent
        self.batteryTemperature = batteryTemperature
        self.memoryPercent = memoryPercent
        self.gpuPercent = gpuPercent
        self.usbOutputs = usbOutputs
        self.cpuWatts = cpuWatts
        self.gpuWatts = gpuWatts
        self.processPower = processPower
        self.fanRPMs = fanRPMs
        self.gpuTemperature = gpuTemperature
    }

    static let unavailable = SystemMetrics(
        externalPower: false,
        adapterLimitWatts: nil,
        inputWatts: nil,
        inputVoltage: nil,
        inputCurrent: nil,
        systemWatts: nil,
        batteryWatts: nil,
        batteryPercent: nil,
        batteryTemperature: nil,
        memoryPercent: nil,
        gpuPercent: nil,
        usbOutputs: []
    )

    static let preview = SystemMetrics(
        externalPower: true,
        adapterLimitWatts: 85,
        inputWatts: 83.98,
        inputVoltage: 20,
        inputCurrent: 4.199,
        systemWatts: 23.7,
        batteryWatts: 61.2,
        batteryPercent: 47,
        batteryTemperature: 33.7,
        memoryPercent: 61,
        gpuPercent: 28,
        usbOutputs: [
            USBPowerFlow(portIndex: 1, name: "iPad", watts: 10.7, voltage: 5.1, current: 2.1),
            USBPowerFlow(portIndex: 2, name: "USB-C 显示器", watts: 3.83, voltage: 5.0, current: 0.77),
            USBPowerFlow(portIndex: 3, name: "USB-C 设备", watts: 9.15, voltage: 5.0, current: 1.83)
        ]
    )

    static let previewBatteryIdle = SystemMetrics(
        externalPower: true,
        adapterLimitWatts: 85,
        inputWatts: 23.7,
        inputVoltage: 20,
        inputCurrent: 1.185,
        systemWatts: 23.7,
        batteryWatts: 0,
        batteryPercent: 80,
        batteryTemperature: 32.8,
        memoryPercent: 58,
        gpuPercent: 17,
        usbOutputs: preview.usbOutputs
    )

    static let previewBatteryDischarging = SystemMetrics(
        externalPower: true,
        adapterLimitWatts: 20,
        inputWatts: 12.9,
        inputVoltage: 20,
        inputCurrent: 0.645,
        systemWatts: 13.1,
        batteryWatts: -0.2,
        batteryPercent: 80,
        batteryTemperature: 32.8,
        memoryPercent: 58,
        gpuPercent: 17,
        usbOutputs: []
    )

    /// Matches the approved 1290×563 light reference so geometry and text
    /// scale can be compared at the same visual state during render QA.
    static let previewCompactReference = SystemMetrics(
        externalPower: true,
        adapterLimitWatts: 67,
        inputWatts: 66.8,
        inputVoltage: 20,
        inputCurrent: 3.34,
        systemWatts: 25.59,
        batteryWatts: 41.21,
        batteryPercent: 80,
        batteryTemperature: 32.8,
        memoryPercent: 58,
        gpuPercent: 17,
        usbOutputs: []
    )

    static let previewOneDeviceMissing = SystemMetrics(
        externalPower: true,
        adapterLimitWatts: 85,
        inputWatts: 80.15,
        inputVoltage: 20,
        inputCurrent: 4.008,
        systemWatts: 19.87,
        batteryWatts: 61.2,
        batteryPercent: 47,
        batteryTemperature: 33.7,
        memoryPercent: 61,
        gpuPercent: 28,
        usbOutputs: [preview.usbOutputs[0], preview.usbOutputs[2]]
    )

    static let previewSingleOutput = SystemMetrics(
        externalPower: true,
        adapterLimitWatts: 85,
        inputWatts: 72.4,
        inputVoltage: 20,
        inputCurrent: 3.62,
        systemWatts: 11.2,
        batteryWatts: 61.2,
        batteryPercent: 47,
        batteryTemperature: 33.7,
        memoryPercent: 61,
        gpuPercent: 28,
        usbOutputs: [preview.usbOutputs[0]]
    )

    /// Underpowered-adapter hierarchy fixture from IMG_4665: 84 W from the
    /// charger and 3.47 W from the battery join the whole-machine node before
    /// splitting across three measured consumers.
    static let previewDynamicHierarchy = SystemMetrics(
        externalPower: true,
        adapterLimitWatts: 84,
        inputWatts: 84.0,
        inputVoltage: 20,
        inputCurrent: 4.20,
        systemWatts: 89.0,
        batteryWatts: -3.47,
        batteryPercent: 80,
        batteryTemperature: 32.8,
        memoryPercent: 61,
        gpuPercent: 28,
        usbOutputs: [
            USBPowerFlow(portIndex: 1, name: "CPU", watts: 58.6, voltage: nil, current: nil),
            USBPowerFlow(portIndex: 2, name: "USB-C 显示器", watts: 3.90, voltage: nil, current: nil),
            USBPowerFlow(portIndex: 3, name: "USB-C 设备", watts: 26.7, voltage: nil, current: nil)
        ]
    )

    /// Low positive battery charge with no external outputs. This isolates the
    /// compact branch/card proportional allocation and left-to-right charging
    /// animation from the third-level fan-out.
    static let previewCompactLowBatteryCharging = SystemMetrics(
        externalPower: true,
        adapterLimitWatts: 89,
        inputWatts: 87.47,
        inputVoltage: 20,
        inputCurrent: 4.374,
        systemWatts: 84.0,
        batteryWatts: 3.47,
        batteryPercent: 80,
        batteryTemperature: 32.8,
        memoryPercent: 61,
        gpuPercent: 28,
        usbOutputs: []
    )

    static let previewWithoutOutputs = SystemMetrics(
        externalPower: false,
        adapterLimitWatts: nil,
        inputWatts: nil,
        inputVoltage: nil,
        inputCurrent: nil,
        systemWatts: 18.4,
        batteryWatts: -18.4,
        batteryPercent: 71,
        batteryTemperature: 32.8,
        memoryPercent: 58,
        gpuPercent: 17,
        usbOutputs: []
    )

    /// Explicit design fixture for the new internal-consumer hierarchy. These
    /// values are used only for deterministic preview rendering; live UI data
    /// comes from IOReport and the kernel billed-energy counters below.
    static let previewInternalBreakdown = SystemMetrics(
        externalPower: true,
        adapterLimitWatts: 67,
        inputWatts: 41.8,
        inputVoltage: 20,
        inputCurrent: 2.09,
        systemWatts: 34.6,
        batteryWatts: 7.2,
        batteryPercent: 76,
        batteryTemperature: 32.6,
        memoryPercent: 62,
        gpuPercent: 41,
        usbOutputs: [],
        cpuWatts: 16.8,
        gpuWatts: 9.4,
        processPower: [
            ProcessPowerSample(name: "WindowServer", billedWatts: 1.26),
            ProcessPowerSample(name: "Codex", billedWatts: 0.84)
        ],
        fanRPMs: [0],
        gpuTemperature: 51.8
    )

    /// User-facing fixture for a Mac that is simultaneously powered by a
    /// charger and its battery while supplying an iPad. The values reconcile
    /// in one snapshot: 32.7 W total - 15.0 W external = 17.7 W local.
    static let previewLocalAndExternalBreakdown = SystemMetrics(
        externalPower: true,
        adapterLimitWatts: 20,
        inputWatts: 12.6,
        inputVoltage: 20,
        inputCurrent: 0.63,
        systemWatts: 32.7,
        batteryWatts: -20.1,
        batteryPercent: 68,
        batteryTemperature: 33.4,
        memoryPercent: 63,
        gpuPercent: 36,
        usbOutputs: [
            USBPowerFlow(portIndex: 1, name: "iPad", watts: 15.0, voltage: 5.0, current: 3.0)
        ],
        gpuWatts: 4.4,
        fanRPMs: [2_160],
        gpuTemperature: 63.9
    )

    /// Positive power currently leaving the Mac through measured USB-C ports.
    var externalOutputWatts: Double {
        usbOutputs.reduce(0) { partial, output in
            partial + max(0, output.watts.isFinite ? output.watts : 0)
        }
    }

    /// Power consumed by the Mac itself, excluding power forwarded to attached
    /// devices. Both terms come from this same telemetry snapshot.
    var localComputerWatts: Double? {
        guard let wholeMachine = systemWatts ?? sourceWatts,
              wholeMachine.isFinite else { return nil }
        return max(0, wholeMachine - externalOutputWatts)
    }

    /// Positive contribution from the battery to the active load.
    var batterySupplyWatts: Double {
        guard let batteryWatts, batteryWatts.isFinite else { return 0 }
        return max(0, -batteryWatts)
    }

    /// Positive power currently being stored in the battery.
    var batteryChargeWatts: Double {
        guard let batteryWatts, batteryWatts.isFinite else { return 0 }
        return max(0, batteryWatts)
    }

    var sourceWatts: Double? {
        if externalPower {
            return inputWatts ?? systemWatts
        }
        return batteryWatts.map { abs($0) } ?? systemWatts
    }
}

enum SystemMetricsReader {
    static func fetch() async -> SystemMetrics {
        await Task.detached(priority: .utility) { read() }.value
    }

    static func read() -> SystemMetrics {
        let battery = registryProperties(className: "AppleSmartBattery")
        let pack = registryProperties(className: "AppleSmartBatteryPack")
        let gpu = registryProperties(className: "AGXAccelerator")

        let telemetry = dictionary(battery["PowerTelemetryData"])
        let distribution = dictionary(battery["PowerDistribution"])
        let adapter = dictionary(battery["AdapterDetails"])
        let packData = dictionary(pack["BatteryData"])

        let externalPower = boolean(battery["ExternalConnected"]) ?? false
        let adapterLimit = number(adapter["Watts"])
            ?? number(distribution["IPDInputPower"]).map { $0 / 1_000 }
        let inputWatts = number(telemetry["SystemPowerIn"]).map { $0 / 1_000 }
        let inputVoltage = number(telemetry["SystemVoltageIn"]).map { $0 / 1_000 }
        let inputCurrent = number(telemetry["SystemCurrentIn"]).map { $0 / 1_000 }
        let systemWatts = number(telemetry["SystemLoad"])
            .map { $0 / 1_000 }
            ?? inputWatts

        let voltage = number(battery["Voltage"])
        let current = signedNumber(battery["InstantAmperage"])
            ?? signedNumber(battery["Amperage"])
        let currentDerivedBatteryPower: Double? = {
            guard let voltage, let current else { return nil }
            return voltage * current / 1_000_000
        }()
        let telemetryBatteryPower = signedNumber(telemetry["BatteryPower"]).map { $0 / 1_000 }
        let batteryWatts = currentDerivedBatteryPower.flatMap { abs($0) > 0.01 ? $0 : nil }
            ?? telemetryBatteryPower

        let rawTemperature = number(packData["Temperature"])
            ?? number(packData["VirtualTemperature"])
        let temperature = rawTemperature.map { raw -> Double in
            if raw > 1_000 { return raw / 100 }
            return raw > 200 ? raw / 10 - 273.15 : raw / 10
        }

        let performance = dictionary(gpu["PerformanceStatistics"])
        let gpuPercent = gpuUsagePercent(performance)
        let hardwarePower = PowerTelemetrySampler.shared.read()
        let fanRPMs = readFanRPMs()
        let gpuTemperature = readGPUTemperature()

        return SystemMetrics(
            externalPower: externalPower,
            adapterLimitWatts: adapterLimit,
            inputWatts: inputWatts,
            inputVoltage: inputVoltage,
            inputCurrent: inputCurrent,
            systemWatts: systemWatts,
            batteryWatts: batteryWatts,
            batteryPercent: number(battery["CurrentCapacity"]).map { Int($0.rounded()) },
            batteryTemperature: temperature,
            memoryPercent: memoryUsagePercent(),
            gpuPercent: gpuPercent,
            usbOutputs: decodePowerOutputs(
                raw: battery["PowerOutDetails"],
                usbDevices: usbDevices()
            ),
            cpuWatts: hardwarePower.cpuWatts,
            gpuWatts: hardwarePower.gpuWatts,
            processPower: hardwarePower.processes,
            fanRPMs: fanRPMs,
            gpuTemperature: gpuTemperature
        )
    }

    private static func readFanRPMs() -> [Double] {
        var values = [Double](repeating: 0, count: 4)
        let count = values.withUnsafeMutableBufferPointer { buffer in
            Int(bcpt_read_fan_rpms(buffer.baseAddress, Int32(buffer.count)))
        }
        guard count > 0 else { return [] }
        return Array(values.prefix(min(count, values.count)))
            .filter { $0.isFinite && $0 >= 0 }
    }

    private static func readGPUTemperature() -> Double? {
        var value = 0.0
        guard bcpt_read_gpu_temperature(&value) == 1,
              value.isFinite,
              value > 10,
              value < 150 else { return nil }
        return value
    }

    static func decodePowerOutputs(raw: Any?, usbDevices: [USBDeviceDescriptor]) -> [USBPowerFlow] {
        let entries = raw as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            let portIndex = Int(number(entry["PortIndex"]) ?? -1)
            guard portIndex >= 0 else { return nil }
            let rawPower = ["Watts", "FilteredPower", "PDPowermW"]
                .compactMap { number(entry[$0]) }
                .first(where: { $0 > 0 }) ?? 0
            guard rawPower > 50 else { return nil }
            let exactLocation = number(entry["LocationID"]).map { UInt32($0) }
            let candidates = usbDevices.filter { device in
                if let exactLocation, exactLocation != 0, device.locationID == exactLocation { return true }
                let controller = Int((device.locationID >> 24) & 0xFF) + 1
                return controller == portIndex
            }
            let device = candidates.sorted { lhs, rhs in
                devicePriority(lhs.name) > devicePriority(rhs.name)
            }.first
            let name = device?.name ?? "USB-C 设备 · 端口 \(portIndex)"
            return USBPowerFlow(
                portIndex: portIndex,
                name: name,
                watts: rawPower / 1_000,
                voltage: number(entry["AdapterVoltage"])
                    .flatMap { $0 > 0 ? $0 / 1_000 : nil }
                    ?? number(entry["ConfiguredVoltage"]).flatMap { $0 > 0 ? $0 / 1_000 : nil },
                current: number(entry["Current"]).flatMap { $0 > 0 ? $0 / 1_000 : nil }
            )
        }.sorted { $0.portIndex < $1.portIndex }
    }

    static func gpuUsagePercent(_ performance: [String: Any]) -> Double? {
        ["Device Utilization %", "Renderer Utilization %", "Tiler Utilization %"]
            .compactMap { number(performance[$0]) }
            .max()
            .map { min(100, max(0, $0)) }
    }

    private static func usbDevices() -> [USBDeviceDescriptor] {
        registryPropertyList(className: "IOUSBHostDevice").compactMap { properties in
            let rawName = (properties["kUSBProductString"] as? String)
                ?? (properties["USB Product Name"] as? String)
            guard let rawName, !rawName.isEmpty else { return nil }
            let locationID = number(properties["locationID"]).map { UInt32($0) } ?? 0
            return USBDeviceDescriptor(name: friendlyDeviceName(rawName), locationID: locationID)
        }
    }

    private static func devicePriority(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.contains("ipad") || lower.contains("iphone") { return 3 }
        if lower.contains("hub") { return 0 }
        return 2
    }

    private static func friendlyDeviceName(_ name: String) -> String {
        if name.localizedCaseInsensitiveContains("iPad") { return "iPad" }
        if name.localizedCaseInsensitiveContains("iPhone") { return "iPhone" }
        if name.localizedCaseInsensitiveContains("Wireless Charging Case") { return "AirPods 充电盒" }
        return name
    }

    private static func registryProperties(className: String) -> [String: Any] {
        guard let matching = IOServiceMatching(className) else { return [:] }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return [:] }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &properties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS else { return [:] }
        return properties?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    private static func registryPropertyList(className: String) -> [[String: Any]] {
        guard let matching = IOServiceMatching(className) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(
                service,
                &properties,
                kCFAllocatorDefault,
                0
            ) == KERN_SUCCESS,
               let dictionary = properties?.takeRetainedValue() as? [String: Any] {
                result.append(dictionary)
            }
        }
        return result
    }

    private static func memoryUsagePercent() -> Double? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let usedPages = UInt64(statistics.internal_page_count)
            + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }
        return min(100, max(0, Double(usedPages * UInt64(pageSize)) / Double(total) * 100))
    }

    private static func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func signedNumber(_ value: Any?) -> Double? {
        (value as? NSNumber).map { Double($0.int64Value) }
    }

    private static func boolean(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }
}

/// Serializes access to the cumulative IOReport subscription. The controller
/// reads once per second, so each call advances a single well-defined baseline.
final class PowerTelemetrySampler: @unchecked Sendable {
    static let shared = PowerTelemetrySampler()

    private let lock = NSLock()
    private var sampler: OpaquePointer?

    private init() {
        sampler = bcpt_sampler_create()
    }

    deinit {
        if let sampler {
            bcpt_sampler_destroy(sampler)
        }
    }

    func read() -> HardwarePowerSample {
        lock.lock()
        defer { lock.unlock() }
        guard let sampler else { return .unavailable }

        var cpuWatts = 0.0
        var gpuWatts = 0.0
        var hasCPU = false
        var hasGPU = false
        let hasDelta = bcpt_sampler_read(
            sampler,
            &cpuWatts,
            &hasCPU,
            &gpuWatts,
            &hasGPU
        ) != 0
        guard hasDelta else { return .unavailable }

        let processCount = max(0, Int(bcpt_sampler_process_count(sampler)))
        let processes = (0..<processCount).compactMap { index -> ProcessPowerSample? in
            guard let rawName = bcpt_sampler_process_name(sampler, Int32(index)) else {
                return nil
            }
            let watts = bcpt_sampler_process_watts(sampler, Int32(index))
            guard watts.isFinite, watts >= 0.001 else { return nil }
            return ProcessPowerSample(
                name: String(cString: rawName),
                billedWatts: watts
            )
        }
        return HardwarePowerSample(
            cpuWatts: hasCPU && cpuWatts.isFinite ? cpuWatts : nil,
            gpuWatts: hasGPU && gpuWatts.isFinite ? gpuWatts : nil,
            processes: processes
        )
    }
}

enum PowerRunnerStyle: String, CaseIterable {
    case cat
    case coffee
    case dog
    case drop
    case engine
    case mochi
    case newtonCradle = "newton-cradle"
    case slime

    static let defaultsKey = "powerRunnerStyle.v1"

    var title: String {
        switch self {
        case .cat: return "跑猫"
        case .coffee: return "咖啡"
        case .dog: return "跑狗"
        case .drop: return "水滴"
        case .engine: return "引擎"
        case .mochi: return "麻薯"
        case .newtonCradle: return "牛顿摆"
        case .slime: return "史莱姆"
        }
    }

    var framePrefix: String { rawValue }

    var frameCount: Int {
        switch self {
        case .coffee, .engine: return 10
        default: return 5
        }
    }

    static func load() -> PowerRunnerStyle {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(PowerRunnerStyle.init(rawValue:)) ?? .cat
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

@MainActor
final class PowerRunnerButton: NSButton {
    var watts: Double? {
        didSet {
            contentTintColor = Self.tintColor(for: watts)
            updateToolTip()
            if isAnimating,
               abs(Self.framesPerSecond(for: watts) - Self.framesPerSecond(for: oldValue)) > 0.2 {
                scheduleTimer()
            }
        }
    }
    private(set) var isAnimating = false
    private(set) var animationFrame = 0
    private(set) var style: PowerRunnerStyle
    var frameCount: Int { frames.count }
    private var frames: [NSImage] = []
    private var animationTimer: Timer?

    init(target: AnyObject?, action: Selector, style: PowerRunnerStyle = .load()) {
        self.style = style
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        contentTintColor = .systemTeal
        setAccessibilityLabel("整机功率动画")
        setAccessibilityHelp("点击进入 Touch Bar 整机详细信息")
        frames = Self.loadFrames(for: style)
        image = frames.first ?? NSImage(systemSymbolName: "hare.fill", accessibilityDescription: "整机功率")
        updateToolTip()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stopAnimating() : startAnimating()
    }

    func startAnimating() {
        guard animationTimer == nil, frames.count > 1 else { return }
        isAnimating = true
        scheduleTimer()
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        isAnimating = false
    }

    func setStyle(_ style: PowerRunnerStyle) {
        guard self.style != style || frames.isEmpty else { return }
        self.style = style
        frames = Self.loadFrames(for: style)
        animationFrame = 0
        image = frames.first ?? NSImage(systemSymbolName: "hare.fill", accessibilityDescription: "整机功率")
        updateToolTip()
        if isAnimating { scheduleTimer() }
    }

    static func framesPerSecond(for watts: Double?) -> Double {
        guard let watts, watts.isFinite else { return 2 }
        return min(14, max(2, 2 + watts / 6))
    }

    private func tick() {
        animationFrame += 1
        image = frames[animationFrame % frames.count]
    }

    private func scheduleTimer() {
        animationTimer?.invalidate()
        let timer = Timer(timeInterval: 1 / Self.framesPerSecond(for: watts), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateToolTip() {
        toolTip = watts.map { String(format: "%@ · 整机功率 %.1f W，点击查看详细信息", style.title, $0) }
            ?? "\(style.title) · 整机功率读取中，点击查看详细信息"
    }

    private static func tintColor(for watts: Double?) -> NSColor {
        guard let watts else { return .secondaryLabelColor }
        switch watts {
        case ..<25: return .systemGreen
        case ..<50: return .systemTeal
        case ..<75: return .systemOrange
        default: return .systemRed
        }
    }

    private static func loadFrames(for style: PowerRunnerStyle) -> [NSImage] {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/RunCatNeo")
        let installedRoot = Bundle.main.resourceURL?.appendingPathComponent("RunCatNeo")
        let roots = [installedRoot, sourceRoot].compactMap { $0 }
        return (0..<style.frameCount).compactMap { index in
            let name = "\(style.framePrefix)-frame-\(index).png"
            let url = roots
                .map { $0.appendingPathComponent(style.rawValue).appendingPathComponent(name) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
                ?? sourceRoot.appendingPathComponent(style.rawValue).appendingPathComponent(name)
            guard let image = NSImage(contentsOf: url) else { return nil }
            image.isTemplate = true
            let naturalSize = image.size
            let width = min(44, max(18, naturalSize.width / max(1, naturalSize.height) * 18))
            image.size = NSSize(width: width, height: 18)
            return image
        }
    }
}

@MainActor
final class SystemDetailStripView: NSView {
    var metrics = SystemMetrics.unavailable {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(accessibilitySummary)
        }
    }

    init(width: CGFloat = 457, height: CGFloat = 30) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let cards: [(String, String, String, NSColor, CGFloat)] = [
            ("整机功率", watts(metrics.systemWatts ?? metrics.sourceWatts), "bolt.fill", .systemTeal, 66),
            ("内存占用", percent(metrics.memoryPercent), "memorychip", .systemPurple, 62),
            ("GPU 占用", percent(metrics.gpuPercent), "gauge.with.dots.needle.67percent", .systemBlue, 58),
            ("电池温度", temperature, "thermometer.medium", .systemGreen, 72),
            ("电池状态", batteryStatus, "battery.75percent", batteryColor, 92),
            ("端口功率", portPower, "cable.connector", .systemYellow, 92)
        ]
        var x: CGFloat = 0
        for card in cards {
            drawCard(x: x, title: card.0, value: card.1, symbol: card.2, color: card.3, width: card.4)
            x += card.4 + 3
        }
    }

    private var batteryStatus: String {
        let level = metrics.batteryPercent.map { "\($0)%" } ?? "--%"
        guard let power = metrics.batteryWatts else { return level }
        if metrics.externalPower {
            if power > 0.05 { return String(format: "%@·充电%.1fW", level, power) }
            if power < -0.05 { return String(format: "%@·放电%.1fW", level, abs(power)) }
            return "\(level)·保持"
        }
        return String(format: "%@·放电%.1fW", level, abs(power))
    }

    private var batteryColor: NSColor {
        guard let power = metrics.batteryWatts else { return .secondaryLabelColor }
        return power < -0.05 ? .systemOrange : .systemGreen
    }

    private var portPower: String {
        let input = metrics.inputWatts.map { String(format: "入%.1f", $0) } ?? "入--"
        let output = metrics.usbOutputs.reduce(0) { $0 + $1.watts }
        return output > 0.05 ? String(format: "%@·出%.1fW", input, output) : "\(input)W"
    }

    private var temperature: String {
        metrics.batteryTemperature.map { String(format: "%.1f°C", $0) } ?? "--°C"
    }

    private var accessibilitySummary: String {
        "整机功率 \(watts(metrics.systemWatts ?? metrics.sourceWatts))，内存占用 \(percent(metrics.memoryPercent))，GPU 占用 \(percent(metrics.gpuPercent))，电池温度 \(temperature)，电池状态 \(batteryStatus)，端口功率 \(portPower)"
    }

    private func drawCard(
        x: CGFloat,
        title: String,
        value: String,
        symbol: String,
        color: NSColor,
        width: CGFloat
    ) {
        let rect = NSRect(x: x, y: 0, width: width, height: 30)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        color.withAlphaComponent(0.22).setFill()
        path.fill()
        color.withAlphaComponent(0.52).setStroke()
        path.lineWidth = 0.8
        path.stroke()
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(configuration)?
            .draw(in: NSRect(x: rect.minX + 4, y: 17, width: 9, height: 9))
        drawText(title, in: NSRect(x: rect.minX + 15, y: 16, width: rect.width - 18, height: 10), size: 6.8, color: .secondaryLabelColor)
        drawText(value, in: NSRect(x: rect.minX + 5, y: 3, width: rect.width - 10, height: 14), size: 9.2, color: .white, monospaced: true)
    }

    private func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-- W" }
        return value >= 100 ? String(format: "%.0f W", value) : String(format: "%.1f W", value)
    }

    private func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--%" }
        return String(format: "%.0f%%", value)
    }

    private func drawText(_ text: String, in rect: NSRect, size: CGFloat, color: NSColor, monospaced: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: monospaced
                ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
                : NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }
}

@MainActor
enum PowerFlowStyle: String, CaseIterable {
    case alDente
    case ribbon
    case capsule
    case neon
    case minimal
}

final class PowerFlowView: NSView {
    var metrics = SystemMetrics.unavailable {
        didSet { needsDisplay = true }
    }
    var style: PowerFlowStyle = .ribbon {
        didSet { needsDisplay = true }
    }
    private(set) var isAnimating = false
    private(set) var animationFrame = 0
    private var animationTimer: Timer?
    private var flowPhase: CGFloat = 0

    init(width: CGFloat = 390, height: CGFloat = 390) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startAnimating() {
        guard animationTimer == nil else { return }
        isAnimating = true
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceFlow() }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        isAnimating = false
    }

    static func flowSpeed(for watts: Double) -> CGFloat {
        guard watts.isFinite, watts > 0.05 else { return 0 }
        return min(4, max(0.7, CGFloat(sqrt(watts)) * 0.55))
    }

    static func dashPhase(for watts: Double, frame: CGFloat, reversed: Bool) -> CGFloat {
        // Positive dash phase moves toward the path start in NSBezierPath.
        flowSpeed(for: watts) * frame * (reversed ? 1 : -1)
    }

    private func advanceFlow() {
        animationFrame += 1
        flowPhase = (flowPhase + 1).truncatingRemainder(dividingBy: 10_000)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawText(
            "整机能源流",
            in: NSRect(x: 14, y: 356, width: 138, height: 22),
            font: .systemFont(ofSize: 16, weight: .semibold),
            color: .labelColor
        )
        drawText(
            batteryStatus,
            in: NSRect(x: 150, y: 359, width: 224, height: 17),
            font: .monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            color: batteryColor,
            alignment: .right
        )
        NSColor.separatorColor.withAlphaComponent(0.32).setStroke()
        let headerSeparator = NSBezierPath()
        headerSeparator.move(to: NSPoint(x: 14, y: 344))
        headerSeparator.line(to: NSPoint(x: 376, y: 344))
        headerSeparator.lineWidth = 0.6
        headerSeparator.stroke()
        drawPowerTopology()
        drawStatusCards()
        drawText(
            footerText,
            in: NSRect(x: 16, y: 4, width: 358, height: 12),
            font: .systemFont(ofSize: 8.5, weight: .regular),
            color: .tertiaryLabelColor,
            alignment: .center
        )
    }

    private func drawPowerTopology() {
        if style == .alDente {
            drawAlDenteTopology()
            return
        }
        let charger = NSPoint(x: 64, y: 212)
        let system = NSPoint(x: 194, y: 156)
        let battery = NSPoint(x: 194, y: 260)

        let inputPower = metrics.inputWatts ?? metrics.sourceWatts
        let batteryPower = metrics.batteryWatts ?? 0
        let batteryReversed = batteryPower < -0.05
        let batteryFlowColor: NSColor = batteryReversed ? .systemOrange : .systemGreen
        let batteryStart = batteryReversed
            ? NSPoint(x: 190, y: 232)
            : NSPoint(x: 190, y: 186)
        let batteryEnd = batteryReversed
            ? NSPoint(x: 190, y: 186)
            : NSPoint(x: 190, y: 232)

        let outputs = Array(metrics.usbOutputs.prefix(3))
        let centers: [NSPoint] = outputs.count == 1
            ? [NSPoint(x: 332, y: 176)]
            : (outputs.count == 2
                ? [NSPoint(x: 332, y: 210), NSPoint(x: 332, y: 142)]
                : [NSPoint(x: 332, y: 236), NSPoint(x: 332, y: 176), NSPoint(x: 332, y: 116)])

        drawFlow(
            from: NSPoint(x: 76, y: 212),
            to: NSPoint(x: 158, y: 164),
            color: metrics.externalPower ? .systemYellow : .systemGreen,
            power: inputPower,
            label: watts(inputPower),
            arc: 26
        )
        if metrics.externalPower {
            drawFlow(
                from: batteryStart,
                to: batteryEnd,
                color: batteryFlowColor,
                power: abs(batteryPower),
                label: batteryFlowValue,
                arc: 28
            )
        }

        for (index, output) in outputs.enumerated() {
            let center = centers[index]
            drawFlow(
                from: NSPoint(x: 224, y: system.y - CGFloat(index) * 8),
                to: NSPoint(x: 312, y: center.y),
                color: .systemTeal,
                power: output.watts,
                label: watts(output.watts),
                arc: 20
            )
        }

        drawIconNode(
            center: charger,
            icon: sourceSymbol,
            color: sourceColor,
            primary: sourceNodeValue,
            secondary: metrics.externalPower ? "充电器" : "电池供电"
        )
        drawIconNode(center: system, icon: "laptopcomputer", color: .systemBlue, secondary: "Mac 整机")
        if metrics.externalPower {
            drawIconNode(
                center: battery,
                icon: batteryReversed ? "battery.25percent" : "battery.75percent",
                color: batteryFlowColor,
                primary: batteryFlowStatus,
                secondary: metrics.batteryPercent.map { "电池 \($0)%" } ?? "电池"
            )
        }
        for (index, output) in outputs.enumerated() {
            let center = centers[index]
            drawIconNode(
                center: center,
                icon: deviceSymbol(for: output.name),
                color: .systemTeal,
                secondary: output.name
            )
        }
    }

    private func drawAlDenteTopology() {
        let inputPower = metrics.inputWatts ?? metrics.sourceWatts
        let batteryPower = metrics.batteryWatts ?? 0
        let batteryReversed = batteryPower < -0.05
        let batteryFlowColor: NSColor = batteryReversed ? .systemOrange : .systemGreen
        let outputs = Array(metrics.usbOutputs.prefix(3))

        // Top battery band, like AlDente's green charge bar
        let barRect = NSRect(x: 24, y: 300, width: 342, height: 26)
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: 13, yRadius: 13)
        batteryFlowColor.withAlphaComponent(0.92).setFill()
        barPath.fill()
        drawText(
            metrics.batteryPercent.map { "\($0)%" } ?? "--%",
            in: NSRect(x: 36, y: 303, width: 56, height: 18),
            font: .monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            color: .white,
            alignment: .left
        )
        if metrics.externalPower {
            drawText(
                batteryFlowStatus,
                in: NSRect(x: 220, y: 305, width: 138, height: 16),
                font: .systemFont(ofSize: 10, weight: .semibold),
                color: .white,
                alignment: .right
            )
        }

        // Charger node: bottom-left
        let chargerPoint = NSPoint(x: 68, y: 148)
        drawIconNode(
            center: NSPoint(x: 34, y: 148),
            icon: sourceSymbol,
            color: sourceColor,
            primary: sourceNodeValue,
            secondary: metrics.externalPower ? "充电器" : "电池供电"
        )

        // Main vertical ribbon from charger up to the system junction
        let junction = NSPoint(x: 138, y: 258)
        drawFlow(
            from: chargerPoint,
            to: junction,
            color: metrics.externalPower ? .systemYellow : .systemGreen,
            power: inputPower,
            label: nil,
            arc: 42
        )
        let topPoint = bezierMidpoint(from: chargerPoint, to: junction, t: 0.76, arc: 42)
        drawText(
            watts(inputPower),
            in: NSRect(x: topPoint.x - 40, y: topPoint.y - 8, width: 80, height: 16),
            font: .monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            color: .labelColor,
            alignment: .center
        )
        if metrics.externalPower {
            let bottomPoint = bezierMidpoint(from: chargerPoint, to: junction, t: 0.34, arc: 42)
            drawText(
                batteryFlowValue,
                in: NSRect(x: bottomPoint.x - 40, y: bottomPoint.y - 8, width: 80, height: 16),
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                color: .labelColor,
                alignment: .center
            )
        }

        // Mac node at the junction
        drawIconNode(center: junction, icon: "laptopcomputer", color: .systemBlue, secondary: "Mac 整机")

        // Devices on the right
        let centers: [NSPoint] = outputs.count == 1
            ? [NSPoint(x: 348, y: 205)]
            : (outputs.count == 2
                ? [NSPoint(x: 348, y: 232), NSPoint(x: 348, y: 178)]
                : [NSPoint(x: 348, y: 250), NSPoint(x: 348, y: 205), NSPoint(x: 348, y: 160)])
        for (index, output) in outputs.enumerated() {
            let center = centers[index]
            let flowStart = NSPoint(x: 172, y: junction.y - CGFloat(index) * 16)
            let flowEnd = NSPoint(x: 318, y: center.y)
            drawFlow(
                from: flowStart,
                to: flowEnd,
                color: .systemTeal,
                power: output.watts,
                label: nil,
                arc: 26
            )
            let labelPoint = bezierMidpoint(from: flowStart, to: flowEnd, t: 0.44, arc: 26)
            drawText(
                watts(output.watts),
                in: NSRect(x: labelPoint.x - 34, y: labelPoint.y - 8, width: 68, height: 16),
                font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
                color: .labelColor,
                alignment: .center
            )
            drawIconNode(center: center, icon: deviceSymbol(for: output.name), color: .systemTeal, secondary: output.name)
        }
    }

    private var sourceColor: NSColor {
        metrics.externalPower ? .systemYellow : .systemGreen
    }

    private var sourceSymbol: String {
        metrics.externalPower ? "powerplug.fill" : "battery.75percent"
    }

    private var sourceNodeValue: String {
        if metrics.externalPower {
            return metrics.adapterLimitWatts.map { "\(Int($0.rounded()))W" } ?? watts(metrics.inputWatts)
        }
        guard let power = metrics.batteryWatts else { return "-- W" }
        if power < -0.05 { return String(format: "−%.1f W", abs(power)) }
        if power > 0.05 { return String(format: "+%.1f W", power) }
        return "0.0 W"
    }

    private var batteryStatus: String {
        let level = metrics.batteryPercent.map { "\($0)%" } ?? "--%"
        guard let power = metrics.batteryWatts else { return "电池 \(level) · 功率未识别" }
        if power > 0.05 { return String(format: "电池 %@ · 充电 +%.1f W", level, power) }
        if power < -0.05 { return String(format: "电池 %@ · 放电 −%.1f W", level, abs(power)) }
        return "电池 \(level) · 保持 0.0 W"
    }

    private var batteryFlowValue: String {
        guard let power = metrics.batteryWatts else { return "--" }
        if power > 0.05 { return String(format: "+%.1f W", power) }
        if power < -0.05 { return String(format: "−%.1f W", abs(power)) }
        return "0.0 W"
    }

    private var batteryFlowStatus: String {
        guard let power = metrics.batteryWatts else { return "--" }
        if power > 0.05 { return "充电中" }
        if power < -0.05 { return "放电中" }
        return "保持"
    }

    private var batteryColor: NSColor {
        guard let power = metrics.batteryWatts else { return .secondaryLabelColor }
        if power > 0.05 { return .systemGreen }
        if power < -0.05 { return .systemOrange }
        return .secondaryLabelColor
    }

    private var chargeLimitPercent: Int? {
        guard metrics.externalPower,
              let percent = metrics.batteryPercent,
              percent < 100,
              let power = metrics.batteryWatts,
              abs(power) < 5 else { return nil }
        return percent
    }

    private var protectionValue: String {
        if let limit = chargeLimitPercent { return "\(limit)%" }
        return metrics.adapterLimitWatts.map { "≤\(Int($0.rounded()))W" } ?? "--"
    }

    private var protectionSub: String {
        chargeLimitPercent != nil ? "保持阈值" : "充电上限"
    }

    private var temperatureValue: String {
        metrics.batteryTemperature.map { String(format: "%.1f°C", $0) } ?? "--°C"
    }

    private var footerText: String {
        let adapter = metrics.adapterLimitWatts.map { String(format: "充电器上限 %.0f W · ", $0) } ?? ""
        return "\(adapter)数据每秒刷新"
    }

    private func drawStatusCards() {
        let cardWidth: CGFloat = 120
        let gap: CGFloat = 8
        let cardHeight: CGFloat = 44
        let y: CGFloat = 48
        let cards: [(icon: String, title: String, value: String, sub: String, color: NSColor)] = [
            ("thermometer.medium", "散热", temperatureValue, "电池温度", .systemOrange),
            ("shield.lefthalf.filled", "电池保护", protectionValue, protectionSub, .systemYellow),
            ("bolt.fill", "整机功耗", watts(metrics.systemWatts ?? metrics.sourceWatts), "系统负载", .systemTeal)
        ]
        for (index, card) in cards.enumerated() {
            let x = 8 + CGFloat(index) * (cardWidth + gap)
            drawStatusCard(
                x: x,
                y: y,
                width: cardWidth,
                height: cardHeight,
                icon: card.icon,
                title: card.title,
                value: card.value,
                sub: card.sub,
                color: card.color
            )
        }
    }

    private func drawStatusCard(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        icon: String,
        title: String,
        value: String,
        sub: String,
        color: NSColor
    ) {
        let rect = NSRect(x: x, y: y, width: width, height: height)
        if let image = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
            image.withSymbolConfiguration(configuration)?
                .draw(in: NSRect(x: rect.minX, y: rect.maxY - 14, width: 11, height: 11))
        }
        drawText(
            title,
            in: NSRect(x: rect.minX + 15, y: rect.maxY - 16, width: 52, height: 13),
            font: .systemFont(ofSize: 8.5, weight: .medium),
            color: .secondaryLabelColor
        )
        drawText(
            sub,
            in: NSRect(x: rect.minX + 15, y: rect.maxY - 30, width: 60, height: 11),
            font: .systemFont(ofSize: 7.5, weight: .medium),
            color: .tertiaryLabelColor
        )
        drawText(
            value,
            in: NSRect(x: rect.minX, y: rect.minY + 2, width: rect.width - 10, height: 19),
            font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .bold),
            color: .labelColor,
            alignment: .left
        )
    }

    private func deviceSymbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("ipad") { return "ipad" }
        if lower.contains("iphone") { return "iphone" }
        if lower.contains("display") || lower.contains("monitor") || lower.contains("显示器") { return "display" }
        if lower.contains("watch") { return "applewatch" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("hub") || lower.contains("dock") { return "cable.connector" }
        return "externaldrive.fill"
    }

    private func drawFlow(
        from start: NSPoint,
        to end: NSPoint,
        color: NSColor,
        power: Double?,
        reversed: Bool = false,
        label: String? = nil,
        arc: CGFloat = 24
    ) {
        let controls = flowControls(from: start, to: end, arc: arc)
        let path = NSBezierPath()
        path.move(to: start)
        path.curve(
            to: end,
            controlPoint1: controls.0,
            controlPoint2: controls.1
        )
        guard let power, power > 0.05 else {
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.setLineDash([3, 7], count: 2, phase: 0)
            NSColor.secondaryLabelColor.withAlphaComponent(0.22).setStroke()
            path.stroke()
            if let label {
                drawFlowLabel(label, from: start, to: end, color: color, arc: arc)
            }
            return
        }
        let bandWidth = min(34, max(4, 3.5 + CGFloat(power) * 0.38))
        if style == .minimal {
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            color.withAlphaComponent(0.75).setStroke()
            path.stroke()
            drawTrickles(
                from: start,
                to: end,
                arc: arc,
                bandWidth: 3,
                power: power,
                reversed: reversed
            )
        } else if style == .neon {
            path.lineWidth = bandWidth + 18
            path.lineCapStyle = .round
            color.withAlphaComponent(0.16).setStroke()
            path.stroke()
            path.lineWidth = bandWidth + 9
            color.withAlphaComponent(0.38).setStroke()
            path.stroke()
            let core = path.copy() as! NSBezierPath
            core.lineWidth = bandWidth
            core.lineCapStyle = .round
            color.withAlphaComponent(0.95).setStroke()
            core.stroke()
            drawTrickles(
                from: start,
                to: end,
                arc: arc,
                bandWidth: bandWidth,
                power: power,
                reversed: reversed
            )
        } else {
            // Soft outer halo + solid saturated ribbon (AlDente look)
            path.lineWidth = bandWidth + 9
            path.lineCapStyle = .round
            color.withAlphaComponent(0.22).setStroke()
            path.stroke()

            let core = path.copy() as! NSBezierPath
            core.lineWidth = bandWidth
            core.lineCapStyle = .round
            color.withAlphaComponent(0.92).setStroke()
            core.stroke()

            let edge = path.copy() as! NSBezierPath
            edge.lineWidth = max(1.2, bandWidth * 0.10)
            edge.lineCapStyle = .round
            color.withAlphaComponent(0.35).setStroke()
            edge.stroke()

            drawTrickles(
                from: start,
                to: end,
                arc: arc,
                bandWidth: bandWidth,
                power: power,
                reversed: reversed
            )
        }

        if let label {
            drawFlowLabel(label, from: start, to: end, color: color, arc: arc)
        }
    }

    private func drawTrickles(
        from start: NSPoint,
        to end: NSPoint,
        arc: CGFloat,
        bandWidth: CGFloat,
        power: Double,
        reversed: Bool
    ) {
        let direction: CGFloat = reversed ? -1 : 1
        let count = max(3, min(6, Int(power / 12) + 3))
        let step = 1.0 / CGFloat(count)
        let radius = max(2.0, bandWidth * 0.14)
        let speed = Self.flowSpeed(for: power)
        let offset = (flowPhase * 0.008 * speed * direction)
        for i in 0..<count {
            var t = (CGFloat(i) * step + offset).truncatingRemainder(dividingBy: 1)
            if t < 0 { t += 1 }
            let p = bezierMidpoint(from: start, to: end, t: t, arc: arc)
            let glow = NSBezierPath(ovalIn: NSRect(x: p.x - radius * 1.8, y: p.y - radius * 1.8, width: radius * 3.6, height: radius * 3.6))
            NSColor.white.withAlphaComponent(0.28).setFill()
            glow.fill()
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            NSColor.white.withAlphaComponent(0.85).setFill()
            dot.fill()
        }
    }

    private func drawFlowLabel(_ text: String, from start: NSPoint, to end: NSPoint, color: NSColor, arc: CGFloat) {
        let point = bezierMidpoint(from: start, to: end, t: 0.5, arc: arc)
        let width: CGFloat = text.count > 6 ? 62 : 56
        drawText(
            text,
            in: NSRect(x: point.x - width / 2, y: point.y - 8, width: width, height: 16),
            font: .monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            color: .labelColor,
            alignment: .center
        )
    }

    private func flowControls(from start: NSPoint, to end: NSPoint, arc: CGFloat) -> (NSPoint, NSPoint) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        if abs(dx) >= abs(dy) {
            let horizontal = min(46, max(24, abs(dx) * 0.45))
            let direction: CGFloat = dx >= 0 ? 1 : -1
            let bow: CGFloat = -abs(arc)
            return (
                NSPoint(x: start.x + horizontal * direction, y: start.y + bow),
                NSPoint(x: end.x - horizontal * direction, y: end.y + bow)
            )
        }
        return (
            NSPoint(x: start.x + arc, y: start.y),
            NSPoint(x: end.x - arc, y: end.y)
        )
    }

    private func bezierMidpoint(from start: NSPoint, to end: NSPoint, t: CGFloat, arc: CGFloat) -> NSPoint {
        let controls = flowControls(from: start, to: end, arc: arc)
        let u = 1 - t
        let x = u * u * u * start.x + 3 * u * u * t * controls.0.x + 3 * u * t * t * controls.1.x + t * t * t * end.x
        let y = u * u * u * start.y + 3 * u * u * t * controls.0.y + 3 * u * t * t * controls.1.y + t * t * t * end.y
        return NSPoint(x: x, y: y)
    }

    private func drawIconNode(
        center: NSPoint,
        icon: String,
        color: NSColor,
        primary: String? = nil,
        secondary: String? = nil
    ) {
        if style == .capsule {
            drawCapsuleNode(center: center, icon: icon, color: color, primary: primary, secondary: secondary)
            return
        }
        if style == .minimal {
            let size: CGFloat = 14
            if let image = symbolImage(icon, pointSize: 11, color: .secondaryLabelColor) {
                image.draw(in: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
            }
            if let primary {
                drawText(
                    primary,
                    in: NSRect(x: center.x - 60, y: center.y - 22, width: 120, height: 15),
                    font: .monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                    color: .labelColor,
                    alignment: .center
                )
            }
            if let secondary {
                drawText(
                    secondary,
                    in: NSRect(x: center.x - 60, y: center.y - 37, width: 120, height: 12),
                    font: .systemFont(ofSize: 8, weight: .regular),
                    color: .secondaryLabelColor,
                    alignment: .center
                )
            }
            return
        }
        let size: CGFloat = 18
        if let image = symbolImage(icon, pointSize: 14, color: color) {
            image.draw(in: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
        }
        if let primary {
            drawText(
                primary,
                in: NSRect(x: center.x - 60, y: center.y - 24, width: 120, height: 14),
                font: .monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                color: .labelColor,
                alignment: .center
            )
        }
        if let secondary {
            drawText(
                secondary,
                in: NSRect(x: center.x - 60, y: center.y - 39, width: 120, height: 12),
                font: .systemFont(ofSize: 8.5, weight: .medium),
                color: .secondaryLabelColor,
                alignment: .center
            )
        }
    }

    private func drawCapsuleNode(
        center: NSPoint,
        icon: String,
        color: NSColor,
        primary: String?,
        secondary: String?
    ) {
        let capsuleWidth: CGFloat = primary == nil ? 44 : 74
        let capsuleHeight: CGFloat = 26
        let rect = NSRect(x: center.x - capsuleWidth / 2, y: center.y - capsuleHeight / 2, width: capsuleWidth, height: capsuleHeight)
        let path = NSBezierPath(roundedRect: rect, xRadius: capsuleHeight / 2, yRadius: capsuleHeight / 2)
        color.withAlphaComponent(0.92).setFill()
        path.fill()
        color.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 0.7
        path.stroke()

        if let primary {
            if let image = symbolImage(icon, pointSize: 11, color: .white) {
                image.draw(in: NSRect(x: rect.minX + 9, y: center.y - 6, width: 12, height: 12))
            }
            drawText(
                primary,
                in: NSRect(x: rect.minX + 24, y: center.y - 8, width: rect.width - 28, height: 16),
                font: .monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                color: .white,
                alignment: .left
            )
        } else {
            if let image = symbolImage(icon, pointSize: 13, color: .white) {
                image.draw(in: NSRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
            }
        }
        if let secondary {
            drawText(
                secondary,
                in: NSRect(x: center.x - 60, y: center.y - capsuleHeight / 2 - 17, width: 120, height: 12),
                font: .systemFont(ofSize: 8.5, weight: .medium),
                color: .secondaryLabelColor,
                alignment: .center
            )
        }
    }

    private func symbolImage(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return image.withSymbolConfiguration(configuration)
    }

    private func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-- W" }
        return value >= 100 ? String(format: "%.0f W", value) : String(format: "%.1f W", value)
    }

    private func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--%" }
        return String(format: "%.0f%%", value)
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }
}
