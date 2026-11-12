import AppKit
import CoreAudio
import Network

extension Process {
    static func runRestartControlCenter() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["ControlCenter"]
        try? task.run()
    }
}

/// DuoBar-inspired compact glyph. Geometry reference: Mikeli7666/DuoBar (MIT).
/// Only the menu-bar image is replaced; NSStatusItem keeps its existing menu.
@MainActor
final class DuoMenuIcon {
    private enum DefaultsKey {
        static let percentStyle = "duoIconPercentStyle.v1"   // 0=off, 1=trailing
        static let hideSystemBattery = "hideSystemBatteryIcon.v1"
    }

    private let monitor = NWPathMonitor()
    private var networkSymbol = "network.slash"
    private var battery: Int?
    private var charging = false
    private var lastKey = ""
    private weak var button: NSStatusBarButton?

    var percentStyle: PercentStyle {
        let raw = UserDefaults.standard.integer(forKey: DefaultsKey.percentStyle)
        return raw == 1 ? .trailing : .none
    }

    init(button: NSStatusBarButton) {
        self.button = button
        Self.applySystemBatteryVisibility()
        monitor.pathUpdateHandler = { [weak self] path in
            let symbol = path.status != .satisfied ? "network.slash"
                : path.usesInterfaceType(.wiredEthernet) ? "cable.connector"
                : path.usesInterfaceType(.wifi) ? "wifi" : "network"
            Task { @MainActor [weak self] in
                self?.networkSymbol = symbol
                self?.refresh()
            }
        }
        monitor.start(queue: DispatchQueue(label: "barcontrol.menu-network"))
        refresh()
    }

    func update(battery: Int?, charging: Bool) {
        self.battery = battery
        self.charging = charging
        refresh()
    }

    /// 设置窗口改动样式后调用：强制下一帧重绘。
    func reloadStyle() {
        lastKey = ""
        refresh()
    }

    private func refresh() {
        let volume = Self.outputVolume()
        let key = "\(battery ?? -1)/\(charging)/\(networkSymbol)/\(volume.map { Int($0 * 100) } ?? -1)/\(percentStyle.hashValue)"
        guard key != lastKey else { return }
        lastKey = key
        button?.image = Self.image(battery: battery, charging: charging,
                                   networkSymbol: networkSymbol, volume: volume,
                                   percentStyle: percentStyle)
        button?.setAccessibilityLabel("Bar Control，电量 \(battery.map { "\($0)%" } ?? "未知")，\(charging ? "充电中" : "未充电")")
    }

    static func illuminatedDots(volume: Double?) -> Int {
        guard let volume, volume.isFinite else { return 0 }
        return Int(ceil(min(1, max(0, volume)) * 4))
    }

    enum PercentStyle { case none, trailing, inside }

