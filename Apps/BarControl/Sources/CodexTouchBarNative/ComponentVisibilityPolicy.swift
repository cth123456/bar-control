import Foundation

/// 模块显示开关的槽位变换：开 = 放进第一个空槽（满了替换最后一格），关 = 清掉它的所有槽位。
enum ComponentVisibilityPolicy {
    static func applying(
        to slots: [MainComponent?],
        component: MainComponent,
        show: Bool
    ) -> [MainComponent?] {
        var next = slots
        if show {
            guard !next.contains(component) else { return next }
            if let index = next.firstIndex(where: { $0 == nil }) {
                next[index] = component
            } else if !next.isEmpty {
                next[next.count - 1] = component
            }
        } else {
            for index in next.indices where next[index] == component {
                next[index] = nil
            }
        }
        return next
    }
}
