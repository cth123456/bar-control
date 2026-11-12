import Foundation

/// 什么时候自动把模块栏呈现到触控栏。
/// 把独立语义拆开：常驻（唤醒/启动恢复）、让位（前台应用需要中间区域）、
/// 自愈（运行中补呈现）、fn 模式修复。
enum TouchBarPresentationPolicy {
    /// 启动时是否自动呈现：常驻打开，且用户没有手动收起。
    static func shouldPresentAtLaunch(persistent: Bool, userHidden: Bool = false) -> Bool {
        persistent && !userHidden
    }

    /// 唤醒/解锁后是否恢复：常驻打开，且用户没有手动收起。
    static func shouldRestoreAfterWake(persistent: Bool, userHidden: Bool = false) -> Bool {
        persistent && !userHidden
    }

    /// 运行中的自愈：常驻打开、用户没收起，且当前前台应用不需要中间的触控栏。
    static func shouldSelfHeal(persistent: Bool, yieldingToApp: Bool, userHidden: Bool = false) -> Bool {
        persistent && !yieldingToApp && !userHidden
    }

    /// 自动展开（启动、唤醒、随航结束后的回挂）只在触控栏“空着”时进行：
    /// 前台应用不在让位名单、没有文本输入焦点，系统没在合成（随航/通用控制活动）。
    static func shouldAutoExpand(
        persistent: Bool,
        yieldingToApp: Bool,
        systemOwnsTouchBar: Bool
    ) -> Bool {
        persistent && !yieldingToApp && !systemOwnsTouchBar
    }

    /// 修复原生 F1–F12 模式：只有我们的模块栏本来就该显示时才去改系统设置。
    static func shouldRepairNativeMode(mainBarShown: Bool, yieldingToApp: Bool) -> Bool {
        mainBarShown && !yieldingToApp
    }
}
