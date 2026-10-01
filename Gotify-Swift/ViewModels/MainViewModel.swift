import Foundation
import Combine
import AppKit
import CryptoKit
import ImageIO
import ServiceManagement

@MainActor
final class MainViewModel: ObservableObject {
    static let allAppsSelectionID = -1

    /// 驻留内存的消息历史上限;更早的内容不常驻,降低内存占用
    private static let maxResidentMessages = 200

    @Published private(set) var messages: [GotifyMessage] = []
    @Published private(set) var applications: [GotifyApplication] = []
    @Published private(set) var appIcons: [Int: NSImage] = [:]
    @Published var selectedAppID: Int = MainViewModel.allAppsSelectionID
    @Published var serverURL: String = ""
    @Published var clientToken: String = ""
    @Published var launchAtLoginEnabled: Bool
    @Published var messageFontSize: Double = 14 {
        didSet {
            settings.messageFontSize = messageFontSize
        }
    }
    @Published var focusedMessageID: Int?
    @Published var searchText: String = ""
    @Published private(set) var connectionStatusText: String = L10n.text("connection.idle")
    @Published private(set) var lastConnectionErrorText: String = ""
    @Published private(set) var launchAtLoginErrorText: String = ""
    @Published private(set) var isRefreshing = false
    @Published private(set) var deletingMessageIDs: Set<Int> = []

    private let settings = AppSettings.shared
    private let socketService = GotifyWebSocketService()
    private let apiService = GotifyAPIService()
    private let iconCache = AppIconCache()
    private var loadingAppIconIDs: Set<Int> = []
    private var hasStarted = false
    private var currentConnectionState: GotifyWebSocketService.ConnectionState = .idle
    private var maintenanceTask: Task<Void, Never>?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var isBackgroundSyncing = false

    init() {
        serverURL = settings.serverURL
        clientToken = settings.clientToken
        launchAtLoginEnabled = Self.currentLaunchAtLoginEnabled()
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

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = enabled
            launchAtLoginErrorText = ""
        } catch {
            launchAtLoginEnabled = Self.currentLaunchAtLoginEnabled()
            launchAtLoginErrorText = L10n.format("error.launch_at_login_failed", error.localizedDescription)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            await refreshMessagesInternal()
        }
        connectIfPossible()
        startMaintenanceLoop()
        installWakeObserverIfNeeded()
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
        var result: [GotifyMessage]
        if selectedAppID == Self.allAppsSelectionID {
            result = messages
        } else {
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -90, to: Date())
            result = messages.filter { item in
                guard item.appID == selectedAppID else { return false }
                guard let cutoffDate else { return true }
                guard let messageDate = item.date else { return false }
                return messageDate >= cutoffDate
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }
        return result.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.message.localizedCaseInsensitiveContains(query)
                || appName(for: item.appID).localizedCaseInsensitiveContains(query)
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

    func clearFocusedMessage(_ messageID: Int? = nil) {
        guard messageID == nil || focusedMessageID == messageID else { return }
        focusedMessageID = nil
    }

    func appName(for appID: Int?) -> String {
        guard let appID else { return L10n.text("app.unknown") }
        if let app = applications.first(where: { $0.id == appID }) {
            return app.name
        }
        return L10n.format("app.fallback_format", appID)
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
        guard !deletingMessageIDs.contains(message.id) else { return }
        guard let existingIndex = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let removedMessage = messages.remove(at: existingIndex)
        deletingMessageIDs.insert(message.id)
        Task {
            do {
                try await apiService.deleteMessage(serverURL: serverURL, token: clientToken, messageID: message.id)
            } catch {
                messages.insert(removedMessage, at: min(existingIndex, messages.count))
                messages.sort(by: Self.sortMessages)
                lastConnectionErrorText = L10n.format("error.delete_message_failed", error.localizedDescription)
            }
            deletingMessageIDs.remove(message.id)
        }
    }

    private func connectIfPossible() {
        socketService.connect(serverURL: serverURL, token: clientToken)
    }

