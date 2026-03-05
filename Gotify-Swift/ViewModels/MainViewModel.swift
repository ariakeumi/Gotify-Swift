import Foundation
import Combine
import AppKit
import CryptoKit
import ImageIO

@MainActor
final class MainViewModel: ObservableObject {
    static let allAppsSelectionID = -1

    @Published private(set) var messages: [GotifyMessage] = []
    @Published private(set) var applications: [GotifyApplication] = []
    @Published private(set) var appIcons: [Int: NSImage] = [:]
    @Published var selectedAppID: Int = MainViewModel.allAppsSelectionID
    @Published var serverURL: String = ""
    @Published var clientToken: String = ""
    @Published var messageFontSize: Double = 14 {
        didSet {
            settings.messageFontSize = messageFontSize
        }
    }
    @Published var focusedMessageID: Int?
    @Published private(set) var connectionStatusText: String = "未连接"
    @Published private(set) var lastConnectionErrorText: String = ""
    @Published private(set) var isRefreshing = false

    private let settings = AppSettings.shared
    private let socketService = GotifyWebSocketService()
    private let apiService = GotifyAPIService()
    private let iconCache = AppIconCache()
    private var loadingAppIconIDs: Set<Int> = []
    private var hasStarted = false

    init() {
        serverURL = settings.serverURL
        clientToken = settings.clientToken
        messageFontSize = settings.messageFontSize

        socketService.onMessage = { [weak self] message in
            guard let self else { return }
            self.upsertMessage(message)
            NotificationService.shared.postNotification(for: message)
        }
        socketService.onStateChange = { [weak self] state in
            self?.handleConnectionState(state)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            await refreshMessagesInternal()
        }
        connectIfPossible()
    }

    func saveSettingsAndReconnect() {
        settings.serverURL = serverURL
        settings.clientToken = clientToken
        selectedAppID = Self.allAppsSelectionID
        applications = []
        appIcons.removeAll()
        loadingAppIconIDs.removeAll()
        Task {
            await refreshMessagesInternal()
        }
        connectIfPossible()
    }

    func refreshMessages() {
        Task {
            await refreshMessagesInternal()
        }
    }

    func refreshMessagesForSelectedApp() {
        Task {
            await refreshSelectedAppMessagesForLast90Days()
        }
    }

