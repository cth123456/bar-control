import Foundation
import CoreGraphics

enum TouchBarBrightnessPolicy {
    static let activeBrightness = 1.0
    static let idleBrightness = 0.8

    /// 系统亮度有量化误差（1.0 回读约 0.991），避免因此反复写入。
    static func shouldAdjust(current: Double, target: Double, targetChanged: Bool) -> Bool {
        guard current.isFinite, target.isFinite,
              (0...1).contains(current), (0...1).contains(target) else { return false }
        return targetChanged ? abs(current - target) > 0.015 : current + 0.015 < target
    }

    /// Mac 输入与触控栏输入任一仍然活跃，就不降到空闲档位。
    static func isIdle(touchBarIdle: TimeInterval, macIdle: TimeInterval, delay: TimeInterval) -> Bool {
        min(max(0, touchBarIdle), max(0, macIdle)) >= delay
    }

    /// 仅读取输入空闲时长，不监听或记录按键内容，不需要全局事件监控权限。
    static func macIdleTime() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel
        ]
        return types.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.filter { $0.isFinite && $0 >= 0 }.min() ?? .infinity
    }
}