    private static func currentLaunchAtLoginEnabled() -> Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    private func refreshMessagesInternal() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let recent = try await fetchMessageSnapshot(targetCount: Self.maxResidentMessages)
            replaceMessages(with: recent)
            mergeApplicationsFromMessages()
        } catch {
            lastConnectionErrorText = L10n.format("error.fetch_history_failed", error.localizedDescription)
        }

        do {
            let apps = try await apiService.fetchApplications(serverURL: serverURL, token: clientToken)
            mergeApplications(apps)
        } catch {
            // Some tokens cannot access /application; keep sidebar from message appid fallback.
        }
    }

    /// 后台可靠性同步:增量拉取本地没有的新消息(比全量拉 100 条省得多的解析与分配)。
    /// 官方 since 语义:只返回比 since 更新(更高 ID)的消息。
    private func syncRecentMessagesForReliability() async {
        if isRefreshing || isBackgroundSyncing { return }
        isBackgroundSyncing = true
        defer { isBackgroundSyncing = false }

        do {
            guard let newestKnown = messages.map(\.id).max() else {
                let recent = try await fetchMessageSnapshot(targetCount: 100)
                await ingestSyncedMessages(recent)
                return
            }

            var since = newestKnown
            var fetched: [GotifyMessage] = []
            var incrementalOK = false
            var firstProbeEmpty = false

            for attempt in 0..<3 {
                let page = try await apiService.fetchMessagesPage(
                    serverURL: serverURL,
                    token: clientToken,
                    limit: 100,
                    since: since
                )
                if attempt == 0 && page.messages.isEmpty {
                    // 没有比最新已知 ID 更新的消息 —— 增量路径,一次请求收工
                    firstProbeEmpty = true
                    break
                }
                let newer = page.messages.filter { $0.id > since }
                guard !newer.isEmpty else { break }
                incrementalOK = true
                fetched.append(contentsOf: newer)
                guard let pageMaxID = newer.map(\.id).max(), pageMaxID > since,
                      page.messages.count >= 100 else { break }
                since = pageMaxID
            }

            if incrementalOK {
                await ingestSyncedMessages(fetched)
            } else if firstProbeEmpty {
                // 空闲周期:没有新消息,什么都不做
            } else {
                // 服务器把 since 当作分页游标(返回更旧消息)时走这里:
                // 退回全量快照,保证 WS 断线期间漏掉的消息仍能补上
                let recent = try await fetchMessageSnapshot(targetCount: 100)
                await ingestSyncedMessages(recent)
            }
        } catch {
            if currentConnectionState != .connected {
                lastConnectionErrorText = L10n.format("error.fetch_history_failed", error.localizedDescription)
            }
        }
    }

    private func ingestSyncedMessages(_ recent: [GotifyMessage]) async {
        let existingIDs = Set(messages.map(\.id))
        let newMessages = recent.filter { !existingIDs.contains($0.id) }

        upsertMessages(recent)

        let orderedNewMessages = newMessages.sorted { lhs, rhs in
            if let lhsDate = lhs.date, let rhsDate = rhs.date, lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return lhs.id < rhs.id
        }
        for message in orderedNewMessages {
            NotificationService.shared.postNotification(for: message)
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

                // 驻留上限内收满即停,避免为凑满 90 天解析上千条
                if collected.count >= Self.maxResidentMessages {
                    collected.removeLast(collected.count - Self.maxResidentMessages)
                    break
                }

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
            replaceMessagesForSelectedApp(collected, appID: targetAppID, cutoffDate: cutoffDate)
            mergeApplicationsFromMessages()
        } catch {
            lastConnectionErrorText = L10n.format("error.fetch_90_days_failed", error.localizedDescription)
        }
    }

    private func fetchMessageSnapshot(targetCount: Int) async throws -> [GotifyMessage] {
        let desiredCount = max(1, targetCount)
        var collected: [GotifyMessage] = []
        var since: Int? = nil

        while collected.count < desiredCount {
            let remaining = desiredCount - collected.count
            let page = try await apiService.fetchMessagesPage(
                serverURL: serverURL,
                token: clientToken,
                limit: min(100, remaining),
                since: since
            )

            if page.messages.isEmpty {
                break
            }

            collected.append(contentsOf: page.messages)

            guard let nextSince = page.nextSince, nextSince != since else {
                break
            }
            since = nextSince
        }

        return Array(collected.prefix(desiredCount))
    }

    private func replaceMessages(with incoming: [GotifyMessage]) {
        let unique = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        messages = unique.values.sorted(by: Self.sortMessages)
    }

    private func replaceMessagesForSelectedApp(_ incoming: [GotifyMessage], appID: Int, cutoffDate: Date?) {
        let incomingIDs = Set(incoming.map(\.id))
        let remainingMessages = messages.filter { item in
            guard item.appID == appID else { return true }
            guard let cutoffDate else { return false }
            guard let date = item.date else { return false }
            if date < cutoffDate {
                return true
            }
            return incomingIDs.contains(item.id)
        }

        let uniqueIncoming = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        messages = (remainingMessages + uniqueIncoming.values).sorted(by: Self.sortMessages)
        trimMessagesToResidentLimit()
    }

    private func upsertMessage(_ message: GotifyMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        messages.sort(by: Self.sortMessages)
        trimMessagesToResidentLimit()
        mergeApplicationsFromMessages()
    }

    private func upsertMessages(_ incoming: [GotifyMessage]) {
        guard !incoming.isEmpty else { return }
        var mergedByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for item in incoming {
            mergedByID[item.id] = item
        }
        messages = mergedByID.values.sorted(by: Self.sortMessages)
        trimMessagesToResidentLimit()
        mergeApplicationsFromMessages()
    }

    /// 数组已按最新在前排序,直接丢弃超出驻留上限的旧消息
    private func trimMessagesToResidentLimit() {
        guard messages.count > Self.maxResidentMessages else { return }
        messages.removeLast(messages.count - Self.maxResidentMessages)
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
                known[appID] = GotifyApplication(id: appID, name: L10n.format("app.fallback_format", appID), image: nil, description: nil)
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
        currentConnectionState = state
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

    private func startMaintenanceLoop() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard !Task.isCancelled else { return }
                await self.performMaintenanceTick()
            }
        }
    }

    private func performMaintenanceTick() async {
        guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !clientToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let needsReconnect = currentConnectionState != .connected || socketService.isLikelyStale(maxIdle: 90)
        if needsReconnect {
            connectIfPossible()
            await syncRecentMessagesForReliability()
        }
    }

    private func installWakeObserverIfNeeded() {
        guard workspaceWakeObserver == nil else { return }
        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.connectIfPossible()
                await self.syncRecentMessagesForReliability()
            }
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
            return L10n.text("connection.idle")
        case .connecting:
            return L10n.text("connection.connecting")
        case .connected:
            return L10n.text("connection.connected")
        case .failed(let reason):
            return reason
        }
    }

    deinit {
        maintenanceTask?.cancel()
        if let workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
        }
    }
}
