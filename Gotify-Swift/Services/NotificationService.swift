import Foundation
import UserNotifications

final class NotificationService {
    static let shared = NotificationService()
    private static let localNotificationPrefix = "gotify-"
    static let unreadCountDidChangeNotification = Notification.Name("gotify.unreadCountDidChange")

    private let center = UNUserNotificationCenter.current()
    // 未读数的唯一事实来源:消息到达 +1,打开主窗口/面板清零。
    // 不依赖系统通知中心:未授权或前台抑制展示时 add 不产生 delivered 记录,
    // 若按 delivered 统计会导致红眼永远不触发。
    private var inAppUnreadCount = 0

    private init() {}

    func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self?.center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    func postNotification(for message: GotifyMessage) {
        inAppUnreadCount += 1          // MainActor 上同步自增,连发不丢计数
        publishUnreadCount(inAppUnreadCount)

        let content = UNMutableNotificationContent()
        content.title = message.title.isEmpty ? "Gotify" : message.title
        content.body = message.message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(Self.localNotificationPrefix)\(message.id)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request) { _ in }   // 失败(如未授权)不影响红眼状态
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

    private func publishUnreadCount(_ count: Int) {
        DispatchQueue.main.async {
            self.inAppUnreadCount = count
            NotificationCenter.default.post(
                name: Self.unreadCountDidChangeNotification,
                object: count
            )
        }
    }
}
