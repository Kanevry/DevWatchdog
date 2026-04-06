import Foundation
@preconcurrency import UserNotifications

@MainActor
final class NotificationService {
    private let center = UNUserNotificationCenter.current()
    private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    func requestPermission() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus

        if authorizationStatus == .notDetermined {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                authorizationStatus = granted ? .authorized : .denied
                if !granted {
                    print("DevWatchdog: Notification permission denied by user.")
                }
            } catch {
                print("DevWatchdog: Notification permission error: \(error.localizedDescription)")
                authorizationStatus = .denied
            }
        }
    }

    func send(title: String, body: String, sound: Bool = false) async {
        if authorizationStatus == .notDetermined {
            await requestPermission()
        }

        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus

        guard authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
        } catch {
            print("DevWatchdog: Failed to send notification: \(error.localizedDescription)")
        }
    }

    func sendBatchZombieAlert(count: Int, projects: [String: Int], totalMemoryMB: Double) async {
        let projectSummary = projects
            .sorted { $0.value > $1.value }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")

        let body: String
        if projectSummary.isEmpty {
            body = "\(count) zombie process\(count == 1 ? "" : "es") detected. \(String(format: "%.0f", totalMemoryMB)) MB memory. Will kill after grace period."
        } else {
            body = "\(count) zombies (\(projectSummary)). \(String(format: "%.0f", totalMemoryMB)) MB memory. Will kill after grace period."
        }

        await send(title: "Zombies detected", body: body, sound: true)
    }

    func sendBatchKillSummary(count: Int, freedMemoryMB: Double) async {
        await send(
            title: "Killed \(count) zombie process\(count == 1 ? "" : "es")",
            body: "Freed \(String(format: "%.0f", freedMemoryMB)) MB memory."
        )
    }
}
