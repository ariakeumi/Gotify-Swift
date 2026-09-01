import Foundation
import UserNotifications

final class NotificationService {
    static let shared = NotificationService()
    private static let localNotificationPrefix = "gotify-"
    static let unreadCountDidChangeNotification = Notification.Name("gotify.unreadCountDidChange")

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

        center.add(request) { [weak self] _ in
            self?.refreshUnreadCount()
        }
    }

    func clearDeliveredGotifyNotifications() {
        center.getDeliveredNotifications { [weak self] notifications in
            let identifiers = notifications
                .map(\.request.identifier)
                .filter { $0.hasPrefix(Self.localNotificationPrefix) }

            guard !identifiers.isEmpty else {
                self?.publishUnreadCount(0)
                return
            }
            self?.center.removeDeliveredNotifications(withIdentifiers: identifiers)
            self?.publishUnreadCount(0)
        }
    }

    func refreshUnreadCount() {
        center.getDeliveredNotifications { notifications in
            let unreadCount = notifications.reduce(into: 0) { partialResult, notification in
                if notification.request.identifier.hasPrefix(Self.localNotificationPrefix) {
                    partialResult += 1
                }
            }
            self.publishUnreadCount(unreadCount)
        }
    }

    private func publishUnreadCount(_ unreadCount: Int) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.unreadCountDidChangeNotification,
                object: unreadCount
            )
        }
    }
}
