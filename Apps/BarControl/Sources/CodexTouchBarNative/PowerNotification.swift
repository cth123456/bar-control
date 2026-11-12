import Foundation
import UserNotifications

/// System banners in Notification Center, not modal alerts.
/// Posting is gated by policy changes in AppMain, so a dropping battery
/// percentage never produces a stream of notifications.
enum PowerNotification {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            AppLog.write("notification authorization granted=\(granted) error=\(error?.localizedDescription ?? "none")")
        }
    }

    static func post(title: String, body: String, identifier: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLog.write("notification post failed: \(error.localizedDescription)")
            }
        }
    }

    /// Only a real policy transition deserves a banner.
    static func shouldPost(previous: PowerFlowPolicy, next: PowerFlowPolicy, priority: PowerFlowPolicy.LowBatteryPriority) -> Bool {
        previous != next && priority == .bothLow
    }
}
