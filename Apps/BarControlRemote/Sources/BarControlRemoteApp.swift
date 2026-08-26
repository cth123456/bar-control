import SwiftUI
import UIKit

extension Notification.Name {
    static let cloudRelayDidChange = Notification.Name("BarControlRemote.cloudRelayDidChange")
}

final class RemoteAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NotificationCenter.default.post(name: .cloudRelayDidChange, object: nil)
        completionHandler(.newData)
    }
}

@main
struct BarControlRemoteApp: App {
    @UIApplicationDelegateAdaptor(RemoteAppDelegate.self) private var appDelegate
    @StateObject private var model = RemoteViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    #if DEBUG
                    if CommandLine.arguments.contains("--ui-preview-fixture") { return }
                    #endif
                    await model.start()
                    if CommandLine.arguments.contains("--cloudkit-smoke-test") {
                        await model.runCloudKitSmokeTest()
                    }
                    if CommandLine.arguments.contains("--file-smoke-test") {
                        await model.runFileSmokeTest()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .cloudRelayDidChange)) { _ in
                    Task { await model.refresh() }
                }
        }
    }
}
