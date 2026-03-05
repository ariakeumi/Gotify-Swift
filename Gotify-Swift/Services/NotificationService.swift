import Foundation
import UserNotifications

final class NotificationService {
    static let shared = NotificationService()
    private static let localNotificationPrefix = "gotify-"

    private let center = UNUserNotificationCenter.current()

    private init() {}

    func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self?.center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    func postNotification(for message: GotifyMessage) {
        let content = UNMutableNotificationContent()
        content.title = message.title.isEmpty ? "Gotify" : message.title
        content.body = message.message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(Self.localNotificationPrefix)\(message.id)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request)
    }

    func clearDeliveredGotifyNotifications() {
        center.getDeliveredNotifications { [weak self] notifications in
            let identifiers = notifications
                .map(\.request.identifier)
                .filter { $0.hasPrefix(Self.localNotificationPrefix) }

            guard !identifiers.isEmpty else { return }
            self?.center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }
}
