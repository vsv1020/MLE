import UIKit
@preconcurrency import UserNotifications

/// The few things SwiftUI's `App` still cannot do: receive the APNs device token, and decide how
/// a notification is presented while the app is open.
///
/// Installed with `@UIApplicationDelegateAdaptor` in ``VocabLoopApp``, which hands it the
/// ``PushRegistrationService`` once the dependency graph exists. A token that arrives before
/// that is held and passed on at attach time.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private weak var push: PushRegistrationService?
    private var pendingToken: String?

    func attach(_ push: PushRegistrationService) {
        self.push = push
        if let token = pendingToken {
            pendingToken = nil
            Task { await push.didReceiveDeviceToken(token) }
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Set before launch finishes, as Apple requires, so a tap that launched the app is
        // delivered here too.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = PushRegistrationService.hexString(deviceToken)
        guard let push else {
            pendingToken = token
            return
        }
        Task { await push.didReceiveDeviceToken(token) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        push?.didFailToRegister(error)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Remote announcements show as a banner even with the app open — otherwise one sent while
    /// the user is studying would vanish unseen. Local study reminders keep their old behaviour
    /// (not shown in the foreground): the user is already studying.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.trigger is UNPushNotificationTrigger {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([])
        }
    }

    /// A tap just opens the app; announcements carry no deep link.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
