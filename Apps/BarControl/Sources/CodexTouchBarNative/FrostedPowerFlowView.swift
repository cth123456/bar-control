import AppKit
import CoreText
import QuartzCore

enum FlowAnimationStyle: String, CaseIterable {
    case softTide = "soft-tide"
    case liquidDrops = "liquid-drops"
    case auroraPulse = "aurora-pulse"
    case silkRibbon = "silk-ribbon"
}

/// Menu-sized composition that keeps the approved flow geometry intact and
/// adds a synchronized accounting strip underneath it.
@MainActor
final class PowerFlowPanelView: NSView {
    private enum Layout {
        static let footerHeight: CGFloat = 88
        static let horizontalInset: CGFloat = 8.5
        static let chipGap: CGFloat = 8
        static let chipHeight: CGFloat = 26
        static let primaryChipBottom: CGFloat = 57
        static let temperatureChipBottom: CGFloat = 27
        static let captionBottom: CGFloat = 5
    }

    let flowView = FrostedPowerFlowView()
    private let localChip = PowerMetricChipView(accent: .systemBlue)
    private let externalChip = PowerMetricChipView(accent: .systemOrange)
    private let fanChip = PowerMetricChipView(
        accent: .systemPurple,
        symbolName: "fan.fill",
        symbolAccessibilityDescription: "风扇"
    )
    private let batteryTemperatureChip = PowerMetricChipView(
        accent: .systemGreen,
        symbolName: "battery.100percent",
        symbolAccessibilityDescription: "电池温度"
    )
    private let gpuTemperatureChip = PowerMetricChipView(
        accent: .systemPink,
        symbolName: "thermometer.high",
        symbolAccessibilityDescription: "GPU 温度"
    )
    private let sourceLabel = NSTextField(labelWithString: "")
    private let negotiationLabel = NSTextField(labelWithString: "USB-C 自动协商")

    var metrics = SystemMetrics.unavailable {
        didSet {
            flowView.metrics = metrics
            updateSummary()
            updateLayoutSize()
        }
    }

    var isAnimating: Bool { flowView.isAnimating }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        sourceLabel.font = .systemFont(ofSize: 10, weight: .medium)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.lineBreakMode = .byClipping
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        negotiationLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        negotiationLabel.textColor = .secondaryLabelColor
        negotiationLabel.alignment = .right
        negotiationLabel.lineBreakMode = .byClipping

        addSubview(flowView)
        addSubview(localChip)
        addSubview(externalChip)
        addSubview(fanChip)
        addSubview(batteryTemperatureChip)
        addSubview(gpuTemperatureChip)
        addSubview(sourceLabel)
        addSubview(negotiationLabel)
        updateSummary()
        updateLayoutSize()

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("功率分配摘要")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: flowView.intrinsicContentSize.width,
            height: flowView.intrinsicContentSize.height + Layout.footerHeight
        )
    }

    override func layout() {
        super.layout()
        flowView.frame = NSRect(
            x: 0,
            y: Layout.footerHeight,
            width: bounds.width,
            height: max(0, bounds.height - Layout.footerHeight)
        )
        let availableWidth = bounds.width - Layout.horizontalInset * 2 - Layout.chipGap * 2
        let chipWidth = floor(availableWidth / 3)
        localChip.frame = NSRect(
            x: Layout.horizontalInset,
            y: Layout.primaryChipBottom,
            width: chipWidth,
            height: Layout.chipHeight
        )
        externalChip.frame = NSRect(
            x: localChip.frame.maxX + Layout.chipGap,
            y: Layout.primaryChipBottom,
            width: chipWidth,
            height: Layout.chipHeight
        )
        fanChip.frame = NSRect(
            x: externalChip.frame.maxX + Layout.chipGap,
            y: Layout.primaryChipBottom,
            width: bounds.width - Layout.horizontalInset - externalChip.frame.maxX - Layout.chipGap,
            height: Layout.chipHeight
        )
        let temperatureWidth = floor(
            (bounds.width - Layout.horizontalInset * 2 - Layout.chipGap) / 2
        )
        batteryTemperatureChip.frame = NSRect(
            x: Layout.horizontalInset,
            y: Layout.temperatureChipBottom,
            width: temperatureWidth,
            height: Layout.chipHeight
        )
        gpuTemperatureChip.frame = NSRect(
            x: batteryTemperatureChip.frame.maxX + Layout.chipGap,
            y: Layout.temperatureChipBottom,
            width: bounds.width - Layout.horizontalInset - batteryTemperatureChip.frame.maxX - Layout.chipGap,
            height: Layout.chipHeight
        )
        sourceLabel.frame = NSRect(
            x: Layout.horizontalInset + 3,
            y: Layout.captionBottom,
            width: 244,
            height: 16
        )
        negotiationLabel.frame = NSRect(
            x: 252,
            y: Layout.captionBottom,
            width: max(0, bounds.width - 252 - Layout.horizontalInset - 2),
            height: 16
        )
    }

    func startAnimating() {
        flowView.startAnimating()
    }

    func stopAnimating() {
        flowView.stopAnimating()
    }

    func setAnimationFrameForPreview(_ frame: Int) {
        flowView.setAnimationFrameForPreview(frame)
    }

    func setAnimationStyleForPreview(_ style: FlowAnimationStyle) {
        flowView.animationStyle = style
    }

    private func updateLayoutSize() {
        let size = intrinsicContentSize
        if frame.size != size {
            setFrameSize(size)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func updateSummary() {
        localChip.title = "本机实际"
        localChip.value = Self.watts(metrics.localComputerWatts)
        externalChip.title = "外接设备"
        externalChip.value = Self.watts(metrics.externalOutputWatts)
        let fanSummary = Self.fanSummary(metrics.fanRPMs)
        fanChip.title = fanSummary.state
        fanChip.value = fanSummary.value
        batteryTemperatureChip.title = "电池"
        batteryTemperatureChip.value = Self.temperature(metrics.batteryTemperature)
        gpuTemperatureChip.title = "GPU"
        gpuTemperatureChip.value = Self.temperature(metrics.gpuTemperature)
        sourceLabel.stringValue = sourceDescription
        negotiationLabel.stringValue = "USB-C 自动协商"
        setAccessibilityValue(
            "本机实际 \(localChip.value)，外接设备 \(externalChip.value)，风扇\(fanSummary.accessibility)，电池温度 \(batteryTemperatureChip.value)，GPU 温度 \(gpuTemperatureChip.value)，\(sourceDescription)，USB-C 自动协商"
        )
    }

    private var sourceDescription: String {
        let charger = metrics.inputWatts.flatMap { value -> Double? in
            value.isFinite && value > 0.05 ? value : nil
        }
        if metrics.batterySupplyWatts > 0.05 {
            if let charger {
                return "来源  充电器 \(Self.watts(charger)) + 电池 \(Self.watts(metrics.batterySupplyWatts))"
            }
            return "来源  电池 \(Self.watts(metrics.batterySupplyWatts))"
        }
        if metrics.batteryChargeWatts > 0.05, let charger {
            return "来源  充电器 \(Self.watts(charger)) · 电池充电 \(Self.watts(metrics.batteryChargeWatts))"
        }
        if let charger {
            return "来源  充电器 \(Self.watts(charger))"
        }
        return "来源  --"
    }

    private static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-- W" }
        return String(format: "%.1f W", max(0, value))
    }

    private static func temperature(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 10, value < 150 else { return "--°C" }
        return String(format: "%.1f°C", value)
    }

    private static func fanSummary(
        _ rpms: [Double]
    ) -> (state: String, value: String, accessibility: String) {
        let values = rpms.filter { $0.isFinite && $0 >= 0 }
        guard let maximum = values.max() else {
            return ("无数据", "--", "状态不可用")
        }
        let rounded = Int(maximum.rounded())
        if rounded < 50 {
            return ("停转", "0 RPM", "停转，0 RPM")
        }
        let fanCount = values.count
        let countText = fanCount > 1 ? "，\(fanCount) 个风扇" : ""
        return ("运行", "\(rounded) RPM", "运行，\(rounded) RPM\(countText)")
    }
}

@MainActor
private final class PowerMetricChipView: NSVisualEffectView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let symbolView = NSImageView()
    private let accent: NSColor
    private let symbolName: String?

    var title = "" {
        didSet { titleLabel.stringValue = title }
    }
    var value = "-- W" {
        didSet { valueLabel.stringValue = value }
    }

    init(
        accent: NSColor,
        symbolName: String? = nil,
        symbolAccessibilityDescription: String = "状态"
    ) {
        self.accent = accent
        self.symbolName = symbolName
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.6
        layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor

        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byClipping
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        valueLabel.textColor = accent
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byClipping
        if let symbolName {
            symbolView.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: symbolAccessibilityDescription
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            )
            symbolView.contentTintColor = accent
            symbolView.imageScaling = .scaleProportionallyDown
            addSubview(symbolView)
        }
        addSubview(titleLabel)
        addSubview(valueLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let hasSymbol = symbolName != nil
        symbolView.frame = hasSymbol
            ? NSRect(x: 8, y: 7, width: 12, height: 12)
            : .zero
        let titleX: CGFloat = hasSymbol ? 24 : 9
        let desiredTitleWidth = ceil(titleLabel.intrinsicContentSize.width)
        let titleWidth = min(hasSymbol ? 32 : 54, max(20, desiredTitleWidth))
        titleLabel.frame = NSRect(x: titleX, y: 5, width: titleWidth, height: 16)
        let valueX = titleLabel.frame.maxX + 5
        valueLabel.frame = NSRect(
            x: valueX,
            y: 4,
            width: max(0, bounds.width - valueX - 8),
            height: 17
        )
        layer?.borderColor = NSColor.white.withAlphaComponent(
            effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.18 : 0.56
        ).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.20 : 0.12
        layer?.shadowRadius = 5
        layer?.shadowOffset = NSSize(width: 0, height: -1)
    }
}

/// The compact, data-driven power-flow graph shown at the top of the menu.
///
/// This view intentionally owns no telemetry or device-discovery logic. It only
/// renders the current `SystemMetrics` snapshot supplied by the controller.
@MainActor
final class FrostedPowerFlowView: NSView {
    /// Structure variants for the same data-driven renderer. These let the
    /// design be compared end-to-end with the reference before committing.
    struct Structure {
        let size: NSSize
        let source: NSRect
        let batteryCard: NSRect
        let laptopCard: NSRect
        let outputX: CGFloat
        let outputWidth: CGFloat
        let outputHeight: CGFloat
        var batteryCenterY: CGFloat { batteryCard.midY }
        var systemCenterY: CGFloat { laptopCard.midY }

        static let reference = Structure(
            size: NSSize(width: 390, height: 206),
            source: NSRect(x: 8.5, y: 52.3, width: 44.1, height: 124.9),
            batteryCard: NSRect(x: 172.3, y: 101.3, width: 44.1, height: 89.8),
            laptopCard: NSRect(x: 172.3, y: 38.1, width: 44.1, height: 35.1),
            outputX: 336.4, outputWidth: 44.1, outputHeight: 16
        )

        static let bold = Structure(
            size: NSSize(width: 390, height: 206),
            source: NSRect(x: 8.5, y: 52.3, width: 44.1, height: 124.9),
            batteryCard: NSRect(x: 172.3, y: 101.3, width: 44.1, height: 89.8),
            laptopCard: NSRect(x: 172.3, y: 38.1, width: 44.1, height: 35.1),
            outputX: 336.4, outputWidth: 44.1, outputHeight: 16
        )
    }

    private enum Design {
        static let expandedCanvas = NSSize(width: 1290, height: 681)
        static let compactCanvas = NSSize(width: 1290, height: 563)
        static let compactViewSize = NSSize(
            width: Structure.reference.size.width,
            height: Structure.reference.size.width * compactCanvas.height / compactCanvas.width
        )
        static let referenceBatteryWatts = 61.2
        static let referenceSystemWatts = 23.7
        static let sourceAttachmentCenterY: CGFloat = 301.5
        static let sourceAttachmentHeight: CGFloat = 456
        static let minimumBranchThickness: CGFloat = 32
        static let minimumEndpointCardHeight: CGFloat = 96
        static let standardEndpointCardHeight: CGFloat = 132
        static let minimumEndpointIconSize: CGFloat = 64
        static let minimumInputCardHeight: CGFloat = 132
        static let minimumSecondLevelIconSize: CGFloat = 72
        static let maximumSystemCardHeight: CGFloat = 360
        static let endpointModuleGap: CGFloat = 64
        static let outputRootGap: CGFloat = 17
        static let flowCornerRadius: CGFloat = 24
        static let moduleCornerRadius: CGFloat = 22
        static let compactModuleCornerRadius: CGFloat = 24
    }

    private enum OutputSlot: Int, CaseIterable {
        case top
        case middle
        case bottom
    }

    private struct OutputRibbonLayout {
        let output: USBPowerFlow
        let slot: OutputSlot
        let usesMainFlowStyle: Bool
        let cardRect: NSRect
        let start: NSPoint
        let end: NSPoint
        let startWidth: CGFloat
        let endWidth: CGFloat
        let path: NSBezierPath
    }

    private enum InputBranchKind {
        case battery
        case charger
    }

    private struct InputRibbonLayout {
        let kind: InputBranchKind
        let watts: Double
        let cardRect: NSRect
        let start: NSPoint
        let end: NSPoint
        let startWidth: CGFloat
        let endWidth: CGFloat
        let path: NSBezierPath
    }

    private enum MainBranchKind {
        case battery
        case system
    }

    private struct MainRibbonLayout {
        let kind: MainBranchKind
        let watts: Double
        let cardRect: NSRect
        let start: NSPoint
        let end: NSPoint
        let startWidth: CGFloat
        let endWidth: CGFloat
        let path: NSBezierPath
    }

    var structure = Structure.reference {
        didSet {
            updateLayoutSize()
            needsDisplay = true
        }
    }

    private static let outputThresholdWatts = 0.05
    private static let chargingThresholdWatts = 0.25

    var metrics = SystemMetrics.unavailable {
        didSet {
            updateLayoutSize()
            updateAccessibilitySummary()
            needsDisplay = true
        }
    }

    var animationStyle = FlowAnimationStyle.auroraPulse {
        didSet { needsDisplay = true }
    }

    private(set) var isAnimating = false
    private(set) var animationFrame = 0
    private var animationTimer: Timer?
    private var animationEpoch = CACurrentMediaTime() - 0.85
    private var animationElapsed: TimeInterval = 0.85
    private var rendersPreviewAnimation = false

