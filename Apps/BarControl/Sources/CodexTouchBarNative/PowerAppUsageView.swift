import AppKit
import Darwin

/// Small app icons + names, following the battery menu's compact list layout.
/// Values remain kernel billed-energy estimates, not Apple's Energy Impact score.
@MainActor
final class PowerAppUsageView: NSView {
    private let title = NSTextField(labelWithString: "高功耗应用")
    private let empty = NSTextField(labelWithString: "暂无耗能数据")
    private let rows: [(NSImageView, NSTextField, NSTextField)] = (0..<3).map { _ in
        (NSImageView(), NSTextField(labelWithString: ""), NSTextField(labelWithString: ""))
    }
    private let icons = NSCache<NSString, NSImage>()
    private var rowCount = 0
    /// EMA 平滑后的每应用功耗，避免 1 W 门槛附近来回跳。
    private var smoothed: [String: (name: String, url: URL?, watts: Double)] = [:]
    /// 展示节流：短于这个间隔的更新直接丢弃，菜单里的列表不会逐秒跳动。
    var lastDisplayAt = Date.distantPast
    /// 是否曾拿到过有效样本（用于区分“还没采到”与“都没超门槛”）。
    private var hasEverHadSamples = false
    /// 上一次实际显示的条目，用于迟滞判断。
    private var listedKeys: [String] = []
    /// 测试钩子：当前平滑表中的进程/应用名。
    var testHookTrackedNames: [String] { smoothed.values.map(\.name) }
    nonisolated static let displayInterval: TimeInterval = 5
    nonisolated static let minContentHeight: CGFloat = 20
    nonisolated static let rowHeight: CGFloat = 22
    var contentHeight: CGFloat {
        rowCount == 0 ? Self.minContentHeight
            : Self.minContentHeight + CGFloat(rowCount) * Self.rowHeight
    }
    nonisolated static let highPowerThresholdWatts = 0.20
    /// 迟滞：已在列表里的应用跌破 0.10 W 才移除，新应用要超过 0.20 W 才进入。
    nonisolated static let highPowerExitWatts = 0.10
    nonisolated static let highPowerEnterWatts = 0.20
    nonisolated static let smoothingFactor = 0.4

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(title)
        addSubview(empty)
        for (icon, name, value) in rows {
            addSubview(icon); addSubview(name); addSubview(value)
        }
        title.font = .systemFont(ofSize: 10, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.toolTip = "同一应用合并后，估算功耗超过 0.2 W 才显示，按功耗排序取前三项。这是本应用的门槛，并非系统电池菜单的高耗能判定。"
        empty.font = .systemFont(ofSize: 11)
        empty.textColor = .tertiaryLabelColor
        for (icon, name, value) in rows {
            icon.imageScaling = .scaleProportionallyDown
            name.font = .systemFont(ofSize: 11)
            name.textColor = .labelColor
            name.lineBreakMode = .byTruncatingTail
            value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            value.textColor = .secondaryLabelColor
            value.alignment = .right
        }
        update(samples: [])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func appURL(executablePath: String) -> URL? {
        // Use the outer application, not an embedded helper's .app bundle.
        let pieces = (executablePath as NSString).pathComponents
        guard pieces.first == "/", let end = pieces.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(pieces[...end])))
    }

    private func application(for sample: ProcessPowerSample, running: [NSRunningApplication]) -> URL? {
        if let pid = sample.pid, pid > 0 {
            var bytes = [CChar](repeating: 0, count: 4096)
            let count = bytes.count
            if proc_pidpath(pid, &bytes, UInt32(count)) > 0 {
                let path = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                if let url = Self.appURL(executablePath: String(decoding: path, as: UTF8.self)) { return url }
            }
            return NSRunningApplication(processIdentifier: pid)?.bundleURL
        }
        // Fixtures or old samplers without PID: only accept an unambiguous exact match.
        let matches = running.filter { $0.localizedName == sample.name || $0.executableURL?.lastPathComponent == sample.name }
        return matches.count == 1 ? matches.first?.bundleURL : nil
    }

    /// 参考系统电池菜单：高耗能应用不是每次采样都换列表，而是以较低频率刷新。
    /// 这里改为至少间隔 5 秒才更新一次显示。
    func update(samples: [ProcessPowerSample], ignoreThrottle: Bool = false) {
        let now = Date()
        // 注意：不能用 defer 刷新时间戳——被节流丢弃的调用若也刷新，
        // 按 2 秒周期喂数据时会永远达不到 5 秒间隔，列表永远不更新。
        guard ignoreThrottle || now.timeIntervalSince(lastDisplayAt) >= Self.displayInterval else { return }
        lastDisplayAt = now
        let running = NSWorkspace.shared.runningApplications
        var groups: [String: (name: String, watts: Double, url: URL?)] = [:]
        for sample in samples where sample.billedWatts.isFinite && sample.billedWatts > 0 {
            let url = application(for: sample, running: running)
            let key = url?.path ?? "process:\(sample.name)"
            let name = url.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
                ?? url?.deletingPathExtension().lastPathComponent ?? sample.name
            let previous = groups[key]?.watts ?? 0
            groups[key] = (name, previous + sample.billedWatts, url)
        }
        let hadSamples = !groups.isEmpty
        if hadSamples { hasEverHadSamples = true }

        // 指数平滑：新值占 40%，旧值按 60% 衰减；本次没出现的应用自然衰减。
        var next: [String: (name: String, url: URL?, watts: Double)] = [:]
        for (key, value) in smoothed {
            let decayed = value.watts * (1 - Self.smoothingFactor)
            next[key] = (value.name, value.url, decayed)
        }
        for (key, value) in groups {
            // 首次出现直接用真实值，避免进入列表要等两三帧。
            let smoothedWatts = smoothed[key].map {
                $0.watts + (value.watts - $0.watts) * Self.smoothingFactor
            } ?? value.watts
            next[key] = (value.name, value.url, smoothedWatts)
        }
        next = next.filter { $0.value.watts > 0.05 }
        smoothed = next

        // 迟滞：既有条目用较低退出阈值，新条目用较高进入阈值。
        let previousKeys = Set(listedKeys)
        var candidates: [(String, (name: String, url: URL?, watts: Double))] = []
        for (key, value) in smoothed {
            let alreadyListed = previousKeys.contains(key)
            let threshold = alreadyListed ? Self.highPowerExitWatts : Self.highPowerEnterWatts
            if value.watts > threshold {
                candidates.append((key, value))
            }
        }
        candidates.sort { left, right in
            if left.1.watts == right.1.watts { return left.1.name < right.1.name }
            return left.1.watts > right.1.watts
        }
        let top = candidates.prefix(3)
        listedKeys = top.map { $0.0 }
        rowCount = top.count
        title.isHidden = rowCount == 0
        // 采样偶尔会整帧为空（首帧或增量未就绪），此时保留上一次结果，避免一闪一闪。
        empty.isHidden = rowCount > 0
        if rowCount == 0 {
            // 有采样但都低于阈值 ≠ 没有数据；只有真正拿不到进程样本才显示“暂无耗能数据”。
            empty.stringValue = hasEverHadSamples ? "暂无高功耗应用" : "暂无耗能数据"
        }
        for (index, entry) in top.enumerated() {
            let (icon, label, value) = rows[index]
            if let url = entry.1.url {
                let key = url.path as NSString
                let image = icons.object(forKey: key) ?? NSWorkspace.shared.icon(forFile: url.path)
                icons.setObject(image, forKey: key)
                icon.image = image
                icon.contentTintColor = nil
            } else {
                let gear = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "系统进程")
                gear?.isTemplate = true
                icon.image = gear
                icon.contentTintColor = NSColor.secondaryLabelColor
            }
            icon.setAccessibilityLabel(entry.1.name)
            label.stringValue = entry.1.name
            label.toolTip = entry.1.url?.path ?? "系统进程：\(entry.1.name)"
            value.stringValue = String(format: "≈ %.2f W", entry.1.watts)
        }
        for (index, row) in rows.enumerated() {
            row.0.isHidden = index >= rowCount
            row.1.isHidden = index >= rowCount
            row.2.isHidden = index >= rowCount
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 16)
        empty.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 18)
        for (index, row) in rows.enumerated() {
            let y = Self.minContentHeight + CGFloat(index) * Self.rowHeight
            row.0.frame = NSRect(x: 0, y: y, width: 16, height: 16)
            row.1.frame = NSRect(x: 24, y: y - 1, width: max(0, bounds.width - 100), height: 18)
            row.2.frame = NSRect(x: max(0, bounds.width - 72), y: y, width: 72, height: 16)
        }
    }
}
