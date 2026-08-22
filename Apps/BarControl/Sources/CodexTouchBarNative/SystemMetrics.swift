import AppKit
import Darwin
import IOKit

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
        inputWatts: 61.2,
        inputVoltage: 20,
        inputCurrent: 3.06,
        systemWatts: 23.7,
        batteryWatts: 37.5,
        batteryPercent: 47,
        batteryTemperature: 33.7,
        memoryPercent: 61,
        gpuPercent: 28,
        usbOutputs: [
            USBPowerFlow(portIndex: 1, name: "iPad", watts: 10.7, voltage: 5.1, current: 2.1),
            USBPowerFlow(portIndex: 2, name: "USB-C 显示器", watts: 3.83, voltage: 5.0, current: 0.77)
        ]
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
            )
        )
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
final class PowerFlowView: NSView {
    var metrics = SystemMetrics.unavailable {
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
        drawDetailsPanel()
        drawText(
            footerText,
            in: NSRect(x: 16, y: 4, width: 358, height: 12),
            font: .systemFont(ofSize: 8.5, weight: .regular),
            color: .tertiaryLabelColor,
            alignment: .center
        )
    }

    private func drawPowerTopology() {
        let source = NSRect(x: 12, y: 160, width: 78, height: 118)
        let system = NSRect(x: 151, y: 182, width: 84, height: 72)
        let battery = NSRect(x: 284, y: 278, width: 94, height: 48)
        drawNode(source, color: sourceColor, title: sourceNodeTitle, value: sourceNodeValue)
        drawFlow(
            from: NSPoint(x: source.maxX, y: 219),
            to: NSPoint(x: system.minX, y: 218),
            color: metrics.externalPower ? .systemYellow : .systemGreen,
            power: metrics.inputWatts ?? metrics.sourceWatts
        )
        drawFlowLabel(watts(metrics.inputWatts ?? metrics.sourceWatts), x: 92, y: 228)
        drawNode(system, color: .systemBlue, title: "Mac 整机", value: watts(metrics.systemWatts))

        let batteryPower = metrics.batteryWatts ?? 0
        let batteryReversed = batteryPower < -0.05
        let batteryColor: NSColor = batteryReversed ? .systemOrange : .systemGreen
        if metrics.externalPower {
            drawFlow(
                from: NSPoint(x: system.maxX, y: 236),
                to: NSPoint(x: battery.minX, y: 302),
                color: batteryColor,
                power: abs(batteryPower),
                reversed: batteryReversed
            )
            drawNode(
                battery,
                color: batteryColor,
                title: metrics.batteryPercent.map { "电池 \($0)%" } ?? "电池",
                value: batteryFlowStatus
            )
        }

        let outputs = Array(metrics.usbOutputs.prefix(3))
        let yPositions: [CGFloat] = outputs.count == 1 ? [184] : (outputs.count == 2 ? [206, 150] : [214, 164, 116])
        for (index, output) in outputs.enumerated() {
            let rect = NSRect(x: 284, y: yPositions[index], width: 94, height: 42)
            drawFlow(
                from: NSPoint(x: system.maxX, y: system.midY - CGFloat(index) * 8),
                to: NSPoint(x: rect.minX, y: rect.midY),
                color: .systemTeal,
                power: output.watts
            )
            drawNode(rect, color: .systemTeal, title: output.name, value: watts(output.watts))
        }
    }

    private var sourceColor: NSColor {
        metrics.externalPower ? .systemYellow : .systemGreen
    }

    private var totalUSBOutput: Double? {
        let total = metrics.usbOutputs.reduce(0) { $0 + $1.watts }
        return total > 0.05 ? total : nil
    }

    private var sourceNodeTitle: String {
        if metrics.externalPower { return "充电器" }
        return metrics.batteryPercent.map { "电池 \($0)%" } ?? "电池供电"
    }