    init(
        width: CGFloat = Structure.reference.size.width,
        height: CGFloat = Structure.reference.size.height
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateLayoutSize()
        updateAccessibilitySummary()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    func startAnimating() {
        guard animationTimer == nil else { return }
        isAnimating = true
        rendersPreviewAnimation = false
        animationEpoch = CACurrentMediaTime() - animationElapsed
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.animationFrame += 1
                self.animationElapsed = CACurrentMediaTime() - self.animationEpoch
                self.needsDisplay = true
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopAnimating() {
        if animationTimer != nil {
            animationElapsed = CACurrentMediaTime() - animationEpoch
        }
        animationTimer?.invalidate()
        animationTimer = nil
        isAnimating = false
        rendersPreviewAnimation = false
    }

    func setAnimationFrameForPreview(_ frame: Int) {
        animationFrame = max(0, frame)
        animationElapsed = Double(animationFrame) / 30
        rendersPreviewAnimation = true
        needsDisplay = true
    }

    /// AlDente treats animation as direction, not another quantitative scale:
    /// watts control ribbon width while active ribbons share a calm sweep rate.
    static func flowDuration(for watts: Double) -> TimeInterval {
        guard watts.isFinite, watts > outputThresholdWatts else { return 0 }
        return 3.6
    }

    /// Power controls the cross-section while the small floor keeps a low-power
    /// accessory visible at this compact menu scale.
    static func ribbonWidth(for watts: Double) -> CGFloat {
        guard watts.isFinite, watts > outputThresholdWatts else { return 0 }
        let power = CGFloat(min(watts, 120))
        let width: CGFloat
        switch power {
        case ...4:
            width = 1.5 + power * 1.5
        case ...12:
            width = 7.5 + (power - 4) * 1.55
        case ...30:
            width = 19.9 + (power - 12) * 0.5
        default:
            width = 28.9 + (power - 30) * 0.4
        }
        return min(44, width)
    }

    /// Each ribbon gets its own short attachment slot at a node edge. Main
    /// branches keep a broad shoulder; fan-out branches begin slimmer so the
    /// slots can sit beside one another instead of stacking on the same pixels.
    static func ribbonStartWidth(for watts: Double, startsNarrow: Bool) -> CGFloat {
        let width = ribbonWidth(for: watts)
        guard width > 0 else { return 0 }
        return startsNarrow
            ? max(2.5, width * 0.60)
            : max(3, width)
    }

    /// Fan-out geometry is relative within one hierarchy level. The strongest
    /// active device owns the broadest branch, while weaker siblings taper
    /// non-linearly. The entire shared root is then fitted into the current
    /// whole-machine card edge, so adding/removing a sibling also changes the
    /// available cross-section instead of leaving a fixed three-slot stencil.
    static func outputBranchStartWidths(
        for watts: [Double],
        maximumTotalHeight: CGFloat = 116
    ) -> [CGFloat] {
        outputBranchWidths(
            for: watts,
            minimum: Design.minimumBranchThickness,
            exponent: 1.35,
            maximumTotalHeight: maximumTotalHeight
        )
    }

    static func outputBranchEndWidths(
        for watts: [Double],
        maximumTotalHeight: CGFloat = 116
    ) -> [CGFloat] {
        outputBranchWidths(
            for: watts,
            minimum: Design.minimumBranchThickness,
            exponent: 1.70,
            maximumTotalHeight: maximumTotalHeight
        )
    }

    private static func outputBranchWidths(
        for watts: [Double],
        minimum: CGFloat,
        exponent: CGFloat,
        maximumTotalHeight: CGFloat
    ) -> [CGFloat] {
        let powers = watts.map { CGFloat(max(0, $0.isFinite ? $0 : 0)) }
        guard let maximumPower = powers.max(), maximumPower > 0 else {
            return powers.map { _ in 0 }
        }
        // A sole child owns the complete outlet. Power ratios only have
        // meaning when this level has siblings competing for cross-section.
        if powers.count == 1 {
            return [max(1, maximumTotalHeight)]
        }
        let safeMinimum = min(
            minimum,
            maximumTotalHeight / CGFloat(max(1, powers.count))
        )
        let weights = powers.map { power -> CGFloat in
            guard power > 0 else { return 0 }
            let ratio = min(1, power / maximumPower)
            return pow(ratio, exponent)
        }
        let remaining = max(
            0,
            maximumTotalHeight - safeMinimum * CGFloat(powers.count)
        )
        let weightTotal = max(0.001, weights.reduce(0, +))
        return weights.map { safeMinimum + remaining * $0 / weightTotal }
    }

    static func endpointCardHeights(
        for watts: [Double],
        maximumHeight: CGFloat = 280
    ) -> [CGFloat] {
        let powers = watts.map { CGFloat(max(0, $0.isFinite ? $0 : 0)) }
        guard let maximumPower = powers.max(), maximumPower > 0 else {
            return powers.map { _ in Design.minimumEndpointCardHeight }
        }
        let minimum = Design.minimumEndpointCardHeight
        let largest = min(
            maximumHeight,
            max(minimum, minimum + maximumPower * 2.60)
        )
        return powers.map { power in
            guard power > 0 else { return minimum }
            let ratio = min(1, power / maximumPower)
            return minimum + (largest - minimum) * pow(ratio, 1.50)
        }
    }

    /// A single endpoint uses a normal component token instead of a percentage
    /// of the whole-Mac card. Multiple endpoints remain power-proportional but
    /// never request a card smaller than a normally readable device icon.
    static func preferredOutputCardHeights(for watts: [Double]) -> [CGFloat] {
        guard !watts.isEmpty else { return [] }
        if watts.count == 1 { return [Design.standardEndpointCardHeight] }
        return endpointCardHeights(for: watts)
    }

    /// Endpoint symbols share one normal-size floor in every device-count
    /// state. Card height may enlarge a symbol slightly, but siblings never
    /// switch to a smaller icon scale just because more endpoints are visible.
    static func endpointIconSize(forCardHeight height: CGFloat) -> CGFloat {
        min(72, max(Design.minimumEndpointIconSize, height * 0.48))
    }

    /// Battery and whole-Mac cards share one readable symbol scale. Branch
    /// allocation may resize the card, but it must never turn either device
    /// icon into a small dot.
    static func secondLevelIconSize(forCardHeight height: CGFloat) -> CGFloat {
        min(80, max(Design.minimumSecondLevelIconSize, height * 0.45))
    }

    /// Every third-level module carries an explicit, readable identity label.
    /// Color remains a secondary cue; it is never the only way to tell CPU,
    /// GPU, other hardware, displays, and accessories apart.
    static func endpointCaption(for name: String) -> String {
        let lower = name.lowercased()
        if lower == "cpu" { return "CPU" }
        if lower == "gpu" { return "GPU" }
        if lower.contains("其他硬件") { return "其他硬件" }
        if let separator = name.range(of: "进程 · ") {
            let raw = String(name[separator.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return "进程" }
            return raw.count > 7 ? String(raw.prefix(6)) + "…" : raw
        }
        if lower.contains("display") || lower.contains("monitor") || lower.contains("显示器") {
            return "显示器"
        }
        if lower.contains("ipad") { return "iPad" }
        if lower.contains("iphone") { return "iPhone" }
        if lower.contains("watch") { return "手表" }
        if lower.contains("airpods") || lower.contains("耳机") { return "耳机" }
        if lower.contains("hub") || lower.contains("dock") || lower.contains("扩展坞") {
            return "扩展坞"
        }
        if lower.contains("usb") { return "外接设备" }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "设备" }
        return trimmed.count > 7 ? String(trimmed.prefix(6)) + "…" : trimmed
    }

    /// The whole-Mac card expands when necessary so its outlet can contain the
    /// endpoint floor without compressing third-level modules into hairlines.
    static func requiredSystemCardHeight(for watts: [Double]) -> CGFloat {
        guard !watts.isEmpty else { return 0 }
        // A lone endpoint and the whole-Mac card use separate component
        // tokens. The 32-point host shoulder keeps the child visually
        // subordinate without deriving either size from a fixed percentage.
        if watts.count == 1 {
            return Design.standardEndpointCardHeight + 32
        }
        return min(
            Design.maximumSystemCardHeight,
            preferredOutputCardHeights(for: watts).reduce(0, +)
        )
    }

    /// Second-to-third-level ribbons use one constant cross-section from the
    /// whole-Mac outlet to the endpoint card. Preferred card sizes are kept
    /// when they fit; otherwise the group is compressed into the parent edge
    /// with the same non-hairline floor used by the fan-out allocator.
    static func equalizedOutputWidths(
        preferredHeights: [CGFloat],
        watts: [Double],
        maximumTotalHeight: CGFloat
    ) -> [CGFloat] {
        guard preferredHeights.count == watts.count, !watts.isEmpty else { return [] }
        if preferredHeights.count == 1 {
            return [min(maximumTotalHeight, max(1, preferredHeights[0]))]
        }
        // A sibling group owns the whole connected edge of the whole-Mac
        // card. Allocate that complete height even when preferred endpoint
        // sizes would leave an inset at the top or bottom.
        return outputBranchWidths(
            for: watts,
            minimum: Design.minimumEndpointCardHeight,
            exponent: 1.35,
            maximumTotalHeight: maximumTotalHeight
        )
    }

    static func secondLevelCardHeights(
        batteryWatts: Double,
        systemWatts: Double,
        minimumSystemHeight: CGFloat = 72
    ) -> (battery: CGFloat, system: CGFloat) {
        let battery = CGFloat(max(0, batteryWatts.isFinite ? batteryWatts : 0))
        let system = CGFloat(max(0, systemWatts.isFinite ? systemWatts : 0))
        let totalPower = max(0.1, battery + system)
        // A live but low-power battery branch must remain large enough to look
        // intentional and keep its icon readable. A true zero-watt branch is
        // removed by `showsBatteryBranch(for:)` instead of being squeezed into
        // this visual floor.
        let minimumBattery: CGFloat = 96
        let minimumSystem = min(
            Design.maximumSystemCardHeight,
            max(72, minimumSystemHeight)
        )
        // Both destination cards and both source slots share one exact
        // 456-point attachment budget. Apply visual floors first, then divide
        // only the remaining room by power so neither ribbon ever tapers.
        let remaining = max(
            0,
            Design.sourceAttachmentHeight - minimumBattery - minimumSystem
        )
        let batteryHeight = minimumBattery + remaining * battery / totalPower
        let systemHeight = minimumSystem + remaining * system / totalPower
        return (batteryHeight, systemHeight)
    }

    /// Allocate one hierarchy level as a single fixed visual budget. The
    /// readable floor is applied first, then the remaining height is shared by
    /// measured power. A sole item owns the whole level.
    static func linkedCardHeights(
        for watts: [Double],
        totalHeight: CGFloat,
        minimumHeight: CGFloat
    ) -> [CGFloat] {
        guard !watts.isEmpty else { return [] }
        if watts.count == 1 { return [totalHeight] }
        let powers = watts.map { CGFloat(max(0, $0.isFinite ? $0 : 0)) }
        let totalPower = powers.reduce(0, +)
        guard totalPower > 0 else {
            return Array(repeating: totalHeight / CGFloat(watts.count), count: watts.count)
        }
        let safeMinimum = min(minimumHeight, totalHeight / CGFloat(watts.count))
        var heights = powers.map { max(safeMinimum, totalHeight * $0 / totalPower) }
        var excess = heights.reduce(0, +) - totalHeight
        while excess > 0.001 {
            let flexible = heights.map { max(0, $0 - safeMinimum) }
            let flexibleTotal = flexible.reduce(0, +)
            guard flexibleTotal > 0.001 else { break }
            for index in heights.indices {
                heights[index] -= excess * flexible[index] / flexibleTotal
            }
            excess = heights.reduce(0, +) - totalHeight
        }
        return heights
    }

    static func mainCardHeight(for watts: Double) -> CGFloat {
        min(46, max(34, 34 + ribbonWidth(for: watts) * 0.28))
    }

    /// The broad main flows in the reference taper toward the destination
    /// card and stay power-driven: a high-power branch nearly fills the card
    /// edge while a hairline branch stays thin.
    static func mainFlowEndWidth(for watts: Double, cardHeight: CGFloat) -> CGFloat {
        guard watts.isFinite, watts > outputThresholdWatts else { return 0 }
        let ratio = min(1, max(0.18, CGFloat(sqrt(min(watts, 90) / 90))))
        return max(8, cardHeight * ratio)
    }

    static func showsChargingBranch(for metrics: SystemMetrics) -> Bool {
        metrics.externalPower && (metrics.batteryWatts ?? 0) > chargingThresholdWatts
    }

    static func showsBatteryBranch(for metrics: SystemMetrics) -> Bool {
        metrics.externalPower
            && (metrics.batteryWatts ?? 0) > outputThresholdWatts
    }

    /// With an underpowered adapter the battery is another source, not a
    /// destination branch. It must join the adapter on the left and feed the
    /// whole-machine node instead of animating back into the charger.
    static func showsBatteryInput(for metrics: SystemMetrics) -> Bool {
        metrics.externalPower
            && (metrics.batteryWatts ?? 0) < -outputThresholdWatts
    }

    static func batteryFlowIsReversed(for metrics: SystemMetrics) -> Bool {
        (metrics.batteryWatts ?? 0) < 0
    }

    static func visibleDeviceCount(for metrics: SystemMetrics) -> Int {
        metrics.usbOutputs.filter { $0.watts > outputThresholdWatts }.prefix(3).count
    }

    static func displayedDeviceCount(for metrics: SystemMetrics) -> Int {
        displayedOutputs(for: metrics).count
    }

    static func displayedOutputNames(for metrics: SystemMetrics) -> [String] {
        displayedOutputs(for: metrics).map(\.name)
    }

    private static func displayedOutputs(for metrics: SystemMetrics) -> [USBPowerFlow] {
        var displayed = Array(
            metrics.usbOutputs
                .filter { $0.watts > outputThresholdWatts }
                .prefix(3)
        )
        func appendInternal(
            name: String,
            watts: Double?,
            index: Int,
            minimumWatts: Double = outputThresholdWatts
        ) {
            guard displayed.count < 3,
                  let watts,
                  watts.isFinite,
                  watts >= minimumWatts else { return }
            displayed.append(USBPowerFlow(
                portIndex: index,
                name: name,
                watts: watts,
                voltage: nil,
                current: nil
            ))
        }
        appendInternal(name: "CPU", watts: metrics.cpuWatts, index: -100)
        appendInternal(name: "GPU", watts: metrics.gpuWatts, index: -101)

        // A process consumes power through CPU, GPU, memory, and other
        // hardware. It belongs in a future drill-down, not beside those rails.
        // The current peer-level remainder is measured by subtraction from the
        // whole-machine total rather than guessed from process billing.
        let wholeMachineWatts = max(0, metrics.systemWatts ?? metrics.sourceWatts ?? 0)
        let externalWatts = metrics.usbOutputs.reduce(0) { partial, output in
            partial + max(0, output.watts.isFinite ? output.watts : 0)
        }
        let cpuWatts = max(0, metrics.cpuWatts?.isFinite == true ? metrics.cpuWatts ?? 0 : 0)
        let gpuWatts = max(0, metrics.gpuWatts?.isFinite == true ? metrics.gpuWatts ?? 0 : 0)
        let otherHardwareWatts = max(
            0,
            wholeMachineWatts - externalWatts - cpuWatts - gpuWatts
        )
        appendInternal(name: "其他硬件", watts: otherHardwareWatts, index: -102)
        return displayed
    }

    private var usesCompactLayout: Bool {
        Self.displayedDeviceCount(for: metrics) == 0
    }

    private var activeCanvas: NSSize {
        usesCompactLayout ? Design.compactCanvas : Design.expandedCanvas
    }

    private var preferredViewSize: NSSize {
        usesCompactLayout ? Design.compactViewSize : structure.size
    }

    override var intrinsicContentSize: NSSize {
        preferredViewSize
    }

    private func updateLayoutSize() {
        let size = preferredViewSize
        if frame.size != size {
            setFrameSize(size)
        }
        invalidateIntrinsicContentSize()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let canvas = activeCanvas
        let scale = min(bounds.width / canvas.width, bounds.height / canvas.height)
        let origin = NSPoint(
            x: (bounds.width - canvas.width * scale) / 2,
            y: (bounds.height - canvas.height * scale) / 2
        )

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: origin.x, yBy: origin.y)
        transform.scale(by: scale)
        transform.concat()
        drawGraph()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawGraph() {
        let batterySignedPower = metrics.batteryWatts
        let batteryMagnitude = batterySignedPower.map(abs)
        let showsBattery = Self.showsBatteryBranch(for: metrics)
        let systemPower = positive(metrics.systemWatts ?? metrics.sourceWatts)
        let outputs = Self.displayedOutputs(for: metrics)
        if Self.showsBatteryInput(for: metrics), let systemPower {
            drawUnderpoweredGraph(
                batteryPower: batteryMagnitude ?? 0,
                chargerPower: positive(metrics.inputWatts) ?? max(0, systemPower - (batteryMagnitude ?? 0)),
                systemPower: systemPower,
                outputs: outputs
            )
            return
        }
        if outputs.isEmpty {
            drawCompactGraph(
                batteryMagnitude: batteryMagnitude,
                showsBattery: showsBattery,
                systemPower: systemPower
            )
            return
        }
        let slots = outputSlots(for: outputs.count)

        let mainLayouts = mainRibbonLayouts(
            batteryMagnitude: batteryMagnitude,
            showsBattery: showsBattery,
            systemPower: systemPower,
            minimumSystemHeight: Self.requiredSystemCardHeight(
                for: outputs.map(\.watts)
            )
        )
        drawMainRibbonBodies(mainLayouts)
        for layout in mainLayouts {
            let isBattery = layout.kind == .battery
            drawEnergySweep(
                from: layout.start,
                to: layout.end,
                watts: layout.watts,
                sourceColor: Self.color(0xD9C778),
                destinationColor: isBattery
                    ? Self.color(0x83C596)
                    : Self.color(0x6A9FE5),
                reversesFlow: false,
                animationPower: isBattery ? batteryMagnitude : nil,
                crossSection: max(layout.startWidth, layout.endWidth),
                clippedTo: layout.path
            )
        }

        let systemLayout = mainLayouts.first { $0.kind == .system }
        let outputLayouts = systemLayout.map {
            outputRibbonLayouts(outputs: outputs, slots: slots, systemCardRect: $0.cardRect)
        } ?? []
        drawOutputRibbonBodies(outputLayouts)
        for layout in outputLayouts {
            drawEnergySweep(
                from: layout.start,
                to: layout.end,
                watts: layout.output.watts,
                sourceColor: Self.color(0x293A37),
                destinationColor: deviceColor(for: layout.output.name),
                reversesFlow: false,
                animationPower: nil,
                crossSection: max(layout.startWidth, layout.endWidth),
                clippedTo: layout.path,
                followsGentleCurve: !layout.usesMainFlowStyle && layout.slot == .middle
            )
        }

        drawReferenceSourceCard()
        drawReferencePlugOrBatteryIcon()
        drawCenteredDesignText(
            sourceValue,
            centerX: 101,
            baselineY: 347,
            size: 39,
            weight: .semibold,
            color: referenceTextColor
        )

        for layout in mainLayouts {
            drawSecondLevelCard(layout)
            drawMainRibbonLabel(layout)
        }

        let hasSingleOutput = outputLayouts.count == 1
        for layout in outputLayouts {
            drawReferenceEndpointCard(layout)
            drawReferenceEndpointIcon(layout, isOnlyOutput: hasSingleOutput)
            drawOutputRibbonLabel(layout)
        }
    }

    /// No measured external outputs: collapse the fan-out and distribute the
    /// complete source edge between the active battery/system destinations.
    /// Ribbon and card heights share the same power-linked allocation.
    private func drawCompactGraph(
        batteryMagnitude: Double?,
        showsBattery: Bool,
        systemPower: Double?
    ) {
        let layouts = compactMainRibbonLayouts(
            batteryMagnitude: batteryMagnitude,
            showsBattery: showsBattery,
            systemPower: systemPower
        )
        drawMainRibbonBodies(layouts)
        for layout in layouts {
            let isBattery = layout.kind == .battery
            drawEnergySweep(
                from: layout.start,
                to: layout.end,
                watts: layout.watts,
                sourceColor: Self.color(0xD9C778),
                destinationColor: isBattery
                    ? Self.color(0x8BC59A)
                    : Self.color(0x82ACE5),
                reversesFlow: false,
                animationPower: isBattery ? batteryMagnitude : nil,
                crossSection: max(layout.startWidth, layout.endWidth),
                clippedTo: layout.path
            )
        }

        let sourcePath = compactSourceCardPath()
        drawCompactGlass(
            sourcePath,
            bounds: svgRect(45, 90, 163, 394),
            tint: NSColor.white,
            tintStrength: 0.06,
            isFlow: false
        )
        drawCompactSourceIcon()
        drawCenteredDesignText(
            sourceValue.replacingOccurrences(of: " ", with: ""),
            centerX: 127,
            baselineY: 340,
            size: 44,
            weight: .medium,
            color: compactTextColor
        )

        for layout in layouts {
            drawCompactDestinationCard(layout)
            drawCompactMainRibbonLabel(layout)
        }
    }

    private func compactMainRibbonLayouts(
        batteryMagnitude: Double?,
        showsBattery: Bool,
        systemPower: Double?
    ) -> [MainRibbonLayout] {
        var specs: [(MainBranchKind, Double)] = []
        if showsBattery {
            specs.append((.battery, max(0, batteryMagnitude ?? 0)))
        }
        if let systemPower {
            specs.append((.system, max(0, systemPower)))
        }
        guard !specs.isEmpty else { return [] }

        let totalAttachmentHeight: CGFloat = 394
        let heights = Self.linkedCardHeights(
            for: specs.map { $0.1 },
            totalHeight: totalAttachmentHeight,
            minimumHeight: 72
        )
        var sourceCursorY: CGFloat = 90
        var layouts: [MainRibbonLayout] = []
        for index in specs.indices {
            let height = heights[index]
            let kind = specs[index].0
            let cardTop: CGFloat
            if specs.count == 1 {
                cardTop = (Design.compactCanvas.height - height) / 2
            } else if kind == .battery {
                cardTop = 30
            } else {
                cardTop = Design.compactCanvas.height - 30 - height
            }
            let cardRect = svgRect(1094, cardTop, 165, height)
            let startWidth = height
            let start = svgPoint(225, sourceCursorY + startWidth / 2)
            sourceCursorY += startWidth
            let end = svgPoint(1078, cardTop + height / 2)
            let endWidth = height
            let path = ribbonPath(
                from: start,
                to: end,
                startWidth: startWidth,
                endWidth: endWidth,
                roundsDestination: true,
                gentleCurve: false,
                roundsSource: false,
                roundsSourceTop: index == specs.startIndex,
                roundsSourceBottom: index == specs.index(before: specs.endIndex),
                maximumSourceRadius: Design.flowCornerRadius,
                maximumDestinationRadius: Design.flowCornerRadius
            )
            layouts.append(MainRibbonLayout(
                kind: kind,
                watts: specs[index].1,
                cardRect: cardRect,
                start: start,
                end: end,
                startWidth: startWidth,
                endWidth: endWidth,
                path: path
            ))
        }
        return layouts
    }

    private func drawCompactDestinationCard(_ layout: MainRibbonLayout) {
        let radius = min(Design.compactModuleCornerRadius, layout.cardRect.height / 2)
        let path = NSBezierPath(
            roundedRect: layout.cardRect,
            xRadius: radius,
            yRadius: radius
        )
        let isBattery = layout.kind == .battery
        drawCompactGlass(
            path,
            bounds: layout.cardRect,
            tint: Self.color(isBattery ? 0xE0F0E6 : 0xE2EBF8),
            tintStrength: isBattery ? 0.20 : 0.22,
            isFlow: false
        )
        let symbolName = isBattery ? "battery.100percent.bolt" : "laptopcomputer"
        let color: NSColor = isBattery ? .systemGreen : .systemBlue
        let iconSize = Self.secondLevelIconSize(forCardHeight: layout.cardRect.height)
        if let image = symbolImage(symbolName, pointSize: iconSize, color: color) {
            drawSymbol(
                image,
                centeredAt: NSPoint(x: layout.cardRect.midX, y: layout.cardRect.midY),
                maximumSize: iconSize,
                rotated: false
            )
        }
    }

    private func drawCompactMainRibbonLabel(_ layout: MainRibbonLayout) {
        let point = cubicPoint(from: layout.start, to: layout.end, t: 0.50)
        let fontSize = min(48, max(29, 22 + layout.endWidth * 0.10))
        let thinOffset = layout.endWidth < 58
            ? layout.endWidth / 2 + fontSize * 0.62
            : 0
        drawText(
            compactBranchWatts(layout.watts),
            in: NSRect(
                x: point.x - 110,
                y: point.y - fontSize * 0.48 + thinOffset,
                width: 220,
                height: fontSize * 1.2
            ),
            font: roundedFont(size: fontSize, weight: .bold),
            color: compactTextColor,
            alignment: .center,
            shadow: true
        )
    }

    private func drawUnderpoweredGraph(
        batteryPower: Double,
        chargerPower: Double,
        systemPower: Double,
        outputs: [USBPowerFlow]
    ) {
        let systemCardRect: NSRect
        if usesCompactLayout {
            systemCardRect = svgRect(1094, 84.5, 165, 394)
        } else {
            systemCardRect = svgRect(570, 112.5, 146, 456)
        }
        let inputLayouts = underpoweredInputLayouts(
            batteryPower: batteryPower,
            chargerPower: chargerPower,
            systemCardRect: systemCardRect
        )
        drawInputRibbonBodies(inputLayouts)
        for layout in inputLayouts {
            drawEnergySweep(
                from: layout.start,
                to: layout.end,
                watts: layout.watts,
                sourceColor: layout.kind == .battery
                    ? Self.color(0x83C596)
                    : Self.color(0xD9C778),
                destinationColor: Self.color(0x6A9FE5),
                reversesFlow: false,
                animationPower: nil,
                crossSection: max(layout.startWidth, layout.endWidth),
                clippedTo: layout.path
            )
        }

        let slots = outputSlots(for: outputs.count)
        let outputLayouts = outputs.isEmpty
            ? []
            : outputRibbonLayouts(
                outputs: outputs,
                slots: slots,
                systemCardRect: systemCardRect
            )
        drawOutputRibbonBodies(outputLayouts)
        for layout in outputLayouts {
            drawEnergySweep(
                from: layout.start,
                to: layout.end,
                watts: layout.output.watts,
                sourceColor: Self.color(0x6A9FE5),
                destinationColor: deviceColor(for: layout.output.name),
                reversesFlow: false,
                animationPower: nil,
                crossSection: max(layout.startWidth, layout.endWidth),
                clippedTo: layout.path,
                followsGentleCurve: !layout.usesMainFlowStyle && layout.slot == .middle
            )
        }

        for layout in inputLayouts {
            drawUnderpoweredInputCard(layout)
            drawInputRibbonLabel(layout)
        }
        drawUnderpoweredSystemCard(systemCardRect, watts: systemPower)
        let hasSingleOutput = outputLayouts.count == 1
        for layout in outputLayouts {
            drawReferenceEndpointCard(layout)
            drawReferenceEndpointIcon(layout, isOnlyOutput: hasSingleOutput)
            drawOutputRibbonLabel(layout)
        }
    }

    private func underpoweredInputLayouts(
        batteryPower: Double,
        chargerPower: Double,
        systemCardRect: NSRect
    ) -> [InputRibbonLayout] {
        var specs: [(InputBranchKind, Double)] = [(.battery, max(0, batteryPower))]
        if chargerPower > Self.outputThresholdWatts {
            specs.append((.charger, chargerPower))
        }
        let totalHeight: CGFloat = usesCompactLayout ? 394 : 456
        let heights = Self.linkedCardHeights(
            for: specs.map { $0.1 },
            totalHeight: totalHeight,
            minimumHeight: usesCompactLayout
                ? 72
                : Design.minimumInputCardHeight
        )
        let sourceX: CGFloat = usesCompactLayout ? 45 : 29
        let sourceWidth: CGFloat = usesCompactLayout ? 163 : 146
        let startX: CGFloat = usesCompactLayout ? 225 : 190
        let endX: CGFloat = usesCompactLayout ? 1078 : 554
        let margin: CGFloat = usesCompactLayout ? 45 : 35
        let destinationTotal = systemCardRect.height
        let destinationWidths = heights.map { destinationTotal * $0 / totalHeight }
        let systemTop = activeCanvas.height - systemCardRect.maxY
        var destinationCursorY = systemTop
        var layouts: [InputRibbonLayout] = []

        for index in specs.indices {
            let height = heights[index]
            let kind = specs[index].0
            let cardTop: CGFloat
            if specs.count == 1 {
                cardTop = (activeCanvas.height - height) / 2
            } else if kind == .battery {
                cardTop = margin
            } else {
                cardTop = activeCanvas.height - margin - height
            }
            let cardRect = svgRect(sourceX, cardTop, sourceWidth, height)
            let endWidth = destinationWidths[index]
            let start = svgPoint(startX, cardTop + height / 2)
            let end = svgPoint(endX, destinationCursorY + endWidth / 2)
            destinationCursorY += endWidth
            let startWidth = height
            let path = ribbonPath(
                from: start,
                to: end,
                startWidth: startWidth,
                endWidth: endWidth,
                roundsDestination: false,
                gentleCurve: false,
                roundsSource: true,
                roundsDestinationTop: index == specs.startIndex,
                roundsDestinationBottom: index == specs.index(before: specs.endIndex),
                maximumSourceRadius: Design.flowCornerRadius,
                maximumDestinationRadius: Design.flowCornerRadius
            )
            layouts.append(InputRibbonLayout(
                kind: kind,
                watts: specs[index].1,
                cardRect: cardRect,
                start: start,
                end: end,
                startWidth: startWidth,
                endWidth: endWidth,
                path: path
            ))
        }
        return layouts
    }

    private func drawInputRibbonBodies(_ layouts: [InputRibbonLayout]) {
        guard !layouts.isEmpty else { return }
        let compound = NSBezierPath()
        layouts.forEach { compound.append($0.path) }
        drawGlassFill(compound)
        // The two inputs may overlap optically while they merge. Drawing one
        // shared adaptive surface avoids a darker triangular double-fill.
        drawGlassSheen(compound)
        for (index, layout) in layouts.enumerated() {
            let outline = ribbonSelectiveOutlinePath(
                from: layout.start,
                to: layout.end,
                startWidth: layout.startWidth,
                endWidth: layout.endWidth,
                roundsDestination: false,
                gentleCurve: false,
                omitsTopEdge: false,
                omitsBottomEdge: false,
                roundsSource: true,
                roundsDestinationTop: index == layouts.startIndex,
                roundsDestinationBottom: index == layouts.index(before: layouts.endIndex),
                maximumSourceRadius: Design.flowCornerRadius,
                maximumDestinationRadius: Design.flowCornerRadius,
                drawsDestinationCap: false
            )
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(isDarkAppearance ? 0.24 : 0.14)
            shadow.shadowOffset = NSSize(width: 0, height: isDarkAppearance ? -2 : -3)
            shadow.shadowBlurRadius = isDarkAppearance ? 8 : 12
            shadow.set()
            stroke(outline, color: NSColor.black.withAlphaComponent(0.10), width: 3.2)
            NSGraphicsContext.restoreGraphicsState()
            stroke(
                outline,
                color: NSColor.black.withAlphaComponent(isDarkAppearance ? 0.20 : 0.11),
                width: 2.5
            )
            stroke(
                outline,
                color: adaptiveModuleInnerRim,
                width: 1.1
            )
        }
        drawSharedAttachmentOutline(
            x: layouts[0].end.x,
            minimumY: layouts.map { $0.end.y - $0.endWidth / 2 }.min() ?? 0,
            maximumY: layouts.map { $0.end.y + $0.endWidth / 2 }.max() ?? 0,
            radius: Design.flowCornerRadius,
            side: .destination,
            outerWidth: 2.5,
            innerWidth: 1.1
        )
    }

    private func drawUnderpoweredInputCard(_ layout: InputRibbonLayout) {
        let radius = min(Design.moduleCornerRadius, layout.cardRect.height / 2)
        let path = NSBezierPath(roundedRect: layout.cardRect, xRadius: radius, yRadius: radius)
        if usesCompactLayout {
            drawCompactGlass(
                path,
                bounds: layout.cardRect,
                tint: layout.kind == .battery
                    ? Self.color(0xE0F0E6)
                    : NSColor.white,
                tintStrength: layout.kind == .battery ? 0.20 : 0.06,
                isFlow: false
            )
        } else {
            drawReferenceCard(path, bounds: layout.cardRect, green: layout.kind == .battery)
        }
        let symbolName = layout.kind == .battery ? batterySymbol : "powerplug.fill"
        let color: NSColor = layout.kind == .battery ? .systemGreen : .systemOrange
        let iconSize = Self.secondLevelIconSize(forCardHeight: layout.cardRect.height)
        if let image = symbolImage(symbolName, pointSize: iconSize, color: color) {
            drawSymbol(
                image,
                centeredAt: NSPoint(x: layout.cardRect.midX, y: layout.cardRect.midY),
                maximumSize: iconSize,
                rotated: layout.kind == .charger
            )
        }
    }

    private func drawInputRibbonLabel(_ layout: InputRibbonLayout) {
        let point = cubicPoint(from: layout.start, to: layout.end, t: 0.50)
        let fontSize = min(43, max(24, 19 + layout.endWidth * 0.12))
        drawText(
            compactBranchWatts(layout.watts),
            in: NSRect(
                x: point.x - 100,
                y: point.y - fontSize * 0.48,
                width: 200,
                height: fontSize * 1.2
            ),
            font: roundedFont(size: fontSize, weight: .bold),
            color: referenceTextColor,
            alignment: .center,
            shadow: true
        )
    }

    private func drawUnderpoweredSystemCard(
        _ rect: NSRect,
        watts power: Double
    ) {
        let radius = min(Design.moduleCornerRadius, rect.height / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        if usesCompactLayout {
            drawCompactGlass(
                path,
                bounds: rect,
                tint: Self.color(0xE2EBF8),
                tintStrength: 0.22,
                isFlow: false
            )
        } else {
            drawReferenceCard(path, bounds: rect, green: true)
        }
        let iconSize = Self.secondLevelIconSize(forCardHeight: rect.height)
        if let image = symbolImage("laptopcomputer", pointSize: iconSize, color: .systemBlue) {
            drawSymbol(
                image,
                centeredAt: NSPoint(x: rect.midX, y: rect.midY + iconSize * 0.62),
                maximumSize: iconSize,
                rotated: false
            )
        }
        let fontSize = min(42, max(30, rect.height * 0.10))
        drawText(
            watts(power),
            in: NSRect(
                x: rect.minX + 4,
                y: rect.midY - iconSize * 0.88,
                width: rect.width - 8,
                height: fontSize * 1.25
            ),
            font: roundedFont(size: fontSize, weight: .semibold),
            color: referenceTextColor,
            alignment: .center,
            shadow: true
        )
    }

    private func compactSourceCardPath() -> NSBezierPath {
        let rect = svgRect(45, 90, 163, 394)
        return NSBezierPath(
            roundedRect: rect,
            xRadius: Design.compactModuleCornerRadius,
            yRadius: Design.compactModuleCornerRadius
        )
    }

    private func compactUpperFlowPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: svgPoint(242, 90))
        path.curve(
            to: svgPoint(1059, 40),
            controlPoint1: svgPoint(430, 88),
            controlPoint2: svgPoint(768, 61)
        )
        path.curve(
            to: svgPoint(1078, 59),
            controlPoint1: svgPoint(1070, 40),
            controlPoint2: svgPoint(1078, 48)
        )
        path.line(to: svgPoint(1078, 260))
        path.curve(
            to: svgPoint(1061, 278),
            controlPoint1: svgPoint(1078, 271),
            controlPoint2: svgPoint(1072, 277)
        )
        path.curve(
            to: svgPoint(278, 325),
            controlPoint1: svgPoint(757, 283),
            controlPoint2: svgPoint(507, 299)
        )
        path.line(to: svgPoint(225, 325))
        path.line(to: svgPoint(225, 107))
        path.curve(
            to: svgPoint(242, 90),
            controlPoint1: svgPoint(225, 97),
            controlPoint2: svgPoint(232, 91)
        )
        path.close()
        return path
    }

    private func compactLowerFlowPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: svgPoint(225, 326))
        path.line(to: svgPoint(278, 326))
        path.curve(
            to: svgPoint(1061, 375),
            controlPoint1: svgPoint(507, 350),
            controlPoint2: svgPoint(757, 370)
        )
        path.curve(
            to: svgPoint(1078, 392),
            controlPoint1: svgPoint(1072, 375),
            controlPoint2: svgPoint(1078, 382)
        )
        path.line(to: svgPoint(1078, 514))
        path.curve(
            to: svgPoint(1061, 531),
            controlPoint1: svgPoint(1078, 524),
            controlPoint2: svgPoint(1072, 531)
        )
        path.curve(
            to: svgPoint(242, 484),
            controlPoint1: svgPoint(755, 524),
            controlPoint2: svgPoint(500, 504)
        )
        path.curve(
            to: svgPoint(225, 467),
            controlPoint1: svgPoint(232, 483),
            controlPoint2: svgPoint(225, 477)
        )
        path.line(to: svgPoint(225, 326))
        path.close()
        return path
    }

    /// The compact upper and lower fills share the 225...278 origin segment.
    /// Drawing this single perimeter once removes the false horizontal splice
    /// while preserving the real V-shaped split that begins at x=278.
    private func compactMainFlowUnionPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: svgPoint(242, 90))
        path.curve(
            to: svgPoint(1059, 40),
            controlPoint1: svgPoint(430, 88),
            controlPoint2: svgPoint(768, 61)
        )
        path.curve(
            to: svgPoint(1078, 59),
            controlPoint1: svgPoint(1070, 40),
            controlPoint2: svgPoint(1078, 48)
        )
        path.line(to: svgPoint(1078, 260))
        path.curve(
            to: svgPoint(1061, 278),
            controlPoint1: svgPoint(1078, 271),
            controlPoint2: svgPoint(1072, 277)
        )
        path.curve(
            to: svgPoint(278, 325),
            controlPoint1: svgPoint(757, 283),
            controlPoint2: svgPoint(507, 299)
        )
        path.curve(
            to: svgPoint(1061, 375),
            controlPoint1: svgPoint(507, 350),
            controlPoint2: svgPoint(757, 370)
        )
        path.curve(
            to: svgPoint(1078, 392),
            controlPoint1: svgPoint(1072, 375),
            controlPoint2: svgPoint(1078, 382)
        )
        path.line(to: svgPoint(1078, 514))
        path.curve(
            to: svgPoint(1061, 531),
            controlPoint1: svgPoint(1078, 524),
            controlPoint2: svgPoint(1072, 531)
        )
        path.curve(
            to: svgPoint(242, 484),
            controlPoint1: svgPoint(755, 524),
            controlPoint2: svgPoint(500, 504)
        )
        path.curve(
            to: svgPoint(225, 467),
            controlPoint1: svgPoint(232, 483),
            controlPoint2: svgPoint(225, 477)
        )
        path.line(to: svgPoint(225, 107))
        path.curve(
            to: svgPoint(242, 90),
            controlPoint1: svgPoint(225, 97),
            controlPoint2: svgPoint(232, 91)
        )
        path.close()
        return path
    }

    private func compactBatteryCardPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: svgPoint(1111, 40))
        path.line(to: svgPoint(1198, 40))
        path.curve(
            to: svgPoint(1259, 102),
            controlPoint1: svgPoint(1234, 40),
            controlPoint2: svgPoint(1259, 66)
        )
        path.line(to: svgPoint(1259, 217))
        path.curve(
            to: svgPoint(1199, 278),
            controlPoint1: svgPoint(1259, 253),
            controlPoint2: svgPoint(1234, 278)
        )
        path.line(to: svgPoint(1111, 278))
        path.curve(
            to: svgPoint(1094, 261),
            controlPoint1: svgPoint(1101, 278),
            controlPoint2: svgPoint(1094, 271)
        )
        path.line(to: svgPoint(1094, 57))
        path.curve(
            to: svgPoint(1111, 40),
            controlPoint1: svgPoint(1094, 47),
            controlPoint2: svgPoint(1101, 40)
        )
        path.close()
        return path
    }

    private func compactLaptopCardPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: svgPoint(1111, 375))
        path.line(to: svgPoint(1200, 375))
        path.curve(
            to: svgPoint(1259, 434),
            controlPoint1: svgPoint(1235, 375),
            controlPoint2: svgPoint(1259, 400)
        )
        path.line(to: svgPoint(1259, 474))
        path.curve(
            to: svgPoint(1200, 533),
            controlPoint1: svgPoint(1259, 508),
            controlPoint2: svgPoint(1235, 533)
        )
        path.line(to: svgPoint(1111, 533))
        path.curve(
            to: svgPoint(1094, 516),
            controlPoint1: svgPoint(1101, 533),
            controlPoint2: svgPoint(1094, 526)
        )
        path.line(to: svgPoint(1094, 392))
        path.curve(
            to: svgPoint(1111, 375),
            controlPoint1: svgPoint(1094, 382),
            controlPoint2: svgPoint(1101, 375)
        )
        path.close()
        return path
    }

    private func drawCompactGlass(
        _ path: NSBezierPath,
        bounds: NSRect,
        tint: NSColor,
        tintStrength: CGFloat,
        isFlow: Bool,
        drawsShadow: Bool = true,
        drawsRim: Bool = true
    ) {
        if drawsShadow {
            drawCompactShadow(path, isFlow: isFlow)
        }

        drawGradient(
            in: path,
            gradient: NSGradient(colorsAndLocations:
                (adaptiveModuleSurfaceTop, 0.0),
                (adaptiveModuleSurfaceBase, 0.52),
                (adaptiveModuleSurfaceBottom, 1.0)
            ),
            from: NSPoint(x: bounds.midX, y: bounds.maxY),
            to: NSPoint(x: bounds.midX, y: bounds.minY)
        )

        if drawsRim {
            drawCompactRim(path)
        }
    }

    private func drawCompactShadow(_ path: NSBezierPath, isFlow: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(
            isDarkAppearance ? 0.34 : (isFlow ? 0.20 : 0.17)
        )
        shadow.shadowOffset = NSSize(width: 0, height: isDarkAppearance ? -4 : -6)
        shadow.shadowBlurRadius = isDarkAppearance ? 12 : (isFlow ? 22 : 20)
        shadow.set()
        adaptiveModuleSurfaceBase.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCompactRim(_ path: NSBezierPath) {
        stroke(
            path,
            color: adaptiveModuleOuterRim,
            width: 3.0
        )
        stroke(
            path,
            color: adaptiveModuleInnerRim,
            width: 1.35
        )
    }

    private func drawCompactSourceIcon() {
        let symbol = metrics.externalPower ? "powerplug.fill" : batterySymbol
        let color: NSColor = metrics.externalPower ? .systemOrange : .systemGreen
        if let image = symbolImage(symbol, pointSize: 58, color: color) {
            drawSymbol(
                image,
                centeredAt: svgPoint(127, 252),
                maximumSize: 58,
                rotated: metrics.externalPower
            )
        }
    }

    private func drawCompactBatteryIcon() {
        let color = NSColor.systemGreen
        let symbol = symbolImage("battery.100percent.bolt", pointSize: 62, color: color)
            ?? symbolImage("battery.100percent", pointSize: 62, color: color)
        if let symbol {
            drawSymbol(symbol, centeredAt: svgPoint(1177, 158), maximumSize: 67, rotated: false)
        }
    }

    private func drawCompactLaptopIcon() {
        if let image = symbolImage("laptopcomputer", pointSize: 62, color: .systemBlue) {
            drawSymbol(image, centeredAt: svgPoint(1177, 455), maximumSize: 67, rotated: false)
        }
    }

    private static func color(_ rgb: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: alpha
        )
    }

    private func svgPoint(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: x, y: activeCanvas.height - y)
    }

    private func svgRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: x, y: activeCanvas.height - y - height, width: width, height: height)
    }

    private func sourceCardPath() -> NSBezierPath {
        let top = Design.sourceAttachmentCenterY - Design.sourceAttachmentHeight / 2
        let rect = svgRect(28, top, 146, Design.sourceAttachmentHeight)
        return NSBezierPath(
            roundedRect: rect,
            xRadius: Design.moduleCornerRadius,
            yRadius: Design.moduleCornerRadius
        )
    }

    private func batteryCardPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: svgPoint(585, 49))
        path.line(to: svgPoint(666, 49))
        path.curve(
            to: svgPoint(716, 101),
            controlPoint1: svgPoint(694, 49),
            controlPoint2: svgPoint(716, 72)
        )
        path.line(to: svgPoint(716, 294))
        path.curve(
            to: svgPoint(666, 346),
            controlPoint1: svgPoint(716, 323),
            controlPoint2: svgPoint(694, 346)
        )
        path.line(to: svgPoint(585, 346))
        path.curve(
            to: svgPoint(570, 331),
            controlPoint1: svgPoint(575, 346),
            controlPoint2: svgPoint(570, 340)
        )
        path.line(to: svgPoint(570, 64))
        path.curve(
            to: svgPoint(585, 49),
            controlPoint1: svgPoint(570, 54),
            controlPoint2: svgPoint(575, 49)
        )
        path.close()
        return path
    }

    private func upperFlowPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: svgPoint(207, 93))
        path.curve(
            to: svgPoint(407, 57),
            controlPoint1: svgPoint(290, 92),
            controlPoint2: svgPoint(347, 73)
        )
        path.curve(
            to: svgPoint(539, 48),
            controlPoint1: svgPoint(453, 45),
            controlPoint2: svgPoint(501, 48)
        )
        path.curve(
            to: svgPoint(554, 63),
            controlPoint1: svgPoint(548, 48),
            controlPoint2: svgPoint(554, 54)
        )
        path.line(to: svgPoint(554, 330))
        path.curve(
            to: svgPoint(539, 347),
            controlPoint1: svgPoint(554, 340),
            controlPoint2: svgPoint(549, 345)
        )
        path.curve(
            to: svgPoint(271, 392),
            controlPoint1: svgPoint(451, 350),
            controlPoint2: svgPoint(360, 365)
        )
        path.line(to: svgPoint(190, 392))
        path.line(to: svgPoint(190, 109))
        path.curve(
            to: svgPoint(207, 93),
            controlPoint1: svgPoint(190, 100),
            controlPoint2: svgPoint(197, 94)
        )
        path.close()
        return path
    }

    private func lowerFlowPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: svgPoint(190, 392))
        path.line(to: svgPoint(271, 392))
        path.curve(
            to: svgPoint(539, 439),
            controlPoint1: svgPoint(360, 419),
            controlPoint2: svgPoint(450, 437)
        )
        path.curve(
            to: svgPoint(554, 454),
            controlPoint1: svgPoint(549, 439),
            controlPoint2: svgPoint(554, 445)
        )
        path.line(to: svgPoint(554, 539))
        path.curve(
            to: svgPoint(539, 554),
            controlPoint1: svgPoint(554, 548),
            controlPoint2: svgPoint(548, 553)
        )
        path.curve(
            to: svgPoint(207, 509),
            controlPoint1: svgPoint(429, 554),
            controlPoint2: svgPoint(324, 537)
        )
        path.curve(
            to: svgPoint(190, 491),
            controlPoint1: svgPoint(197, 507),
            controlPoint2: svgPoint(190, 501)
        )
        path.line(to: svgPoint(190, 392))
        path.close()
        return path
    }

    /// One outer contour for both first-level flows. The shared 190...271
    /// segment is deliberately absent from the perimeter, so the two tinted
    /// fills meet as one continuous glass body before the V-shaped split.
    private func mainFlowUnionPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: svgPoint(207, 93))
        path.curve(
            to: svgPoint(407, 57),
            controlPoint1: svgPoint(290, 92),
            controlPoint2: svgPoint(347, 73)
        )
        path.curve(
            to: svgPoint(539, 48),
            controlPoint1: svgPoint(453, 45),
            controlPoint2: svgPoint(501, 48)
        )
        path.curve(
            to: svgPoint(554, 63),
            controlPoint1: svgPoint(548, 48),
            controlPoint2: svgPoint(554, 54)
        )
        path.line(to: svgPoint(554, 330))
        path.curve(
            to: svgPoint(539, 347),
            controlPoint1: svgPoint(554, 340),
            controlPoint2: svgPoint(549, 345)
        )
        path.curve(
            to: svgPoint(271, 392),
            controlPoint1: svgPoint(451, 350),
            controlPoint2: svgPoint(360, 365)
        )
        path.curve(
            to: svgPoint(539, 439),
            controlPoint1: svgPoint(360, 419),
            controlPoint2: svgPoint(450, 437)
        )
        path.curve(
            to: svgPoint(554, 454),
            controlPoint1: svgPoint(549, 439),
            controlPoint2: svgPoint(554, 445)
        )
        path.line(to: svgPoint(554, 539))
        path.curve(
            to: svgPoint(539, 554),
            controlPoint1: svgPoint(554, 548),
            controlPoint2: svgPoint(548, 553)
        )
        path.curve(
            to: svgPoint(207, 509),
            controlPoint1: svgPoint(429, 554),
            controlPoint2: svgPoint(324, 537)
        )
        path.curve(
            to: svgPoint(190, 491),
            controlPoint1: svgPoint(197, 507),
            controlPoint2: svgPoint(190, 501)
        )
        path.line(to: svgPoint(190, 109))
        path.curve(
            to: svgPoint(207, 93),
            controlPoint1: svgPoint(190, 100),
            controlPoint2: svgPoint(197, 94)
        )
        path.close()
        return path
    }

    private func hubPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: svgPoint(749, 439))
        path.line(to: svgPoint(796, 439))
        path.curve(
            to: svgPoint(812, 455),
            controlPoint1: svgPoint(806, 439),
            controlPoint2: svgPoint(812, 445)
        )
        path.line(to: svgPoint(812, 539))
        path.curve(
            to: svgPoint(796, 555),
            controlPoint1: svgPoint(812, 549),
            controlPoint2: svgPoint(806, 555)
        )
        path.line(to: svgPoint(749, 555))
        path.curve(
            to: svgPoint(733, 539),
            controlPoint1: svgPoint(738, 555),
            controlPoint2: svgPoint(733, 549)
        )
        path.line(to: svgPoint(733, 455))
        path.curve(
            to: svgPoint(749, 439),
            controlPoint1: svgPoint(733, 445),
            controlPoint2: svgPoint(738, 439)
        )
        path.close()
        return path
    }

    private func outputFlowPath(for slot: OutputSlot) -> NSBezierPath {
        let path = NSBezierPath()
        switch slot {
        case .top:
            path.move(to: svgPoint(812, 439))
            path.curve(
                to: svgPoint(914, 409),
                controlPoint1: svgPoint(857, 439),
                controlPoint2: svgPoint(886, 428)
            )
            path.curve(
                to: svgPoint(1054, 349),
                controlPoint1: svgPoint(960, 378),
                controlPoint2: svgPoint(1006, 357)
            )
            path.curve(
                to: svgPoint(1092, 347),
                controlPoint1: svgPoint(1069, 346),
                controlPoint2: svgPoint(1084, 346)
            )
            path.curve(
                to: svgPoint(1102, 359),
                controlPoint1: svgPoint(1099, 347),
                controlPoint2: svgPoint(1102, 352)
            )
            path.line(to: svgPoint(1102, 386))
            path.curve(
                to: svgPoint(1088, 400),
                controlPoint1: svgPoint(1102, 395),
                controlPoint2: svgPoint(1097, 400)
            )
            path.curve(
                to: svgPoint(929, 450),
                controlPoint1: svgPoint(1027, 400),
                controlPoint2: svgPoint(978, 421)
            )
            path.curve(
                to: svgPoint(812, 488),
                controlPoint1: svgPoint(893, 471),
                controlPoint2: svgPoint(858, 488)
            )
            path.close()
        case .middle:
            path.move(to: svgPoint(812, 488))
            path.line(to: svgPoint(1087, 488))
            path.curve(
                to: svgPoint(1096, 498),
                controlPoint1: svgPoint(1093, 488),
                controlPoint2: svgPoint(1096, 492)
            )
            path.line(to: svgPoint(1096, 504))
            path.curve(
                to: svgPoint(1087, 513),
                controlPoint1: svgPoint(1096, 510),
                controlPoint2: svgPoint(1092, 513)
            )
            path.line(to: svgPoint(812, 513))
            path.close()
        case .bottom:
            path.move(to: svgPoint(812, 514))
            path.curve(
                to: svgPoint(929, 551),
                controlPoint1: svgPoint(858, 514),
                controlPoint2: svgPoint(893, 530)
            )
            path.curve(
                to: svgPoint(1088, 602),
                controlPoint1: svgPoint(978, 580),
                controlPoint2: svgPoint(1027, 602)
            )
            path.curve(
                to: svgPoint(1102, 617),
                controlPoint1: svgPoint(1097, 602),
                controlPoint2: svgPoint(1102, 608)
            )
            path.line(to: svgPoint(1102, 633))
            path.curve(
                to: svgPoint(1088, 646),
                controlPoint1: svgPoint(1102, 642),
                controlPoint2: svgPoint(1097, 646)
            )
            path.curve(
                to: svgPoint(947, 604),
                controlPoint1: svgPoint(1038, 645),
                controlPoint2: svgPoint(990, 628)
            )
            path.curve(
                to: svgPoint(812, 555),
                controlPoint1: svgPoint(903, 579),
                controlPoint2: svgPoint(861, 555)
            )
            path.close()
        }
        return path
    }

    private func mainRibbonLayouts(
        batteryMagnitude: Double?,
        showsBattery: Bool,
        systemPower: Double?,
        minimumSystemHeight: CGFloat
    ) -> [MainRibbonLayout] {
        let batteryPower = showsBattery ? max(0, batteryMagnitude ?? 0) : 0
        let system = max(0, systemPower ?? 0)
        let heights = showsBattery
            ? Self.secondLevelCardHeights(
                batteryWatts: batteryPower,
                systemWatts: system,
                minimumSystemHeight: minimumSystemHeight
            )
            : (battery: 0, system: Design.sourceAttachmentHeight)
        var specs: [(MainBranchKind, Double, NSRect)] = []
        if showsBattery {
            specs.append((.battery, batteryPower, svgRect(570, 49, 146, heights.battery)))
        }
        if systemPower != nil {
            specs.append((.system, system, svgRect(570, 555 - heights.system, 146, heights.system)))
        }
        guard !specs.isEmpty else { return [] }

        // First-to-second-level ribbons follow the same hard rule as the
        // fan-out: source edge, curved body, destination edge, and destination
        // card all use one identical cross-section.
        let startWidths = specs.map { $0.2.height }

        var designCursorY = Design.sourceAttachmentCenterY
            - startWidths.reduce(0, +) / 2
        var layouts: [MainRibbonLayout] = []
        for index in specs.indices {
            let startWidth = startWidths[index]
            let startDesignY = designCursorY + startWidth / 2
            designCursorY += startWidth
            let cardRect = specs[index].2
            let endDesignY = activeCanvas.height - cardRect.midY
            let endWidth = startWidth
            let start = svgPoint(190, startDesignY)
            let end = svgPoint(554, endDesignY)
            let path = ribbonPath(
                from: start,
                to: end,
                startWidth: startWidth,
                endWidth: endWidth,
                roundsDestination: true,
                gentleCurve: false,
                roundsSource: false,
                roundsSourceTop: index == specs.startIndex,
                roundsSourceBottom: index == specs.index(before: specs.endIndex),
                maximumSourceRadius: Design.flowCornerRadius,
                maximumDestinationRadius: Design.flowCornerRadius
            )
            layouts.append(MainRibbonLayout(
                kind: specs[index].0,
                watts: specs[index].1,
                cardRect: cardRect,
                start: start,
                end: end,
                startWidth: startWidth,
                endWidth: endWidth,
                path: path
            ))
        }
        return layouts
    }

    private func drawMainRibbonBodies(_ layouts: [MainRibbonLayout]) {
        guard !layouts.isEmpty else { return }
        let compound = NSBezierPath()
        for layout in layouts {
            compound.append(layout.path)
        }
        drawGlassFill(compound)
        // One opaque-enough adaptive surface spans the complete compound.
        // Per-branch translucent fills double-blended wherever curved paths
        // overlap, which created the triangular "uncovered" patches visible
        // between the first and second hierarchy levels.
        drawGlassSheen(compound)

        for (index, layout) in layouts.enumerated() {
            let outline = ribbonSelectiveOutlinePath(
                from: layout.start,
                to: layout.end,
                startWidth: layout.startWidth,
                endWidth: layout.endWidth,
                roundsDestination: true,
                gentleCurve: false,
                omitsTopEdge: index > 0,
                omitsBottomEdge: index < layouts.count - 1,
                roundsSource: false,
                roundsSourceTop: index == layouts.startIndex,
                roundsSourceBottom: index == layouts.index(before: layouts.endIndex),
                maximumSourceRadius: Design.flowCornerRadius,
                maximumDestinationRadius: Design.flowCornerRadius,
                drawsSourceCap: false
            )
            stroke(
                outline,
                color: NSColor.black.withAlphaComponent(isDarkAppearance ? 0.20 : 0.11),
                width: 3.0
            )
            stroke(
                outline,
                color: adaptiveModuleInnerRim,
                width: 1.3
            )
            stroke(
                outline,
                color: adaptiveModuleInnerRim,
                width: 0.7
            )
        }

        drawSharedAttachmentOutline(
            x: layouts[0].start.x,
            minimumY: layouts.map { $0.start.y - $0.startWidth / 2 }.min() ?? 0,
            maximumY: layouts.map { $0.start.y + $0.startWidth / 2 }.max() ?? 0,
            radius: Design.flowCornerRadius,
            side: .source,
            outerWidth: 3.0,
            innerWidth: 1.3
        )
    }

    private enum AttachmentSide {
        case source
        case destination
    }

    /// A sibling group is one liquid surface at the shared module edge. Only
    /// its two outside corners are rounded; the internal branch boundaries
    /// stay filled, so rounding never cuts black wedges into the split.
    private func drawSharedAttachmentOutline(
        x: CGFloat,
        minimumY: CGFloat,
        maximumY: CGFloat,
        radius requestedRadius: CGFloat,
        side: AttachmentSide,
        outerWidth: CGFloat,
        innerWidth: CGFloat
    ) {
        let radius = min(requestedRadius, max(0, maximumY - minimumY) / 2)
        let direction: CGFloat = side == .source ? 1 : -1
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x + direction * radius, y: maximumY))
        path.curve(
            to: NSPoint(x: x, y: maximumY - radius),
            controlPoint1: NSPoint(
                x: x + direction * radius * 0.34,
                y: maximumY
            ),
            controlPoint2: NSPoint(
                x: x,
                y: maximumY - radius * 0.34
            )
        )
        path.line(to: NSPoint(x: x, y: minimumY + radius))
        path.curve(
            to: NSPoint(x: x + direction * radius, y: minimumY),
            controlPoint1: NSPoint(
                x: x,
                y: minimumY + radius * 0.34
            ),
            controlPoint2: NSPoint(
                x: x + direction * radius * 0.34,
                y: minimumY
            )
        )
        stroke(
            path,
            color: NSColor.black.withAlphaComponent(isDarkAppearance ? 0.20 : 0.11),
            width: outerWidth
        )
        stroke(path, color: adaptiveModuleInnerRim, width: innerWidth)
        stroke(path, color: adaptiveModuleInnerRim, width: 0.7)
    }

    private func outputRibbonLayouts(
        outputs: [USBPowerFlow],
        slots: [OutputSlot],
        systemCardRect: NSRect
    ) -> [OutputRibbonLayout] {
        guard outputs.count == slots.count, !outputs.isEmpty else { return [] }
        let powers = outputs.map(\.watts)
        // Endpoint size uses component tokens, not a mechanical fraction of
        // the parent. Power can enlarge a multi-device group, but it cannot
        // shrink a device below the normal readable floor.
        let preferredCardHeights = Self.preferredOutputCardHeights(for: powers)
        let equalWidths = Self.equalizedOutputWidths(
            preferredHeights: preferredCardHeights,
            watts: powers,
            maximumTotalHeight: systemCardRect.height
        )
        // Each branch is now a curved column rather than a tapered funnel:
        // source edge, full path cross-section, destination edge, and endpoint
        // card all use the exact same width.
        let cardHeights = equalWidths
        let startWidths = equalWidths
        let endWidths = equalWidths
        let totalHeight = startWidths.reduce(0, +)
        let systemDesignCenterY = activeCanvas.height - systemCardRect.midY
        var designCursorY = systemDesignCenterY - totalHeight / 2
        let systemDesignTop = activeCanvas.height - systemCardRect.maxY
        let regionTop = max(35, systemDesignTop - 100)
        let regionBottom: CGFloat = 650
        let cardCenters = outputs.count == 1
            ? [activeCanvas.height / 2]
            : packedOutputCardCenters(
                heights: cardHeights,
                regionTop: regionTop,
                regionBottom: regionBottom,
                fallbackCenter: systemDesignCenterY
            )
        var layouts: [OutputRibbonLayout] = []

        for index in outputs.indices {
            let startWidth = startWidths[index]
            let startDesignY = designCursorY + startWidth / 2
            designCursorY += startWidth
            let slot = slots[index]
            let cardRect = svgRect(1112, cardCenters[index] - cardHeights[index] / 2, 146, cardHeights[index])
            let start = NSPoint(
                x: systemCardRect.maxX + Design.outputRootGap,
                y: activeCanvas.height - startDesignY
            )
            let end = svgPoint(1102, cardCenters[index])
            let usesMainFlowStyle = outputs.count == 1
            let path = ribbonPath(
                from: start,
                to: end,
                startWidth: startWidth,
                endWidth: endWidths[index],
                roundsDestination: true,
                gentleCurve: !usesMainFlowStyle && slot == .middle,
                roundsSource: false,
                roundsSourceTop: index == outputs.startIndex,
                roundsSourceBottom: index == outputs.index(before: outputs.endIndex),
                maximumSourceRadius: Design.flowCornerRadius,
                maximumDestinationRadius: Design.flowCornerRadius
            )
            layouts.append(OutputRibbonLayout(
                output: outputs[index],
                slot: slot,
                usesMainFlowStyle: usesMainFlowStyle,
                cardRect: cardRect,
                start: start,
                end: end,
                startWidth: startWidth,
                endWidth: endWidths[index],
                path: path
            ))
        }
        return layouts
    }

    private func packedOutputCardCenters(
        heights: [CGFloat],
        regionTop: CGFloat,
        regionBottom: CGFloat,
        fallbackCenter: CGFloat
    ) -> [CGFloat] {
        guard !heights.isEmpty else { return [] }
        if heights.count == 1 {
            return [min(regionBottom - heights[0] / 2, max(regionTop + heights[0] / 2, fallbackCenter))]
        }
        let available = max(1, regionBottom - regionTop)
        let total = heights.reduce(0, +)
        let gap = max(
            12,
            min(
                Design.endpointModuleGap,
                (available - total) / CGFloat(heights.count - 1)
            )
        )
        let groupHeight = total + gap * CGFloat(heights.count - 1)
        let unclampedTop = fallbackCenter - groupHeight / 2
        let groupTop = min(
            regionBottom - groupHeight,
            max(regionTop, unclampedTop)
        )
        var cursor = groupTop
        return heights.map { height in
            let center = cursor + height / 2
            cursor += height + gap
            return center
        }
    }

    /// Draws the shared second-level outlet after the branch bodies. The
    /// branch start caps sit underneath this fill, while the right side has no
    /// rim at all; visually it is one root opening into N ribbons, not a card
    /// followed by N separately outlined shapes.
    private func drawSharedOutputRoot(for layouts: [OutputRibbonLayout]) {
        guard !layouts.isEmpty else { return }
        let minimumY = layouts.map { $0.start.y - $0.startWidth / 2 }.min() ?? 0
        let maximumY = layouts.map { $0.start.y + $0.startWidth / 2 }.max() ?? 0
        let root = sharedOutputRootPath(minimumY: minimumY, maximumY: maximumY)
        let bounds = root.bounds

        drawGradient(
            in: root,
            gradient: NSGradient(colorsAndLocations:
                (Self.color(0x9DBEB6, alpha: isDarkAppearance ? 0.17 : 0.28), 0.0),
                (NSColor.white.withAlphaComponent(isDarkAppearance ? 0.13 : 0.23), 0.52),
                (Self.color(0xB8CFD3, alpha: isDarkAppearance ? 0.05 : 0.08), 0.82),
                (NSColor.clear, 1.0)
            ),
            from: NSPoint(x: bounds.minX, y: bounds.midY),
            to: NSPoint(x: bounds.maxX, y: bounds.midY)
        )

        let outline = sharedOutputRootOutline(minimumY: minimumY, maximumY: maximumY)
        stroke(outline, color: NSColor.black.withAlphaComponent(0.20), width: 3.0)
        stroke(outline, color: Self.color(0xBED3D0, alpha: 0.26), width: 1.35)
        stroke(outline, color: NSColor.white.withAlphaComponent(0.27), width: 0.7)
    }

    private func sharedOutputRootPath(
        minimumY: CGFloat,
        maximumY: CGFloat
    ) -> NSBezierPath {
        let leftX: CGFloat = 733
        let rightX: CGFloat = 850
        let radius = min(16, (maximumY - minimumY) / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: leftX + radius, y: maximumY))
        path.line(to: NSPoint(x: rightX, y: maximumY))
        path.line(to: NSPoint(x: rightX, y: minimumY))
        path.line(to: NSPoint(x: leftX + radius, y: minimumY))
        path.curve(
            to: NSPoint(x: leftX, y: minimumY + radius),
            controlPoint1: NSPoint(x: leftX + radius * 0.42, y: minimumY),
            controlPoint2: NSPoint(x: leftX, y: minimumY + radius * 0.42)
        )
        path.line(to: NSPoint(x: leftX, y: maximumY - radius))
        path.curve(
            to: NSPoint(x: leftX + radius, y: maximumY),
            controlPoint1: NSPoint(x: leftX, y: maximumY - radius * 0.42),
            controlPoint2: NSPoint(x: leftX + radius * 0.42, y: maximumY)
        )
        path.close()
        return path
    }

    private func sharedOutputRootOutline(
        minimumY: CGFloat,
        maximumY: CGFloat
    ) -> NSBezierPath {
        let leftX: CGFloat = 733
        let rightX: CGFloat = 806
        let radius = min(16, (maximumY - minimumY) / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rightX, y: maximumY))
        path.line(to: NSPoint(x: leftX + radius, y: maximumY))
        path.curve(
            to: NSPoint(x: leftX, y: maximumY - radius),
            controlPoint1: NSPoint(x: leftX + radius * 0.42, y: maximumY),
            controlPoint2: NSPoint(x: leftX, y: maximumY - radius * 0.42)
        )
        path.line(to: NSPoint(x: leftX, y: minimumY + radius))
        path.curve(
            to: NSPoint(x: leftX + radius, y: minimumY),
            controlPoint1: NSPoint(x: leftX, y: minimumY + radius * 0.42),
            controlPoint2: NSPoint(x: leftX + radius * 0.42, y: minimumY)
        )
        path.line(to: NSPoint(x: rightX, y: minimumY))
        return path
    }

    private func drawUpperFlow(
        _ path: NSBezierPath,
        drawsOuterDecoration: Bool = true
    ) {
        if drawsOuterDecoration {
            drawGlassShadow(path)
        }
        drawGradient(
            in: path,
            gradient: NSGradient(colorsAndLocations:
                (Self.color(0xDCC66F, alpha: 0.34), 0.0),
                (Self.color(0xC8C28C, alpha: 0.28), 0.34),
                (Self.color(0xA9C3B3, alpha: 0.22), 0.67),
                (Self.color(0x94B2AA, alpha: 0.18), 0.84),
                (NSColor.white.withAlphaComponent(0.10), 1.0)
            ),
            from: svgPoint(190, 250),
            to: svgPoint(554, 250)
        )
        drawGlassSheen(path)
        if drawsOuterDecoration {
            drawGlassRim(path, tint: Self.color(0xB9CABF, alpha: 0.30))
        }
    }

    private func drawLowerFlow(
        _ path: NSBezierPath,
        drawsOuterDecoration: Bool = true
    ) {
        if drawsOuterDecoration {
            drawGlassShadow(path)
        }
        drawGradient(
            in: path,
            gradient: NSGradient(colorsAndLocations:
                (Self.color(0xDCC66F, alpha: 0.34), 0.0),
                (Self.color(0xC6C19B, alpha: 0.26), 0.34),
                (Self.color(0xAFC6C6, alpha: 0.22), 0.63),
                (Self.color(0xA1BED1, alpha: 0.18), 0.82),
                (NSColor.white.withAlphaComponent(0.10), 1.0)
            ),
            from: svgPoint(190, 470),
            to: svgPoint(554, 470)
        )
        drawGlassSheen(path)
        if drawsOuterDecoration {
            drawGlassRim(path, tint: Self.color(0xBED2DA, alpha: 0.30))
        }
    }

    private func drawOutputFlow(_ path: NSBezierPath, slot: OutputSlot) {
        let gradient: NSGradient?
        let strokeColor: NSColor
        let strokeWidth: CGFloat
        switch slot {
        case .middle:
            gradient = NSGradient(colorsAndLocations:
                (Self.color(0x8EC4A6, alpha: 0.17), 0.0),
                (NSColor.white.withAlphaComponent(0.19), 0.5),
                (Self.color(0xA9D5BC, alpha: 0.15), 1.0)
            )
            strokeColor = Self.color(0xB7D9C5, alpha: 0.27)
            strokeWidth = 1.6
        case .top, .bottom:
            gradient = NSGradient(colorsAndLocations:
                (Self.color(0x9DBEB6, alpha: 0.17), 0.0),
                (NSColor.white.withAlphaComponent(0.16), 0.48),
                (Self.color(0xB8CFD3, alpha: 0.15), 0.76),
                (NSColor.white.withAlphaComponent(0.10), 1.0)
            )
            strokeColor = Self.color(0xBED3D0, alpha: 0.25)
            strokeWidth = 1.8
        }
        drawGlassShadow(path)
        drawGradient(
            in: path,
            gradient: gradient,
            from: svgPoint(812, 501),
            to: svgPoint(1102, 501)
        )
        drawGlassSheen(path, strength: slot == .middle ? 0.72 : 1.0)
        stroke(path, color: NSColor.black.withAlphaComponent(0.20), width: strokeWidth + 1.2)
        stroke(path, color: strokeColor, width: strokeWidth)
    }

    private func drawOutputRibbonBodies(_ layouts: [OutputRibbonLayout]) {
        guard !layouts.isEmpty else { return }
        let compound = NSBezierPath()
        for layout in layouts {
            compound.append(layout.path)
        }
        drawGlassFill(compound)
        // Keep one compound background instead of layering one translucent
        // background per ribbon at the shared second-level outlet.
        drawGlassSheen(compound)
        for (index, layout) in layouts.enumerated() {
            drawOutputFlowOutline(
                layout,
                omitsTopEdge: index > 0,
                omitsBottomEdge: index < layouts.count - 1,
                roundsSourceTop: index == layouts.startIndex,
                roundsSourceBottom: index == layouts.index(before: layouts.endIndex)
            )
        }
        drawSharedAttachmentOutline(
            x: layouts[0].start.x,
            minimumY: layouts.map { $0.start.y - $0.startWidth / 2 }.min() ?? 0,
            maximumY: layouts.map { $0.start.y + $0.startWidth / 2 }.max() ?? 0,
            radius: Design.flowCornerRadius,
            side: .source,
            outerWidth: 3.0,
            innerWidth: 1.3
        )
    }

    private func drawOutputFlowFill(_ layout: OutputRibbonLayout) {
        let path = layout.path
        let slot = layout.slot
        let gradient: NSGradient?
        if layout.usesMainFlowStyle {
            gradient = NSGradient(colorsAndLocations:
                (Self.color(0xDCC66F, alpha: 0.34), 0.0),
                (Self.color(0xC6C19B, alpha: 0.26), 0.34),
                (Self.color(0xAFC6C6, alpha: 0.22), 0.63),
                (Self.color(0xA1BED1, alpha: 0.18), 0.82),
                (NSColor.white.withAlphaComponent(0.10), 1.0)
            )
        } else if slot == .middle {
            gradient = NSGradient(colorsAndLocations:
                (Self.color(0x8EC4A6, alpha: 0.17), 0.0),
                (NSColor.white.withAlphaComponent(0.19), 0.5),
                (Self.color(0xA9D5BC, alpha: 0.15), 1.0)
            )
        } else {
            gradient = NSGradient(colorsAndLocations:
                (Self.color(0x9DBEB6, alpha: 0.17), 0.0),
                (NSColor.white.withAlphaComponent(0.16), 0.48),
                (Self.color(0xB8CFD3, alpha: 0.15), 0.76),
                (NSColor.white.withAlphaComponent(0.10), 1.0)
            )
        }
        drawGradient(
            in: path,
            gradient: gradient,
            from: layout.start,
            to: layout.end
        )
    }

    private func drawOutputFlowOutline(
        _ layout: OutputRibbonLayout,
        omitsTopEdge: Bool,
        omitsBottomEdge: Bool,
        roundsSourceTop: Bool,
        roundsSourceBottom: Bool
    ) {
        let slot = layout.slot
        let strokeColor = adaptiveModuleInnerRim
        let strokeWidth: CGFloat = layout.usesMainFlowStyle
            ? 1.3
            : (slot == .middle ? 1.6 : 1.8)
        let outline = ribbonSelectiveOutlinePath(
            from: layout.start,
            to: layout.end,
            startWidth: layout.startWidth,
            endWidth: layout.endWidth,
            roundsDestination: true,
            gentleCurve: !layout.usesMainFlowStyle && slot == .middle,
            omitsTopEdge: omitsTopEdge,
            omitsBottomEdge: omitsBottomEdge,
            roundsSource: false,
            roundsSourceTop: roundsSourceTop,
            roundsSourceBottom: roundsSourceBottom,
            maximumSourceRadius: Design.flowCornerRadius,
            maximumDestinationRadius: Design.flowCornerRadius,
            drawsSourceCap: false
        )
        // Shadow the selective outside rim only. Shadowing each closed ribbon
        // would reveal doubled boundaries between translucent sibling flows.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(
            isDarkAppearance ? 0.24 : 0.14
        )
        shadow.shadowOffset = NSSize(width: 0, height: isDarkAppearance ? -2 : -3)
        shadow.shadowBlurRadius = isDarkAppearance ? 8 : 12
        shadow.set()
        stroke(
            outline,
            color: NSColor.black.withAlphaComponent(isDarkAppearance ? 0.16 : 0.09),
            width: strokeWidth + 2.0
        )
        NSGraphicsContext.restoreGraphicsState()
        stroke(
            outline,
            color: NSColor.black.withAlphaComponent(isDarkAppearance ? 0.20 : 0.11),
            width: strokeWidth + 1.2
        )
        stroke(outline, color: strokeColor, width: strokeWidth)
        stroke(
            outline,
            color: adaptiveModuleInnerRim,
            width: 0.55
        )
    }

    private func drawSecondLevelCard(_ layout: MainRibbonLayout) {
        let radius = min(Design.moduleCornerRadius, layout.cardRect.height / 2)
        let path = NSBezierPath(
            roundedRect: layout.cardRect,
            xRadius: radius,
            yRadius: radius
        )
        drawReferenceCard(
            path,
            bounds: layout.cardRect,
            green: layout.kind == .system
        )

        let symbolName = layout.kind == .battery
            ? "battery.100percent.bolt"
            : "laptopcomputer"
        let color: NSColor = layout.kind == .battery ? .systemGreen : .systemBlue
        let iconSize = Self.secondLevelIconSize(forCardHeight: layout.cardRect.height)
        if let image = symbolImage(symbolName, pointSize: iconSize, color: color) {
            drawSymbol(
                image,
                centeredAt: NSPoint(x: layout.cardRect.midX, y: layout.cardRect.midY),
                maximumSize: iconSize,
                rotated: false
            )
        }
    }

    private func drawMainRibbonLabel(_ layout: MainRibbonLayout) {
        let point = cubicPoint(from: layout.start, to: layout.end, t: 0.50)
        let fontSize = min(43, max(22, 18 + layout.endWidth * 0.22))
        let thinOffset = layout.endWidth < 38
            ? layout.endWidth / 2 + fontSize * 0.62
            : 0
        drawText(
            watts(layout.watts),
            in: NSRect(
                x: point.x - 90,
                y: point.y - fontSize * 0.48 + thinOffset,
                width: 180,
                height: fontSize * 1.2
            ),
            font: roundedFont(size: fontSize, weight: .bold),
            color: referenceTextColor,
            alignment: .center,
            shadow: true
        )
    }

    private func drawReferenceEndpointCard(_ layout: OutputRibbonLayout) {
        let radius = min(Design.moduleCornerRadius, layout.cardRect.height / 2)
        let path = NSBezierPath(
            roundedRect: layout.cardRect,
            xRadius: radius,
            yRadius: radius
        )
        drawReferenceCard(
            path,
            bounds: layout.cardRect,
            green: layout.slot == .bottom
        )
    }

    private func drawReferenceEndpointIcon(
        _ layout: OutputRibbonLayout,
        isOnlyOutput _: Bool
    ) {
        let symbolName = deviceSymbol(for: layout.output.name)
        let caption = Self.endpointCaption(for: layout.output.name)
        let iconSize = Self.endpointIconSize(forCardHeight: layout.cardRect.height)
        let captionOffset = min(25, max(18, layout.cardRect.height * 0.15))
        if let image = symbolImage(
            symbolName,
            pointSize: iconSize,
            color: deviceColor(for: layout.output.name)
        ) {
            drawSymbol(
                image,
                centeredAt: NSPoint(
                    x: layout.cardRect.midX,
                    y: layout.cardRect.midY + captionOffset
                ),
                maximumSize: iconSize,
                rotated: false
            )
        }
        let isLongCaption = caption.count > 5
        let fontSize = isLongCaption
            ? min(22, max(19, layout.cardRect.height * 0.14))
            : min(26, max(22, layout.cardRect.height * 0.16))
        drawText(
            caption,
            in: NSRect(
                x: layout.cardRect.minX + 4,
                y: layout.cardRect.midY - captionOffset - fontSize,
                width: layout.cardRect.width - 8,
                height: fontSize * 1.35
            ),
            font: roundedFont(size: fontSize, weight: .bold),
            color: referenceTextColor,
            alignment: .center,
            shadow: true
        )
    }

    private func drawOutputRibbonLabel(_ layout: OutputRibbonLayout) {
        let point = cubicPoint(from: layout.start, to: layout.end, t: 0.54)
        let usesPreciseSmallValue = layout.output.watts > 0 && layout.output.watts < 0.1
        let fontSize = min(
            usesPreciseSmallValue ? 36 : 43,
            max(22, 18 + layout.endWidth * 0.30)
        )
        let labelWidth: CGFloat = usesPreciseSmallValue ? 220 : 168
        let thinOffset = layout.endWidth < 34
            ? layout.endWidth / 2 + fontSize * 0.55
            : 0
        drawText(
            watts(layout.output.watts),
            in: NSRect(
                x: point.x - labelWidth / 2,
                y: point.y - fontSize * 0.48 + thinOffset,
                width: labelWidth,
                height: fontSize * 1.2
            ),
            font: roundedFont(size: fontSize, weight: .bold),
            color: referenceTextColor,
            alignment: .center,
            shadow: true
        )
    }

    private func drawReferenceSourceCard() {
        let path = sourceCardPath()
        let top = Design.sourceAttachmentCenterY - Design.sourceAttachmentHeight / 2
        drawReferenceCard(
            path,
            bounds: svgRect(28, top, 146, Design.sourceAttachmentHeight),
            green: false
        )
    }

    private func drawReferenceBatteryCard() {
        let path = batteryCardPath()
        drawReferenceCard(path, bounds: svgRect(570, 49, 146, 297), green: false)
    }

    private func drawReferenceLaptopCard() {
        let rect = svgRect(570, 439, 146, 116)
        let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        drawReferenceCard(path, bounds: rect, green: true)
    }

    private func drawReferenceHub() {
        let path = hubPath()
        drawReferenceCard(path, bounds: svgRect(733, 439, 79, 116), green: true)
    }

    private func drawReferenceEndpointCard(_ slot: OutputSlot) {
        let spec: (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, Bool) = switch slot {
        case .top: (1112, 347, 146, 53, 25, false)
        case .middle: (1112, 475, 146, 52, 24, false)
        case .bottom: (1113, 599, 146, 51, 24, true)
        }
        let rect = svgRect(spec.0, spec.1, spec.2, spec.3)
        let path = NSBezierPath(roundedRect: rect, xRadius: spec.4, yRadius: spec.4)
        drawReferenceCard(path, bounds: rect, green: spec.5)
    }

    /// Whole-Mac cards with a multi-branch outlet keep rounded left corners
    /// but expose a square, un-stroked right edge. The output ribbons begin at
    /// that exact coordinate, so their outer top/bottom edges continue the
    /// card perimeter without a gap or vertical splice line.
    private func rightConnectedCardPath(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
        path.curve(
            to: NSPoint(x: rect.minX, y: rect.maxY - radius),
            controlPoint1: NSPoint(x: rect.minX + radius * 0.34, y: rect.maxY),
            controlPoint2: NSPoint(x: rect.minX, y: rect.maxY - radius * 0.34)
        )
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.curve(
            to: NSPoint(x: rect.minX + radius, y: rect.minY),
            controlPoint1: NSPoint(x: rect.minX, y: rect.minY + radius * 0.34),
            controlPoint2: NSPoint(x: rect.minX + radius * 0.34, y: rect.minY)
        )
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.close()
        return path
    }

    private func rightConnectedCardOutline(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
        path.curve(
            to: NSPoint(x: rect.minX, y: rect.maxY - radius),
            controlPoint1: NSPoint(x: rect.minX + radius * 0.34, y: rect.maxY),
            controlPoint2: NSPoint(x: rect.minX, y: rect.maxY - radius * 0.34)
        )
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.curve(
            to: NSPoint(x: rect.minX + radius, y: rect.minY),
            controlPoint1: NSPoint(x: rect.minX, y: rect.minY + radius * 0.34),
            controlPoint2: NSPoint(x: rect.minX + radius * 0.34, y: rect.minY)
        )
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        return path
    }

    private func drawRightConnectedReferenceCard(
        _ path: NSBezierPath,
        bounds: NSRect,
        radius: CGFloat
    ) {
        adaptiveModuleSurfaceBase.setFill()
        path.fill()
        drawGradient(
            in: path,
            gradient: NSGradient(colorsAndLocations:
                (adaptiveModuleSurfaceTop, 0.0),
                (adaptiveModuleSurfaceBase, 0.46),
                (adaptiveModuleSurfaceBottom, 1.0)
            ),
            from: NSPoint(x: bounds.midX, y: bounds.maxY),
            to: NSPoint(x: bounds.midX, y: bounds.minY)
        )

        let outline = rightConnectedCardOutline(bounds, radius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isDarkAppearance ? 0.28 : 0.12)
        shadow.shadowOffset = NSSize(width: 0, height: isDarkAppearance ? -3 : -5)
        shadow.shadowBlurRadius = isDarkAppearance ? 8 : 14
        shadow.set()
        stroke(outline, color: adaptiveModuleOuterRim, width: 3.0)
        NSGraphicsContext.restoreGraphicsState()
        stroke(outline, color: adaptiveModuleOuterRim, width: 3.0)
        stroke(outline, color: adaptiveModuleInnerRim, width: 1.25)
    }

    private func drawReferenceCard(_ path: NSBezierPath, bounds: NSRect, green: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isDarkAppearance ? 0.36 : 0.17)
        shadow.shadowOffset = NSSize(width: 0, height: isDarkAppearance ? -3 : -6)
        shadow.shadowBlurRadius = isDarkAppearance ? 8 : 18
        shadow.set()
        adaptiveModuleSurfaceBase.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        drawGradient(
            in: path,
            gradient: NSGradient(colorsAndLocations:
                (adaptiveModuleSurfaceTop, 0.0),
                (adaptiveModuleSurfaceBase, 0.46),
                (adaptiveModuleSurfaceBottom, 1.0)
            ),
            from: NSPoint(x: bounds.midX, y: bounds.maxY),
            to: NSPoint(x: bounds.midX, y: bounds.minY)
        )
        stroke(
            path,
            color: adaptiveModuleOuterRim,
            width: 3.0
        )
        stroke(
            path,
            color: adaptiveModuleInnerRim,
            width: 1.25
        )
    }

    private func drawGlassShadow(_ path: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isDarkAppearance ? 0.32 : 0.18)
        shadow.shadowOffset = NSSize(width: 0, height: isDarkAppearance ? -3 : -5)
        shadow.shadowBlurRadius = isDarkAppearance ? 9 : 16
        shadow.set()
        adaptiveModuleSurfaceBase.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Shared ribbon roots use one neutral glass fill without per-subpath
    /// shadows. A compound NSBezierPath is not a geometric union: applying a
    /// shadow to it still shadows every closed child edge and exposes the
    /// otherwise invisible boundary between adjacent branches.
    private func drawGlassFill(_ path: NSBezierPath) {
        adaptiveModuleSurfaceBase.setFill()
        path.fill()
    }

    private func drawGlassSheen(_ path: NSBezierPath, strength: CGFloat = 1) {
        let bounds = path.bounds
        drawGradient(
            in: path,
            gradient: NSGradient(colorsAndLocations:
                (NSColor.white.withAlphaComponent(0.30 * strength), 0.0),
                (NSColor.white.withAlphaComponent(0.12 * strength), 0.28),
                (NSColor.white.withAlphaComponent(0.035 * strength), 0.66),
                (NSColor.white.withAlphaComponent(0.14 * strength), 1.0)
            ),
            from: NSPoint(x: bounds.midX, y: bounds.maxY),
            to: NSPoint(x: bounds.midX, y: bounds.minY)
        )
    }

    private func drawGlassRim(_ path: NSBezierPath, tint: NSColor) {
        stroke(
            path,
            color: adaptiveModuleOuterRim,
            width: 3.0
        )
        stroke(path, color: adaptiveModuleInnerRim, width: 1.3)
        stroke(
            path,
            color: adaptiveModuleInnerRim,
            width: 0.7
        )
    }

    private func drawGradient(
        in path: NSBezierPath,
        gradient: NSGradient?,
        from start: NSPoint,
        to end: NSPoint
    ) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        gradient?.draw(from: start, to: end, options: [])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
        color.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    private func drawReferencePlugOrBatteryIcon() {
        guard metrics.externalPower else {
            if let image = symbolImage(batterySymbol, pointSize: 72, color: .systemGreen) {
                drawSymbol(image, centeredAt: svgPoint(101, 278), maximumSize: 80, rotated: false)
            }
            return
        }

        let color = NSColor.systemOrange.withAlphaComponent(isDarkAppearance ? 0.92 : 0.82)
        color.setFill()
        NSBezierPath(roundedRect: svgRect(90, 242, 8, 24), xRadius: 4, yRadius: 4).fill()
        NSBezierPath(roundedRect: svgRect(107, 242, 8, 24), xRadius: 4, yRadius: 4).fill()

        let body = NSBezierPath()
        body.move(to: svgPoint(87, 259))
        body.line(to: svgPoint(118, 259))
        body.line(to: svgPoint(118, 278))
        body.curve(
            to: svgPoint(102.5, 296),
            controlPoint1: svgPoint(118, 288),
            controlPoint2: svgPoint(111, 296)
        )
        body.curve(
            to: svgPoint(87, 278),
            controlPoint1: svgPoint(94, 296),
            controlPoint2: svgPoint(87, 288)
        )
        body.close()
        body.fill()

        let tail = NSBezierPath()
        tail.move(to: svgPoint(99, 293))
        tail.line(to: svgPoint(106, 293))
        tail.line(to: svgPoint(106, 303))
        tail.curve(
            to: svgPoint(97, 317),
            controlPoint1: svgPoint(106, 310),
            controlPoint2: svgPoint(102, 314)
        )
        tail.line(to: svgPoint(93, 310))
        tail.curve(
            to: svgPoint(99, 302),
            controlPoint1: svgPoint(97, 308),
            controlPoint2: svgPoint(99, 306)
        )
        tail.close()
        tail.fill()
    }

    private func drawReferenceBatteryIcon() {
        let color = NSColor.systemGreen
        let outer = NSBezierPath(roundedRect: svgRect(606, 181, 67, 34), xRadius: 9, yRadius: 9)
        stroke(outer, color: color, width: 3.5)

        let inner = NSBezierPath(roundedRect: svgRect(612, 187, 51, 22), xRadius: 5, yRadius: 5)
        color.withAlphaComponent(0.72).setFill()
        inner.fill()
        stroke(inner, color: color, width: 1.4)

        let terminal = NSBezierPath()
        terminal.move(to: svgPoint(673, 192))
        terminal.line(to: svgPoint(676, 192))
        terminal.curve(
            to: svgPoint(681, 198),
            controlPoint1: svgPoint(679, 192),
            controlPoint2: svgPoint(681, 194)
        )
        terminal.curve(
            to: svgPoint(676, 204),
            controlPoint1: svgPoint(681, 202),
            controlPoint2: svgPoint(679, 204)
        )
        terminal.line(to: svgPoint(673, 204))
        terminal.close()
        color.setFill()
        terminal.fill()
    }

    private func drawReferenceLaptopIcon() {
        let color = NSColor.systemBlue
        let screen = NSBezierPath(roundedRect: svgRect(615, 475, 52, 36), xRadius: 3, yRadius: 3)
        screen.lineWidth = 3.7
        color.setStroke()
        screen.stroke()

        let base = NSBezierPath()
        base.move(to: svgPoint(606, 516))
        base.line(to: svgPoint(676, 516))
        base.lineWidth = 3.7
        base.lineCapStyle = .round
        color.setStroke()
        base.stroke()
    }

    private func drawReferenceEndpointIcon(for name: String, slot: OutputSlot) {
        let center = endpointCenter(for: slot)
        let lower = name.lowercased()
        if lower.contains("display") || lower.contains("monitor") || lower.contains("显示器") {
            drawMonitorIcon(center: center)
        } else if lower.contains("ipad") || lower.contains("iphone") || lower.contains("chip") {
            drawChipIcon(center: center)
        } else if lower.contains("hub") || lower.contains("dock") || lower.contains("扩展坞") {
            drawMoreIcon(center: center)
        } else if slot == .bottom {
            drawMoreIcon(center: center)
        } else if let image = symbolImage(deviceSymbol(for: name), pointSize: 42, color: referenceNeutralIconColor) {
            drawSymbol(image, centeredAt: svgPoint(center.x, center.y), maximumSize: 42, rotated: false)
        }
    }

    private func drawChipIcon(center: NSPoint) {
        let color = referenceNeutralIconColor
        let outer = NSBezierPath(roundedRect: svgRect(center.x - 10, center.y - 11.5, 27, 27), xRadius: 2, yRadius: 2)
        let inner = NSBezierPath(roundedRect: svgRect(center.x - 4, center.y - 5.5, 15, 15), xRadius: 1, yRadius: 1)
        for path in [outer, inner] {
            path.lineWidth = 2.4
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        }

        let pins = NSBezierPath()
        for y in [-6.5, 2.0, 10.5] as [CGFloat] {
            pins.move(to: svgPoint(center.x - 15, center.y + y))
            pins.line(to: svgPoint(center.x - 10, center.y + y))
            pins.move(to: svgPoint(center.x + 17, center.y + y))
            pins.line(to: svgPoint(center.x + 22, center.y + y))
        }
        for x in [-5.0, 3.5, 12.0] as [CGFloat] {
            pins.move(to: svgPoint(center.x + x, center.y - 16.5))
            pins.line(to: svgPoint(center.x + x, center.y - 11.5))
            pins.move(to: svgPoint(center.x + x, center.y + 15.5))
            pins.line(to: svgPoint(center.x + x, center.y + 20.5))
        }
        pins.lineWidth = 2.4
        pins.lineCapStyle = .round
        color.setStroke()
        pins.stroke()
    }

    private func drawMonitorIcon(center: NSPoint) {
        let color = referenceNeutralIconColor
        let screen = NSBezierPath(roundedRect: svgRect(center.x - 20.5, center.y - 18, 41, 27), xRadius: 2, yRadius: 2)
        screen.lineWidth = 2.5
        color.setStroke()
        screen.stroke()

        let stand = NSBezierPath()
        stand.move(to: svgPoint(center.x, center.y + 9))
        stand.line(to: svgPoint(center.x, center.y + 15))
        stand.move(to: svgPoint(center.x - 9.5, center.y + 15))
        stand.line(to: svgPoint(center.x + 9.5, center.y + 15))
        stand.lineWidth = 2.5
        stand.lineCapStyle = .round
        color.setStroke()
        stand.stroke()
    }

    private func drawMoreIcon(center: NSPoint) {
        referenceNeutralIconColor.setFill()
        for x in [-13, 0, 13] as [CGFloat] {
            NSBezierPath(ovalIn: svgRect(center.x + x - 2.8, center.y - 2.8, 5.6, 5.6)).fill()
        }
    }

    private func outputSlots(for count: Int) -> [OutputSlot] {
        switch count {
        case 1: return [.middle]
        case 2: return [.top, .bottom]
        case 3...: return [.top, .middle, .bottom]
        default: return []
        }
    }

    private func endpointCenter(for slot: OutputSlot) -> NSPoint {
        switch slot {
        case .top: return NSPoint(x: 1185, y: 373.5)
        case .middle: return NSPoint(x: 1185, y: 501)
        case .bottom: return NSPoint(x: 1186, y: 624.5)
        }
    }

    private func outputSweepEndpoints(for slot: OutputSlot) -> (NSPoint, NSPoint) {
        switch slot {
        case .top: return (svgPoint(812, 464), svgPoint(1102, 373))
        case .middle: return (svgPoint(812, 500), svgPoint(1096, 500))
        case .bottom: return (svgPoint(812, 535), svgPoint(1102, 624))
        }
    }

    private func outputLabelPosition(for slot: OutputSlot) -> (x: CGFloat, y: CGFloat, size: CGFloat) {
        switch slot {
        case .top: return (912, 435, 43)
        case .middle: return (914, 515, 32)
        case .bottom: return (914, 591, 40)
        }
    }

    private func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private func drawCenteredDesignText(
        _ text: String,
        centerX: CGFloat,
        baselineY: CGFloat,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: roundedFont(size: size, weight: weight),
                .foregroundColor: color
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: centerX - width / 2,
            y: activeCanvas.height - baselineY
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawFlowLabels(outputs: [USBPowerFlow], centers: [CGFloat]) {
        for (index, output) in outputs.enumerated() {
            // Watt label sits in the open channel between the laptop card and
            // its icon-only endpoint card, aligned with the ribbon's start.
            let x = (structure.laptopCard.maxX + structure.outputX) / 2 - 20
            drawText(
                watts(output.watts),
                in: NSRect(x: x - 34, y: centers[index] - 8, width: 68, height: 16),
                font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                color: glassInk,
                alignment: .center,
                shadow: true
            )
        }
    }

    private func drawMainFlowLabel(_ value: String, centerY: CGFloat) {
        let x = (structure.source.maxX + structure.batteryCard.minX) / 2
        drawText(
            value,
            in: NSRect(x: x - 40, y: centerY - 9, width: 80, height: 18),
            font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
            color: glassInk,
            alignment: .center,
            shadow: true
        )
    }

    private func drawIconDestinationCard(
        _ rect: NSRect,
        symbol: String,
        symbolColor: NSColor,
        accessibilityLabel: String
    ) {
        drawGlassCardBackground(rect)
        let iconSize = min(22, rect.height * 0.72)
        if let image = symbolImage(symbol, pointSize: iconSize, color: symbolColor) {
            drawSymbol(
                image,
                centeredAt: NSPoint(x: rect.midX, y: rect.midY),
                maximumSize: iconSize,
                rotated: symbol == "powerplug.fill"
            )
        }
        _ = accessibilityLabel
    }

    private func drawRibbon(
        from start: NSPoint,
        to end: NSPoint,
        watts: Double,
        label: String?,
        sourceColor: NSColor,
        destinationColor: NSColor,
        startsNarrow: Bool = false,
        reversesFlow: Bool = false,
        animationPower: Double? = nil,
        startWidthOverride: CGFloat? = nil,
        maximumEndWidth: CGFloat? = nil,
        endWidthOverride: CGFloat? = nil,
        roundsDestination: Bool = false,
        gentleCurve: Bool = false
    ) {
        let width = Self.ribbonWidth(for: watts)
        guard width > 0 else { return }

        let startWidth = startWidthOverride
            ?? Self.ribbonStartWidth(for: watts, startsNarrow: startsNarrow)
        let endWidth = endWidthOverride ?? min(width, maximumEndWidth ?? width)
        let path = ribbonPath(
            from: start,
            to: end,
            startWidth: startWidth,
            endWidth: endWidth,
            roundsDestination: roundsDestination,
            gentleCurve: gentleCurve
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isDarkAppearance ? 0.38 : 0.34)
        shadow.shadowOffset = NSSize(width: 0, height: -2.5)
        shadow.shadowBlurRadius = 7
        shadow.set()
        NSColor.white.withAlphaComponent(isDarkAppearance ? 0.10 : 0.18).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let tintGradient = NSGradient(colorsAndLocations:
            (sourceColor.withAlphaComponent(isDarkAppearance ? 0.24 : 0.19), 0.0),
            (NSColor.white.withAlphaComponent(isDarkAppearance ? 0.09 : 0.16), 0.50),
            (destinationColor.withAlphaComponent(isDarkAppearance ? 0.20 : 0.16), 1.0)
        )
        tintGradient?.draw(
            from: NSPoint(x: start.x, y: path.bounds.midY),
            to: NSPoint(x: end.x, y: path.bounds.midY),
            options: []
        )
        let sheenGradient = NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(isDarkAppearance ? 0.30 : 0.42), 0.0),
            (appearanceInk.withAlphaComponent(isDarkAppearance ? 0.035 : 0.055), 0.56),
            (NSColor.white.withAlphaComponent(isDarkAppearance ? 0.08 : 0.16), 1.0)
        )
        sheenGradient?.draw(
            from: NSPoint(x: path.bounds.midX, y: path.bounds.maxY),
            to: NSPoint(x: path.bounds.midX, y: path.bounds.minY),
            options: []
        )
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(isDarkAppearance ? 0.30 : 0.24).setStroke()
        path.lineWidth = 1.0
        path.stroke()
        NSColor.white.withAlphaComponent(isDarkAppearance ? 0.55 : 0.80).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        drawEnergySweep(
            from: start,
            to: end,
            watts: watts,
            sourceColor: sourceColor,
            destinationColor: destinationColor,
            reversesFlow: reversesFlow,
            animationPower: animationPower,
            crossSection: max(startWidth, endWidth),
            clippedTo: path,
            followsGentleCurve: gentleCurve
        )

        if let label {
            let labelPosition: CGFloat = startsNarrow ? 0.72 : 0.5
            let point = cubicPoint(from: start, to: end, t: labelPosition)
            let horizontalSpan = abs(end.x - start.x)
            let labelWidth = min(startsNarrow ? 48 : 74, max(42, horizontalSpan - 12))
            drawText(
                label,
                in: NSRect(
                    x: point.x - labelWidth / 2,
                    y: point.y - (startsNarrow ? 7 : 8),
                    width: labelWidth,
                    height: startsNarrow ? 15 : 17
                ),
                font: .monospacedDigitSystemFont(ofSize: startsNarrow ? 9.5 : 11.5, weight: .semibold),
                color: glassInk,
                alignment: .center,
                shadow: true
            )
        }
    }

    /// Every style is clipped to the actual ribbon and uses one continuous
    /// phase, so the motion follows each curve without a visible reset jump.
    private func drawEnergySweep(
        from start: NSPoint,
        to end: NSPoint,
        watts: Double,
        sourceColor: NSColor,
        destinationColor: NSColor,
        reversesFlow: Bool,
        animationPower: Double?,
        crossSection: CGFloat? = nil,
        clippedTo ribbon: NSBezierPath,
        followsGentleCurve: Bool = false
    ) {
        let duration = Self.flowDuration(for: animationPower ?? watts)
        guard duration > 0, isAnimating || rendersPreviewAnimation else { return }

        var phase = CGFloat(animationElapsed / duration)
        phase = phase - floor(phase)
        let span = hypot(end.x - start.x, end.y - start.y)
        let section = max(1, crossSection ?? ribbon.bounds.height)
        let sweepWidth = min(span * 0.44, max(92, section * 0.82))

        _ = sourceColor
        _ = destinationColor

        NSGraphicsContext.saveGraphicsState()
        ribbon.addClip()

        switch animationStyle {
        case .softTide:
            drawSoftGreenTides(
                from: start,
                to: end,
                phase: phase,
                reversesFlow: reversesFlow,
                sweepWidth: sweepWidth,
                followsGentleCurve: followsGentleCurve
            )
        case .liquidDrops:
            drawLiquidGreenDrops(
                from: start,
                to: end,
                phase: phase,
                reversesFlow: reversesFlow,
                section: section,
                followsGentleCurve: followsGentleCurve
            )
        case .auroraPulse:
            drawGreenAuroraPulse(
                from: start,
                to: end,
                phase: phase,
                reversesFlow: reversesFlow,
                sweepWidth: sweepWidth,
                followsGentleCurve: followsGentleCurve
            )
        case .silkRibbon:
            drawGreenSilkRibbon(
                from: start,
                to: end,
                phase: phase,
                reversesFlow: reversesFlow,
                section: section,
                followsGentleCurve: followsGentleCurve
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSoftGreenTides(
        from start: NSPoint,
        to end: NSPoint,
        phase: CGFloat,
        reversesFlow: Bool,
        sweepWidth: CGFloat,
        followsGentleCurve: Bool
    ) {
        let green = NSColor.systemGreen
        for (index, stagger) in [CGFloat(0), CGFloat(0.5)].enumerated() {
            let progress = wrappedPhase(phase + stagger)
            let endpointFade = pow(max(0, sin(.pi * progress)), 0.72)
            let pathPhase = reversesFlow ? 1 - progress : progress
            let geometry = sweepGeometry(
                from: start,
                to: end,
                pathPhase: pathPhase,
                width: sweepWidth,
                followsGentleCurve: followsGentleCurve
            )
            let peak = (isDarkAppearance ? 0.40 : 0.24)
                * endpointFade
                * (index == 0 ? 1 : 0.72)
            let bandGradient = NSGradient(colorsAndLocations:
                (green.withAlphaComponent(0.00), 0.00),
                (green.withAlphaComponent(peak * 0.16), 0.16),
                (green.withAlphaComponent(peak), 0.54),
                (green.withAlphaComponent(peak * 0.46), 0.80),
                (green.withAlphaComponent(0.00), 1.00)
            )
            bandGradient?.draw(from: geometry.tail, to: geometry.head, options: [])
        }
    }

    private func drawLiquidGreenDrops(
        from start: NSPoint,
        to end: NSPoint,
        phase: CGFloat,
        reversesFlow: Bool,
        section: CGFloat,
        followsGentleCurve: Bool
    ) {
        let green = NSColor.systemGreen
        let dropLength = min(106, max(42, section * 0.68))
        let dropHeight = min(42, max(13, section * 0.28))
        for (index, stagger) in [CGFloat(0), 0.25, 0.5, 0.75].enumerated() {
            let progress = wrappedPhase(phase + stagger)
            let endpointFade = pow(max(0, sin(.pi * progress)), 0.62)
            let pathPhase = reversesFlow ? 1 - progress : progress
            let center = cubicPoint(
                from: start,
                to: end,
                t: pathPhase,
                gentleCurve: followsGentleCurve
            )
            let tangent = cubicTangent(
                from: start,
                to: end,
                t: pathPhase,
                gentleCurve: followsGentleCurve
            )
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: center.x, yBy: center.y)
            transform.rotate(byDegrees: atan2(tangent.y, tangent.x) * 180 / .pi)
            transform.concat()
            let scale = index.isMultiple(of: 2) ? CGFloat(1) : 0.78
            let rect = NSRect(
                x: -dropLength * scale / 2,
                y: -dropHeight * scale / 2,
                width: dropLength * scale,
                height: dropHeight * scale
            )
            let drop = NSBezierPath(
                roundedRect: rect,
                xRadius: rect.height / 2,
                yRadius: rect.height / 2
            )
            let shadow = NSShadow()
            shadow.shadowColor = green.withAlphaComponent(0.42 * endpointFade)
            shadow.shadowBlurRadius = 16
            shadow.shadowOffset = .zero
            shadow.set()
            let peak = (isDarkAppearance ? 0.74 : 0.54) * endpointFade
            NSGradient(colorsAndLocations:
                (green.withAlphaComponent(peak * 0.10), 0.00),
                (green.withAlphaComponent(peak * 0.68), 0.42),
                (green.withAlphaComponent(peak), 0.68),
                (green.withAlphaComponent(peak * 0.08), 1.00)
            )?.draw(in: drop, angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawGreenAuroraPulse(
        from start: NSPoint,
        to end: NSPoint,
        phase: CGFloat,
        reversesFlow: Bool,
        sweepWidth: CGFloat,
        followsGentleCurve: Bool
    ) {
        let green = NSColor.systemGreen
        let brightGreen = green.blended(withFraction: 0.28, of: .white) ?? green
        for stagger in [CGFloat(0), CGFloat(0.5)] {
            let progress = wrappedPhase(phase + stagger)
            let endpointFade = pow(max(0, sin(.pi * progress)), 0.66)
            let pathPhase = reversesFlow ? 1 - progress : progress
            let geometry = sweepGeometry(
                from: start,
                to: end,
                pathPhase: pathPhase,
                width: sweepWidth * 1.18,
                followsGentleCurve: followsGentleCurve
            )
            let outerPeak = (isDarkAppearance ? 0.28 : 0.16) * endpointFade
            NSGradient(colorsAndLocations:
                (green.withAlphaComponent(0), 0.00),
                (green.withAlphaComponent(outerPeak * 0.48), 0.24),
                (green.withAlphaComponent(outerPeak), 0.50),
                (green.withAlphaComponent(outerPeak * 0.42), 0.76),
                (green.withAlphaComponent(0), 1.00)
            )?.draw(from: geometry.tail, to: geometry.head, options: [])
            let core = sweepGeometry(
                from: start,
                to: end,
                pathPhase: pathPhase,
                width: sweepWidth * 0.34,
                followsGentleCurve: followsGentleCurve
            )
            let corePeak = (isDarkAppearance ? 0.66 : 0.42) * endpointFade
            NSGradient(colorsAndLocations:
                (brightGreen.withAlphaComponent(0), 0.00),
                (brightGreen.withAlphaComponent(corePeak * 0.24), 0.22),
                (brightGreen.withAlphaComponent(corePeak), 0.58),
                (brightGreen.withAlphaComponent(corePeak * 0.18), 0.84),
                (brightGreen.withAlphaComponent(0), 1.00)
            )?.draw(from: core.tail, to: core.head, options: [])
        }
    }

    private func drawGreenSilkRibbon(
        from start: NSPoint,
        to end: NSPoint,
        phase: CGFloat,
        reversesFlow: Bool,
        section: CGFloat,
        followsGentleCurve: Bool
    ) {
        let centerline = NSBezierPath()
        centerline.move(to: start)
        for sample in 1...48 {
            centerline.line(to: cubicPoint(
                from: start,
                to: end,
                t: CGFloat(sample) / 48,
                gentleCurve: followsGentleCurve
            ))
        }
        centerline.lineCapStyle = .round
        centerline.lineJoinStyle = .round
        let direction: CGFloat = reversesFlow ? 1 : -1
        let phaseOffset = direction * phase * 112
        let pattern = [CGFloat(28), CGFloat(84)]
        pattern.withUnsafeBufferPointer { buffer in
            centerline.setLineDash(buffer.baseAddress, count: buffer.count, phase: phaseOffset)
        }
        let green = NSColor.systemGreen
        let halo = NSShadow()
        halo.shadowColor = green.withAlphaComponent(isDarkAppearance ? 0.62 : 0.40)
        halo.shadowBlurRadius = 13
        halo.shadowOffset = .zero
        halo.set()
        stroke(
            centerline,
            color: green.withAlphaComponent(isDarkAppearance ? 0.30 : 0.20),
            width: min(15, max(5, section * 0.10))
        )
        stroke(
            centerline,
            color: green.withAlphaComponent(isDarkAppearance ? 0.88 : 0.68),
            width: min(6, max(2.2, section * 0.038))
        )
    }

    private func wrappedPhase(_ value: CGFloat) -> CGFloat {
        value - floor(value)
    }

    private func sweepGeometry(
        from start: NSPoint,
        to end: NSPoint,
        pathPhase: CGFloat,
        width: CGFloat,
        followsGentleCurve: Bool
    ) -> (tail: NSPoint, head: NSPoint) {
        let center = cubicPoint(
            from: start,
            to: end,
            t: pathPhase,
            gentleCurve: followsGentleCurve
        )
        let tangent = cubicTangent(
            from: start,
            to: end,
            t: pathPhase,
            gentleCurve: followsGentleCurve
        )
        let tangentLength = max(0.001, hypot(tangent.x, tangent.y))
        let unit = NSPoint(x: tangent.x / tangentLength, y: tangent.y / tangentLength)
        return (
            NSPoint(x: center.x - unit.x * width / 2, y: center.y - unit.y * width / 2),
            NSPoint(x: center.x + unit.x * width / 2, y: center.y + unit.y * width / 2)
        )
    }

    private func ribbonPath(
        from start: NSPoint,
        to end: NSPoint,
        startWidth: CGFloat,
        endWidth: CGFloat,
        roundsDestination: Bool,
        gentleCurve: Bool,
        roundsSource: Bool = false,
        roundsSourceTop: Bool? = nil,
        roundsSourceBottom: Bool? = nil,
        roundsDestinationTop: Bool? = nil,
        roundsDestinationBottom: Bool? = nil,
        maximumSourceRadius: CGFloat = Design.flowCornerRadius,
        maximumDestinationRadius: CGFloat = Design.flowCornerRadius
    ) -> NSBezierPath {
        let dx = end.x - start.x
        let controlOffset = gentleCurve
            ? max(18, abs(dx) * 0.16)
            : max(22, abs(dx) * 0.46)
        let roundsTopAtSource = roundsSourceTop ?? roundsSource
        let roundsBottomAtSource = roundsSourceBottom ?? roundsSource
        let roundsTopAtDestination = roundsDestinationTop ?? roundsDestination
        let roundsBottomAtDestination = roundsDestinationBottom ?? roundsDestination
        let sourceTopRadius = roundsTopAtSource
            ? min(maximumSourceRadius, startWidth / 2)
            : 0
        let sourceBottomRadius = roundsBottomAtSource
            ? min(maximumSourceRadius, startWidth / 2)
            : 0
        let destinationTopRadius = roundsTopAtDestination
            ? min(maximumDestinationRadius, endWidth / 2)
            : 0
        let destinationBottomRadius = roundsBottomAtDestination
            ? min(maximumDestinationRadius, endWidth / 2)
            : 0
        let startTopJoinX = start.x + sourceTopRadius
        let startBottomJoinX = start.x + sourceBottomRadius
        let endTopJoinX = end.x - destinationTopRadius
        let endBottomJoinX = end.x - destinationBottomRadius
        let startTop = NSPoint(x: startTopJoinX, y: start.y + startWidth / 2)
        let startBottom = NSPoint(x: startBottomJoinX, y: start.y - startWidth / 2)
        let endTop = NSPoint(x: endTopJoinX, y: end.y + endWidth / 2)
        let endBottom = NSPoint(x: endBottomJoinX, y: end.y - endWidth / 2)

        let path = NSBezierPath()
        path.move(to: startTop)
        path.curve(
            to: endTop,
            controlPoint1: NSPoint(x: startTopJoinX + controlOffset, y: startTop.y),
            controlPoint2: NSPoint(x: endTopJoinX - controlOffset, y: endTop.y)
        )
        if roundsTopAtDestination {
            path.curve(
                to: NSPoint(x: end.x, y: endTop.y - destinationTopRadius),
                controlPoint1: NSPoint(x: endTopJoinX + destinationTopRadius * 0.66, y: endTop.y),
                controlPoint2: NSPoint(x: end.x, y: endTop.y - destinationTopRadius * 0.34)
            )
        } else {
            path.line(to: NSPoint(x: end.x, y: endTop.y))
        }
        path.line(to: NSPoint(x: end.x, y: endBottom.y + destinationBottomRadius))
        if roundsBottomAtDestination {
            path.curve(
                to: endBottom,
                controlPoint1: NSPoint(x: end.x, y: endBottom.y + destinationBottomRadius * 0.34),
                controlPoint2: NSPoint(x: endBottomJoinX + destinationBottomRadius * 0.66, y: endBottom.y)
            )
        } else {
            path.line(to: endBottom)
        }
        path.curve(
            to: startBottom,
            controlPoint1: NSPoint(x: endBottomJoinX - controlOffset, y: endBottom.y),
            controlPoint2: NSPoint(x: startBottomJoinX + controlOffset, y: startBottom.y)
        )
        if roundsBottomAtSource {
            path.curve(
                to: NSPoint(x: start.x, y: startBottom.y + sourceBottomRadius),
                controlPoint1: NSPoint(
                    x: startBottomJoinX - sourceBottomRadius * 0.66,
                    y: startBottom.y
                ),
                controlPoint2: NSPoint(
                    x: start.x,
                    y: startBottom.y + sourceBottomRadius * 0.34
                )
            )
        } else {
            path.line(to: NSPoint(x: start.x, y: startBottom.y))
        }
        path.line(to: NSPoint(x: start.x, y: startTop.y - sourceTopRadius))
        if roundsTopAtSource {
            path.curve(
                to: startTop,
                controlPoint1: NSPoint(
                    x: start.x,
                    y: startTop.y - sourceTopRadius * 0.34
                ),
                controlPoint2: NSPoint(
                    x: startTopJoinX - sourceTopRadius * 0.66,
                    y: startTop.y
                )
            )
        }
        path.close()
        return path
    }

    /// Same silhouette as `ribbonPath`, but intentionally omits the vertical
    /// start cap. The shared outlet is drawn over this open side, so there is
    /// no hidden seam that can show through translucent liquid-glass fills.
    private func ribbonOpenOutlinePath(
        from start: NSPoint,
        to end: NSPoint,
        startWidth: CGFloat,
        endWidth: CGFloat,
        roundsDestination: Bool,
        gentleCurve: Bool
    ) -> NSBezierPath {
        let dx = end.x - start.x
        let controlOffset = gentleCurve
            ? max(18, abs(dx) * 0.16)
            : max(22, abs(dx) * 0.46)
        let capRadius = roundsDestination ? min(11, endWidth / 2) : 0
        let endJoinX = end.x - capRadius
        let startTop = NSPoint(x: start.x, y: start.y + startWidth / 2)
        let startBottom = NSPoint(x: start.x, y: start.y - startWidth / 2)
        let endTop = NSPoint(x: endJoinX, y: end.y + endWidth / 2)
        let endBottom = NSPoint(x: endJoinX, y: end.y - endWidth / 2)

        let path = NSBezierPath()
        path.move(to: startTop)
        path.curve(
            to: endTop,
            controlPoint1: NSPoint(x: start.x + controlOffset, y: startTop.y),
            controlPoint2: NSPoint(x: endJoinX - controlOffset, y: endTop.y)
        )
        if roundsDestination {
            path.curve(
                to: NSPoint(x: end.x, y: endTop.y - capRadius),
                controlPoint1: NSPoint(x: endJoinX + capRadius * 0.66, y: endTop.y),
                controlPoint2: NSPoint(x: end.x, y: endTop.y - capRadius * 0.34)
            )
            path.line(to: NSPoint(x: end.x, y: endBottom.y + capRadius))
            path.curve(
                to: endBottom,
                controlPoint1: NSPoint(x: end.x, y: endBottom.y + capRadius * 0.34),
                controlPoint2: NSPoint(x: endJoinX + capRadius * 0.66, y: endBottom.y)
            )
        } else {
            path.line(to: endBottom)
        }
        path.curve(
            to: startBottom,
            controlPoint1: NSPoint(x: endJoinX - controlOffset, y: endBottom.y),
            controlPoint2: NSPoint(x: start.x + controlOffset, y: startBottom.y)
        )
        return path
    }

    /// Draws only the outside rim of a sibling group. Inner edges are omitted
    /// completely: once the ribbons separate, the transparent gap itself is
    /// the divider and does not need a doubled gray border.
    private func ribbonSelectiveOutlinePath(
        from start: NSPoint,
        to end: NSPoint,
        startWidth: CGFloat,
        endWidth: CGFloat,
        roundsDestination: Bool,
        gentleCurve: Bool,
        omitsTopEdge: Bool,
        omitsBottomEdge: Bool,
        roundsSource: Bool = false,
        roundsSourceTop: Bool? = nil,
        roundsSourceBottom: Bool? = nil,
        roundsDestinationTop: Bool? = nil,
        roundsDestinationBottom: Bool? = nil,
        maximumSourceRadius: CGFloat = Design.flowCornerRadius,
        maximumDestinationRadius: CGFloat = Design.flowCornerRadius,
        drawsDestinationCap: Bool = true,
        drawsSourceCap: Bool = true
    ) -> NSBezierPath {
        let dx = end.x - start.x
        let controlOffset = gentleCurve
            ? max(18, abs(dx) * 0.16)
            : max(22, abs(dx) * 0.46)
        let roundsTopAtSource = roundsSourceTop ?? roundsSource
        let roundsBottomAtSource = roundsSourceBottom ?? roundsSource
        let roundsTopAtDestination = roundsDestinationTop ?? roundsDestination
        let roundsBottomAtDestination = roundsDestinationBottom ?? roundsDestination
        let sourceTopRadius = roundsTopAtSource
            ? min(maximumSourceRadius, startWidth / 2)
            : 0
        let sourceBottomRadius = roundsBottomAtSource
            ? min(maximumSourceRadius, startWidth / 2)
            : 0
        let destinationTopRadius = roundsTopAtDestination
            ? min(maximumDestinationRadius, endWidth / 2)
            : 0
        let destinationBottomRadius = roundsBottomAtDestination
            ? min(maximumDestinationRadius, endWidth / 2)
            : 0
        let startTopJoinX = start.x + sourceTopRadius
        let startBottomJoinX = start.x + sourceBottomRadius
        let endTopJoinX = end.x - destinationTopRadius
        let endBottomJoinX = end.x - destinationBottomRadius
        let startTop = NSPoint(x: startTopJoinX, y: start.y + startWidth / 2)
        let startBottom = NSPoint(x: startBottomJoinX, y: start.y - startWidth / 2)
        let endTop = NSPoint(x: endTopJoinX, y: end.y + endWidth / 2)
        let endBottom = NSPoint(x: endBottomJoinX, y: end.y - endWidth / 2)
        let path = NSBezierPath()
        if !omitsTopEdge {
            path.move(to: startTop)
            path.curve(
                to: endTop,
                controlPoint1: NSPoint(x: startTopJoinX + controlOffset, y: startTop.y),
                controlPoint2: NSPoint(x: endTopJoinX - controlOffset, y: endTop.y)
            )
        }

        if drawsDestinationCap {
            path.move(to: endTop)
            if roundsTopAtDestination {
                path.curve(
                    to: NSPoint(x: end.x, y: endTop.y - destinationTopRadius),
                    controlPoint1: NSPoint(x: endTopJoinX + destinationTopRadius * 0.66, y: endTop.y),
                    controlPoint2: NSPoint(x: end.x, y: endTop.y - destinationTopRadius * 0.34)
                )
            } else {
                path.line(to: NSPoint(x: end.x, y: endTop.y))
            }
            path.line(to: NSPoint(x: end.x, y: endBottom.y + destinationBottomRadius))
            if roundsBottomAtDestination {
                path.curve(
                    to: endBottom,
                    controlPoint1: NSPoint(x: end.x, y: endBottom.y + destinationBottomRadius * 0.34),
                    controlPoint2: NSPoint(x: endBottomJoinX + destinationBottomRadius * 0.66, y: endBottom.y)
                )
            } else {
                path.line(to: endBottom)
            }
        }
        if !omitsBottomEdge {
            path.move(to: endBottom)
            path.curve(
                to: startBottom,
                controlPoint1: NSPoint(x: endBottomJoinX - controlOffset, y: endBottom.y),
                controlPoint2: NSPoint(x: startBottomJoinX + controlOffset, y: startBottom.y)
            )
            if drawsSourceCap && !omitsTopEdge {
                if roundsBottomAtSource {
                    path.curve(
                        to: NSPoint(x: start.x, y: startBottom.y + sourceBottomRadius),
                        controlPoint1: NSPoint(
                            x: startBottomJoinX - sourceBottomRadius * 0.66,
                            y: startBottom.y
                        ),
                        controlPoint2: NSPoint(
                            x: start.x,
                            y: startBottom.y + sourceBottomRadius * 0.34
                        )
                    )
                } else {
                    path.line(to: NSPoint(x: start.x, y: startBottom.y))
                }
                path.line(to: NSPoint(x: start.x, y: startTop.y - sourceTopRadius))
                if roundsTopAtSource {
                    path.curve(
                        to: startTop,
                        controlPoint1: NSPoint(
                            x: start.x,
                            y: startTop.y - sourceTopRadius * 0.34
                        ),
                        controlPoint2: NSPoint(
                            x: startTopJoinX - sourceTopRadius * 0.66,
                            y: startTop.y
                        )
                    )
                }
            }
        }
        return path
    }

    private func centerPath(from start: NSPoint, to end: NSPoint) -> NSBezierPath {
        let controls = centerControls(from: start, to: end)
        let path = NSBezierPath()
        path.move(to: start)
        path.curve(to: end, controlPoint1: controls.0, controlPoint2: controls.1)
        return path
    }

    private func centerControls(
        from start: NSPoint,
        to end: NSPoint,
        gentleCurve: Bool = false
    ) -> (NSPoint, NSPoint) {
        let controlOffset = gentleCurve
            ? max(18, abs(end.x - start.x) * 0.16)
            : max(22, abs(end.x - start.x) * 0.46)
        return (
            NSPoint(x: start.x + controlOffset, y: start.y),
            NSPoint(x: end.x - controlOffset, y: end.y)
        )
    }

    private func cubicPoint(
        from start: NSPoint,
        to end: NSPoint,
        t: CGFloat,
        gentleCurve: Bool = false
    ) -> NSPoint {
        let controls = centerControls(from: start, to: end, gentleCurve: gentleCurve)
        let u = 1 - t
        return NSPoint(
            x: u * u * u * start.x
                + 3 * u * u * t * controls.0.x
                + 3 * u * t * t * controls.1.x
                + t * t * t * end.x,
            y: u * u * u * start.y
                + 3 * u * u * t * controls.0.y
                + 3 * u * t * t * controls.1.y
                + t * t * t * end.y
        )
    }

    private func cubicTangent(
        from start: NSPoint,
        to end: NSPoint,
        t: CGFloat,
        gentleCurve: Bool = false
    ) -> NSPoint {
        let controls = centerControls(from: start, to: end, gentleCurve: gentleCurve)
        let u = 1 - t
        return NSPoint(
            x: 3 * u * u * (controls.0.x - start.x)
                + 6 * u * t * (controls.1.x - controls.0.x)
                + 3 * t * t * (end.x - controls.1.x),
            y: 3 * u * u * (controls.0.y - start.y)
                + 6 * u * t * (controls.1.y - controls.0.y)
                + 3 * t * t * (end.y - controls.1.y)
        )
    }

    private func drawSourceCard(
        _ rect: NSRect,
        symbol: String,
        symbolColor: NSColor,
        value: String,
        accessibilityLabel: String
    ) {
        drawGlassCardBackground(rect)

        let iconSize: CGFloat = min(26, rect.height * 0.34)
        if let image = symbolImage(symbol, pointSize: iconSize, color: symbolColor) {
            drawSymbol(
                image,
                centeredAt: NSPoint(x: rect.midX, y: rect.midY + iconSize * 0.65),
                maximumSize: iconSize,
                rotated: symbol == "powerplug.fill"
            )
        }

        drawText(
            value,
            in: NSRect(x: rect.minX + 1, y: rect.midY - 20, width: rect.width - 2, height: 16),
            font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
            color: glassInk,
            alignment: .center,
            shadow: true
        )

        _ = accessibilityLabel
    }

    private func drawGlassCardBackground(_ rect: NSRect) {
        let radius = min(10, rect.height * 0.30)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isDarkAppearance ? 0.40 : 0.36)
        shadow.shadowOffset = NSSize(width: 0, height: -2.5)
        shadow.shadowBlurRadius = 7
        shadow.set()
        adaptiveModuleSurfaceBase.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let gradient = NSGradient(colorsAndLocations:
            (adaptiveModuleSurfaceTop, 0.0),
            (adaptiveModuleSurfaceBase, 0.52),
            (adaptiveModuleSurfaceBottom, 1.0)
        )
        gradient?.draw(in: rect, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        adaptiveModuleOuterRim.setStroke()
        path.lineWidth = 1.0
        path.stroke()
        adaptiveModuleInnerRim.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private var sourceSymbol: String {
        metrics.externalPower ? "powerplug.fill" : batterySymbol
    }

    private var sourceValue: String {
        if metrics.externalPower {
            if let limit = metrics.adapterLimitWatts { return String(format: "%.0f W", limit) }
            return compactWatts(metrics.inputWatts ?? metrics.sourceWatts)
        }
        return compactWatts(positive(metrics.systemWatts ?? metrics.sourceWatts))
    }

    private var batterySymbol: String {
        guard let percent = metrics.batteryPercent else { return "battery.50percent" }
        switch percent {
        case 76...: return "battery.100percent"
        case 51...: return "battery.75percent"
        case 26...: return "battery.50percent"
        default: return "battery.25percent"
        }
    }

    private var batteryAccessibilityLabel: String {
        guard let power = metrics.batteryWatts else { return "电池功率未识别" }
        if power > Self.outputThresholdWatts {
            return "电池充电 \(watts(abs(power)))"
        }
        if power < -Self.outputThresholdWatts {
            return "电池放电 \(watts(abs(power)))"
        }
        return "电池保持 \(watts(abs(power)))"
    }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var appearanceInk: NSColor {
        isDarkAppearance ? .white : .black
    }

    /// AlDente-style monochrome foreground tokens. The containing view stays
    /// transparent; cards, ribbons, labels, and symbols switch together so
    /// light mode reads as white glass with black ink and dark mode as smoked
    /// glass with white ink.
    private var adaptiveModuleInk: NSColor {
        isDarkAppearance
            ? NSColor.white.withAlphaComponent(0.94)
            : NSColor.black.withAlphaComponent(0.86)
    }

    private var adaptiveModuleSurfaceTop: NSColor {
        NSColor.white.withAlphaComponent(isDarkAppearance ? 0.27 : 0.94)
    }

    private var adaptiveModuleSurfaceBase: NSColor {
        NSColor.white.withAlphaComponent(isDarkAppearance ? 0.17 : 0.86)
    }

    private var adaptiveModuleSurfaceBottom: NSColor {
        NSColor.white.withAlphaComponent(isDarkAppearance ? 0.12 : 0.76)
    }

    private var adaptiveModuleOuterRim: NSColor {
        isDarkAppearance
            ? NSColor.black.withAlphaComponent(0.42)
            : NSColor.black.withAlphaComponent(0.16)
    }

    private var adaptiveModuleInnerRim: NSColor {
        NSColor.white.withAlphaComponent(isDarkAppearance ? 0.24 : 0.82)
    }

    private var glassInk: NSColor {
        adaptiveModuleInk
    }

    private var referenceTextColor: NSColor {
        adaptiveModuleInk
    }

    private var referenceNeutralIconColor: NSColor {
        adaptiveModuleInk
    }

    private var compactTextColor: NSColor {
        adaptiveModuleInk
    }

    private func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > Self.outputThresholdWatts else { return nil }
        return value
    }

    private func outputCenterYs(count: Int, around centerY: CGFloat) -> [CGFloat] {
        switch count {
        case 1: return [centerY]
        case 2: return [min(structure.size.height - 16, centerY + 28), max(16, centerY - 28)]
        case 3: return [centerY + 38, centerY, centerY - 38]
        default: return []
        }
    }

    /// Packs attachment centers from top to bottom, preserving a real gap at
    /// the shared node edge before the ribbons begin to diverge.
    private func packedAttachmentCenters(
        widths: [CGFloat],
        around centerY: CGFloat,
        gap: CGFloat
    ) -> [CGFloat] {
        guard !widths.isEmpty else { return [] }
        let totalHeight = widths.reduce(0, +) + CGFloat(widths.count - 1) * gap
        var cursor = centerY + totalHeight / 2
        return widths.map { width in
            let center = cursor - width / 2
            cursor -= width + gap
            return center
        }
    }

    /// Preserves watt-proportional slot ratios while guaranteeing that all
    /// active slots and their gaps fit on the node's usable straight edge.
    private func fittedAttachmentWidths(
        _ widths: [CGFloat],
        within maximumTotalHeight: CGFloat,
        gap: CGFloat
    ) -> [CGFloat] {
        guard !widths.isEmpty else { return [] }
        let gapTotal = CGFloat(widths.count - 1) * gap
        let available = max(CGFloat(widths.count), maximumTotalHeight - gapTotal)
        let total = widths.reduce(0, +)
        guard total > available, total > 0 else { return widths }
        let scale = available / total
        return widths.map { $0 * scale }
    }

    /// The ribbon terminates on the straight portion of a rounded card edge,
    /// avoiding the exposed square seam that appears when it reaches a corner.
    private func straightEdgeHeight(of rect: NSRect) -> CGFloat {
        let radius = min(10, rect.height * 0.30)
        return max(1, rect.height - radius * 2)
    }

    private func deviceSymbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("cpu") || lower.contains("芯片") {
            return "cpu"
        }
        if lower.contains("gpu") { return "square.3.layers.3d.down.right" }
        if lower.contains("其他硬件") { return "memorychip" }
        if lower.contains("进程") { return "app.fill" }
        if lower.contains("ipad") { return "ipad" }
        if lower.contains("iphone") { return "iphone" }
        if lower.contains("display") || lower.contains("monitor") || lower.contains("显示器") { return "display" }
        if lower.contains("watch") { return "applewatch" }
        if lower.contains("airpods") || lower.contains("耳机") { return "airpods" }
        if lower.contains("hub") || lower.contains("dock") || lower.contains("扩展坞") { return "cable.connector" }
        return "ellipsis"
    }

    private func deviceColor(for name: String) -> NSColor {
        let lower = name.lowercased()
        if lower.contains("cpu") || lower.contains("芯片") {
            return .systemOrange
        }
        if lower.contains("gpu") {
            return .systemPurple
        }
        if lower.contains("其他硬件") {
            return .systemIndigo
        }
        if lower.contains("进程") {
            return .systemTeal
        }
        if lower.contains("ipad") || lower.contains("iphone") {
            return .systemGreen
        }
        if lower.contains("display") || lower.contains("monitor") || lower.contains("显示器") {
            return .systemBlue
        }
        if lower.contains("airpods") || lower.contains("耳机") {
            return .systemPink
        }
        return .systemTeal
    }

    private func symbolImage(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color.withAlphaComponent(0.88)))
        return image.withSymbolConfiguration(configuration)
    }

    private func drawSymbol(
        _ image: NSImage,
        centeredAt center: NSPoint,
        maximumSize: CGFloat,
        rotated: Bool
    ) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let fit = min(maximumSize / imageSize.width, maximumSize / imageSize.height)
        let size = NSSize(width: imageSize.width * fit, height: imageSize.height * fit)

        NSGraphicsContext.saveGraphicsState()
        if rotated {
            let transform = NSAffineTransform()
            transform.translateX(by: center.x, yBy: center.y)
            transform.rotate(byDegrees: 90)
            transform.concat()
            image.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        } else {
            image.draw(
                in: NSRect(
                    x: center.x - size.width / 2,
                    y: center.y - size.height / 2,
                    width: size.width,
                    height: size.height
                )
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-- W" }
        if value >= 100 { return String(format: "%.0f W", value) }
        if value >= 10 { return String(format: "%.1f W", value) }
        if value > 0, value < 0.1 { return String(format: "%.3f W", value) }
        return String(format: "%.2f W", value)
    }

    private func compactWatts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-- W" }
        if value >= 10 { return String(format: "%.0f W", value) }
        return String(format: "%.1f W", value)
    }

    private func compactBranchWatts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-- W" }
        return String(format: "%.2f W", value)
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment,
        shadow: Bool
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        if shadow {
            let textShadow = NSShadow()
            textShadow.shadowColor = (isDarkAppearance ? NSColor.black : NSColor.white)
                .withAlphaComponent(isDarkAppearance ? 0.72 : 0.92)
            textShadow.shadowOffset = NSSize(width: 0, height: -0.7)
            textShadow.shadowBlurRadius = 2.2
            attributes[.shadow] = textShadow
        }
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func updateAccessibilitySummary() {
        let battery = "，\(batteryAccessibilityLabel)"
        let devices = Self.displayedOutputs(for: metrics)
            .map { "\($0.name) \(watts($0.watts))" }
            .joined(separator: "，")
        let outputSummary = devices.isEmpty ? "，没有第三层功耗项" : "，第三层功耗：\(devices)"
        setAccessibilityLabel("电源流图。Mac 整机 \(watts(metrics.systemWatts))\(battery)\(outputSummary)")
    }
}
