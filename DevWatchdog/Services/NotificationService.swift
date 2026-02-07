import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    private let center = UNUserNotificationCenter.current()
    private var isAuthorized = false

    func requestPermission() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            if !granted {
                print("DevWatchdog: Notification permission denied by user.")
            }
        } catch {
            print("DevWatchdog: Notification permission error: \(error.localizedDescription)")
        }
    }

    func send(title: String, body: String, sound: Bool = false) async {
        // Check current authorization before sending
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else {
            // Silently skip - user denied or not yet asked
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await center.add(request)
        } catch {
            print("DevWatchdog: Failed to send notification: \(error.localizedDescription)")
        }
    }
}