    private var sourceNodeValue: String {
        guard !metrics.externalPower else { return watts(metrics.inputWatts ?? metrics.sourceWatts) }
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

    private var batteryFlowStatus: String {
        guard let power = metrics.batteryWatts else { return "--" }
        if power > 0.05 { return String(format: "+%.1fW 充电", power) }
        if power < -0.05 { return String(format: "−%.1fW 放电", abs(power)) }
        return "0.0W 保持"
    }

    private var batteryColor: NSColor {
        guard let power = metrics.batteryWatts else { return .secondaryLabelColor }
        if power > 0.05 { return .systemGreen }
        if power < -0.05 { return .systemOrange }
        return .secondaryLabelColor
    }

    private var batteryPowerDetail: String {
        guard let power = metrics.batteryWatts else { return "未识别" }
        if power > 0.05 { return String(format: "充电 +%.1f W", power) }
        if power < -0.05 { return String(format: "放电 −%.1f W", abs(power)) }
        return "保持 0.0 W"
    }

    private var footerText: String {
        let adapter = metrics.adapterLimitWatts.map { String(format: "充电器上限 %.0f W · ", $0) } ?? ""
        return "\(adapter)数据每秒刷新"
    }

    private func drawDetailsPanel() {
        NSColor.separatorColor.withAlphaComponent(0.32).setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: 14, y: 102))
        separator.line(to: NSPoint(x: 376, y: 102))
        separator.lineWidth = 0.6
        separator.stroke()
        let temperature = metrics.batteryTemperature.map { String(format: "%.1f°C", $0) } ?? "--°C"
        let memoryGPU = "\(percent(metrics.memoryPercent)) / \(percent(metrics.gpuPercent))"
        drawDetail(label: metrics.externalPower ? "充电器输入" : "电池供电", value: watts(metrics.inputWatts ?? metrics.sourceWatts), x: 14, y: 78)
        drawDetail(label: "整机负载", value: watts(metrics.systemWatts ?? metrics.sourceWatts), x: 14, y: 50)
        drawDetail(label: "电池功率", value: batteryPowerDetail, x: 14, y: 22)

        var rightY: CGFloat = 78
        if let totalUSBOutput {
            drawDetail(label: "USB-C 输出", value: watts(totalUSBOutput), x: 205, y: rightY)
            rightY -= 28
        }
        drawDetail(label: "电池温度", value: temperature, x: 205, y: rightY)
        rightY -= 28
        drawDetail(label: "内存 / GPU", value: memoryGPU, x: 205, y: rightY)
    }

    private func drawDetail(label: String, value: String, x: CGFloat, y: CGFloat) {
        drawText(label, in: NSRect(x: x, y: y, width: 68, height: 14), font: .systemFont(ofSize: 8.5, weight: .medium), color: .secondaryLabelColor)
        drawText(value, in: NSRect(x: x + 66, y: y - 1, width: 98, height: 16), font: .monospacedDigitSystemFont(ofSize: 10, weight: .semibold), color: .labelColor, alignment: .right)
    }

    private func drawFlowLabel(_ text: String, x: CGFloat, y: CGFloat) {
        let rect = NSRect(x: x, y: y, width: 58, height: 18)
        NSColor.controlBackgroundColor.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        drawText(text, in: NSRect(x: x + 4, y: y + 2, width: 50, height: 14), font: .monospacedDigitSystemFont(ofSize: 9, weight: .semibold), color: .labelColor, alignment: .center)
    }

    private func drawFlow(
        from start: NSPoint,
        to end: NSPoint,
        color: NSColor,
        power: Double?,
        reversed: Bool = false
    ) {
        let path = NSBezierPath()
        path.move(to: start)
        path.curve(
            to: end,
            controlPoint1: NSPoint(x: start.x + 58, y: start.y),
            controlPoint2: NSPoint(x: end.x - 58, y: end.y)
        )
        guard let power, power > 0.05 else {
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.setLineDash([3, 7], count: 2, phase: 0)
            NSColor.secondaryLabelColor.withAlphaComponent(0.22).setStroke()
            path.stroke()
            return
        }
        path.lineWidth = 13
        path.lineCapStyle = .round
        color.withAlphaComponent(0.18).setStroke()
        path.stroke()

        let direction: CGFloat = reversed ? -1 : 1
        let phase = Self.dashPhase(for: power, frame: flowPhase, reversed: reversed)
        let stream = path.copy() as! NSBezierPath
        stream.lineWidth = min(6, 2.6 + CGFloat(sqrt(power)) * 0.38)
        stream.lineCapStyle = .round
        stream.setLineDash([15, 10], count: 2, phase: phase)
        color.withAlphaComponent(0.92).setStroke()
        stream.stroke()
        let glint = path.copy() as! NSBezierPath
        glint.lineWidth = 1.4
        glint.lineCapStyle = .round
        glint.setLineDash([3, 22], count: 2, phase: phase + 6 * direction)
        NSColor.labelColor.withAlphaComponent(0.72).setStroke()
        glint.stroke()
    }

    private func drawNode(_ rect: NSRect, color: NSColor, title: String, value: String) {
        color.withAlphaComponent(0.14).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        path.fill()
        drawText(
            title,
            in: NSRect(x: rect.minX + 7, y: rect.midY + 4, width: rect.width - 14, height: 17),
            font: .systemFont(ofSize: 10, weight: .medium),
            color: .secondaryLabelColor,
            alignment: .center
        )
        drawText(
            value,
            in: NSRect(x: rect.minX + 5, y: rect.midY - 18, width: rect.width - 10, height: 21),
            font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .bold),
            color: .labelColor,
            alignment: .center
        )
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