    var filteredMessages: [GotifyMessage] {
        if selectedAppID == Self.allAppsSelectionID {
            return messages
        }
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -90, to: Date())
        return messages.filter { item in
            guard item.appID == selectedAppID else { return false }
            guard let cutoffDate else { return true }
            guard let messageDate = item.date else { return false }
            return messageDate >= cutoffDate
        }
    }

    var recentStatusBarMessages: [GotifyMessage] {
        Array(messages.prefix(8))
    }

    func didSelectSidebarApp() {
        if selectedAppID != Self.allAppsSelectionID {
            refreshMessagesForSelectedApp()
        } else {
            refreshMessages()
        }
    }

    func selectSidebarApp(_ appID: Int) {
        selectedAppID = appID
        didSelectSidebarApp()
    }

    func focusMessage(_ messageID: Int) {
        selectedAppID = Self.allAppsSelectionID
        focusedMessageID = messageID
    }

    func appName(for appID: Int?) -> String {
        guard let appID else { return "Unknown App" }
        if let app = applications.first(where: { $0.id == appID }) {
            return app.name
        }
        return "App \(appID)"
    }

    func icon(for appID: Int?) -> NSImage? {
        guard let appID else { return nil }
        return appIcons[appID]
    }

    func loadIconIfNeeded(for appID: Int?) {
        guard let appID else { return }
        guard let app = applications.first(where: { $0.id == appID }) else { return }
        guard let imageRef = app.image, !imageRef.isEmpty else { return }
        if appIcons[appID] != nil || loadingAppIconIDs.contains(appID) { return }
        loadingAppIconIDs.insert(appID)
        Task {
            defer { loadingAppIconIDs.remove(appID) }
            let cacheKey = makeIconCacheKey(serverURL: serverURL, appID: appID, imageRef: imageRef)
            if let cachedData = await iconCache.load(forKey: cacheKey), let cachedImage = decodeIconImage(from: cachedData) {
                appIcons[appID] = cachedImage
                return
            }
            do {
                let data = try await apiService.fetchAppIcon(
                    serverURL: serverURL,
                    token: clientToken,
                    appID: appID,
                    imageRef: imageRef
                )
                if let image = decodeIconImage(from: data) {
                    appIcons[appID] = image
                    await iconCache.store(data, forKey: cacheKey)
                }
            } catch {
                // Keep placeholder icon when unavailable.
            }
        }
    }

    func deleteMessage(_ message: GotifyMessage) {
        Task {
            do {
                try await apiService.deleteMessage(serverURL: serverURL, token: clientToken, messageID: message.id)
                messages.removeAll { $0.id == message.id }
            } catch {
                lastConnectionErrorText = "删除通知失败: \(error.localizedDescription)"
            }
        }
    }

    private func connectIfPossible() {
        socketService.connect(serverURL: serverURL, token: clientToken)
    }

    private func refreshMessagesInternal(limit: Int = 100) async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let recent = try await apiService.fetchRecentMessages(serverURL: serverURL, token: clientToken, limit: limit)
            mergeMessages(recent)
            mergeApplicationsFromMessages()
        } catch {
            lastConnectionErrorText = "拉取历史消息失败: \(error.localizedDescription)"
        }

        do {
            let apps = try await apiService.fetchApplications(serverURL: serverURL, token: clientToken)
            mergeApplications(apps)
        } catch {
            // Some tokens cannot access /application; keep sidebar from message appid fallback.
        }
    }

    private func refreshSelectedAppMessagesForLast90Days() async {
        guard selectedAppID != Self.allAppsSelectionID else {
            await refreshMessagesInternal()
            return
        }
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let targetAppID = selectedAppID
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -90, to: Date())
        var since: Int? = nil
        var collected: [GotifyMessage] = []

        do {
            for _ in 0..<60 {
                let page = try await apiService.fetchMessagesPage(
                    serverURL: serverURL,
                    token: clientToken,
                    limit: 100,
                    since: since
                )
                if page.messages.isEmpty {
                    break
                }

                let appMessages = page.messages.filter { $0.appID == targetAppID }
                collected.append(contentsOf: appMessages)

                let reachedOlderThanCutoff: Bool = {
                    guard let cutoffDate else { return false }
                    let datedMessages = page.messages.compactMap(\.date)
                    guard let oldest = datedMessages.min() else { return false }
                    return oldest < cutoffDate
                }()
                if reachedOlderThanCutoff {
                    break
                }

                guard let nextSince = page.nextSince, nextSince != since else { break }
                since = nextSince
            }

            if let cutoffDate {
                collected = collected.filter { msg in
                    guard let date = msg.date else { return false }
                    return date >= cutoffDate
                }
            }
            mergeMessages(collected)
            mergeApplicationsFromMessages()
        } catch {
            lastConnectionErrorText = "拉取 90 天通知失败: \(error.localizedDescription)"
        }
    }

    private func mergeMessages(_ incoming: [GotifyMessage]) {
        guard !incoming.isEmpty else { return }
        var mergedByID: [Int: GotifyMessage] = [:]
        for item in messages {
            mergedByID[item.id] = item
        }
        for item in incoming {
            mergedByID[item.id] = item
        }
        messages = mergedByID.values.sorted(by: Self.sortMessages)
    }

    private func upsertMessage(_ message: GotifyMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        messages.sort(by: Self.sortMessages)
        mergeApplicationsFromMessages()
    }

    private func mergeApplications(_ incoming: [GotifyApplication]) {
        var mergedByID: [Int: GotifyApplication] = [:]
        for app in applications {
            mergedByID[app.id] = app
        }
        for app in incoming {
            mergedByID[app.id] = app
        }
        applications = mergedByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        mergeApplicationsFromMessages()
        prefetchIconsForKnownApps()
    }

    private func mergeApplicationsFromMessages() {
        var known = Dictionary(uniqueKeysWithValues: applications.map { ($0.id, $0) })
        for appID in messages.compactMap(\.appID) {
            if known[appID] == nil {
                known[appID] = GotifyApplication(id: appID, name: "App \(appID)", image: nil, description: nil)
            }
        }
        applications = known.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        prefetchIconsForKnownApps()
    }

    private static func sortMessages(_ lhs: GotifyMessage, _ rhs: GotifyMessage) -> Bool {
        switch (lhs.date, rhs.date) {
        case let (lDate?, rDate?):
            if lDate != rDate {
                return lDate > rDate
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }
        return lhs.id > rhs.id
    }

    private func handleConnectionState(_ state: GotifyWebSocketService.ConnectionState) {
        connectionStatusText = Self.statusText(for: state)
        if case .failed(let reason) = state {
            lastConnectionErrorText = reason
        } else if case .connected = state {
            lastConnectionErrorText = ""
        }
    }

    private func makeIconCacheKey(serverURL: String, appID: Int, imageRef: String) -> String {
        let normalizedServer = serverURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let source = "\(normalizedServer)|\(appID)|\(imageRef)"
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func prefetchIconsForKnownApps() {
        for app in applications {
            loadIconIfNeeded(for: app.id)
        }
    }

    private func decodeIconImage(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return NSImage(data: data)
        }

        // Decode into a high-quality thumbnail first; this reduces jagged edges during UI scaling.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 128
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return NSImage(cgImage: cgImage, size: NSSize(width: 34, height: 34))
        }
        return NSImage(data: data)
    }

    private static func statusText(for state: GotifyWebSocketService.ConnectionState) -> String {
        switch state {
        case .idle:
            return "未连接"
        case .connecting:
            return "连接中..."
        case .connected:
            return "已连接"
        case .failed(let reason):
            return reason
        }
    }
}