    /// 打开 Bar Control 时隐藏系统自带电量图标；关闭该设置时恢复。
    static func applySystemBatteryVisibility() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: DefaultsKey.hideSystemBattery) == nil {
            defaults.set(true, forKey: DefaultsKey.hideSystemBattery)
        }
        let hide = defaults.bool(forKey: DefaultsKey.hideSystemBattery)
        let current = defaults.object(forKey: "NSStatusItem VisibleCC Battery") as? Int
        if hide {
            if current != 0 {
                defaults.set(false, forKey: "NSStatusItem VisibleCC Battery")
                Process.runRestartControlCenter()
            }
        } else if current == 0 {
            defaults.set(true, forKey: "NSStatusItem VisibleCC Battery")
            Process.runRestartControlCenter()
        }
    }

    /// 效果图/预览用：同一套绘制逻辑，可切换百分比样式并指定电量。
    static func previewImage(battery: Int?, charging: Bool, networkSymbol: String,
                             volume: Double?, style: PercentStyle) -> NSImage {
        image(battery: battery, charging: charging, networkSymbol: networkSymbol,
              volume: volume, percentStyle: style)
    }

    static func image(battery: Int?, charging: Bool, networkSymbol: String, volume: Double?,
                      percentStyle: PercentStyle = .none) -> NSImage {
        // Legacy inside style also uses the trailing slot, keeping the ring free of text/bolt.
        let percentStyle: PercentStyle = percentStyle == .inside ? .trailing : percentStyle
        let percentFont = NSFont.monospacedDigitSystemFont(
            ofSize: percentStyle == .inside ? 8.5 : 10.5,
            weight: .semibold
        )
        let percentText: NSString? = {
            guard let battery, percentStyle != .none else { return nil }
            return "\(battery)" as NSString
        }()
        let percentWidth = percentText?.size(withAttributes: [.font: percentFont]).width ?? 0
        // 三位数（100）需要更宽的位置，否则会和圆环/闪电重叠。
        let width: CGFloat = percentStyle == .trailing
            ? max(44, 29 + percentWidth + (charging ? 8 : 0) + 3)
            : (charging ? 39 : 30)
        let image = NSImage(size: NSSize(width: width, height: 22))
        image.lockFocus()
        let ringCenterX: CGFloat = 14.5
        let center = NSPoint(x: ringCenterX, y: 11)
        func arc(_ fraction: CGFloat, alpha: CGFloat) {
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: 10.2, startAngle: 210,
                           endAngle: 210 - 240 * fraction, clockwise: true)
            path.lineWidth = 2
            path.lineCapStyle = .round
            NSColor.black.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
        arc(1, alpha: 0.25)
        if let battery, battery > 0 { arc(CGFloat(min(100, max(0, battery))) / 100, alpha: 1) }
        let symbolTopY: CGFloat = percentStyle == .inside ? 12.6 : 6.4
        let symbolConfig = NSImage.SymbolConfiguration(
            pointSize: percentStyle == .inside ? 8.5 : 12.5, weight: .semibold)
        if let symbol = NSImage(systemSymbolName: networkSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) {
            symbol.draw(in: NSRect(x: 7.4, y: symbolTopY, width: 14.2, height: 11.2))
        }
        let dotsY: CGFloat = percentStyle == .inside ? 2.2 : 2.6
        let dots = illuminatedDots(volume: volume)
        for index in 0..<4 {
            NSColor.black.withAlphaComponent(index < dots ? 1 : 0.25).setFill()
            NSBezierPath(ovalIn: NSRect(x: 6.6 + CGFloat(index) * 4.15, y: dotsY, width: 2.5, height: 2.5)).fill()
        }
        if let percentText, percentStyle != .none {
            let attrs: [NSAttributedString.Key: Any] = [.font: percentFont, .foregroundColor: NSColor.black]
            let size = percentText.size(withAttributes: attrs)
            let origin: NSPoint
            switch percentStyle {
            case .none:
                origin = .zero
            case .trailing:
                origin = NSPoint(x: 29, y: (22 - size.height) / 2)
            case .inside:
                origin = NSPoint(x: (30 - size.width) / 2, y: 7.9)
            }
            percentText.draw(at: origin, withAttributes: attrs)
        }
        // Put the charge indicator just after the digits; never overlay the
        // Wi-Fi ring. The image width above reserves this final slot.
        if charging,
           let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
            let x = percentText == nil || percentStyle == .none ? 30 : width - 8
            bolt.draw(in: NSRect(x: x, y: 6, width: 6, height: 10))
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// Some HDMI/USB outputs have no software volume. Unknown stays unlit.
    private static func outputVolume() -> Double? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                        &size, &device) == noErr, device != 0 else { return nil }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr, muted != 0 { return 0 }
        var values: [Double] = []
        for element: UInt32 in [0, 1, 2] {
            var value: Float32 = 0
            size = UInt32(MemoryLayout<Float32>.size)
            address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
               value.isFinite { values.append(Double(value)) }
            if element == 0, !values.isEmpty { break }
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
