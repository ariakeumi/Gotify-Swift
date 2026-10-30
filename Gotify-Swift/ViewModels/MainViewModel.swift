import Foundation
import Combine
import AppKit
import CryptoKit
import ImageIO
import ServiceManagement

@MainActor
final class MainViewModel: ObservableObject {
    static let allAppsSelectionID = -1

    private static let historyPageSize = 50
    private static let statusBarMessageLimit = 8

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
    @Published private(set) var isMainWindowOpen = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMoreMessages = false
    @Published private(set) var historyLoadError = false
    @Published private(set) var deletingMessageIDs: Set<Int> = []

    private let settings = AppSettings.shared
    private let socketService = GotifyWebSocketService()
    private let apiService: GotifyAPIService
    private let iconCache = AppIconCache()
    private var loadingAppIconIDs: Set<Int> = []
    private var hasStarted = false
    private var currentConnectionState: GotifyWebSocketService.ConnectionState = .idle
    private var maintenanceTask: Task<Void, Never>?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var isBackgroundSyncing = false
    private var historyTask: Task<Void, Never>?
    private var historyGeneration = UUID()
    private var nextHistorySince: Int?
    private var connectionGeneration = UUID()

    init(apiService: GotifyAPIService = GotifyAPIService()) {
        self.apiService = apiService
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
        if historyTask == nil { refreshMessages() }
        connectIfPossible()
        startMaintenanceLoop()
        installWakeObserverIfNeeded()
    }

    func saveSettingsAndReconnect() {
        settings.serverURL = serverURL
        settings.clientToken = clientToken
        connectionGeneration = UUID()
        selectedAppID = Self.allAppsSelectionID
        messages = []
        applications = []
        appIcons.removeAll()
        loadingAppIconIDs.removeAll()
        refreshMessages()
        connectIfPossible()
    }

    func mainWindowDidOpen() {
        guard !isMainWindowOpen else { return }
        isMainWindowOpen = true
        refreshMessages()
    }

    func mainWindowWillClose() {
        isMainWindowOpen = false
        cancelHistoryLoading()
        hasMoreMessages = false
        nextHistorySince = nil
        focusedMessageID = nil
        searchText = ""
        trimMessagesWhenWindowClosed()
        // 启动后立即关窗时,首页请求可能尚未返回;仅补齐菜单栏的小快照。
        if messages.isEmpty && hasStarted { refreshMessages() }
    }

    func refreshMessages() {
        cancelHistoryLoading()
        let generation = historyGeneration
        let windowIsOpen = isMainWindowOpen
        let targetAppID = selectedAppID
        let newestKnownID = messages.map(\.id).max()
        nextHistorySince = nil
        hasMoreMessages = windowIsOpen
        historyLoadError = false
        // 保留菜单栏的最近消息,释放上一次浏览的历史。
        messages = messages.prefix(Self.statusBarMessageLimit).map { $0 }
        isRefreshing = true
        historyTask = Task {
            defer {
                if historyGeneration == generation {
                    isRefreshing = false
                    historyTask = nil
                }
            }
            if windowIsOpen {
                await loadHistoryPage(generation: generation, appID: targetAppID)
            } else {
                do {
                    let recent = try await fetchMessageSnapshot(targetCount: Self.statusBarMessageLimit)
                    guard !Task.isCancelled, historyGeneration == generation else { return }
                    replaceSnapshot(recent, preservingMessagesNewerThan: newestKnownID)
                } catch {
                    guard !Task.isCancelled, historyGeneration == generation else { return }
                    lastConnectionErrorText = L10n.format("error.fetch_history_failed", error.localizedDescription)
                }
            }
            guard !Task.isCancelled, historyGeneration == generation else { return }
            do {
                let apps = try await apiService.fetchApplications(serverURL: serverURL, token: clientToken)
                guard !Task.isCancelled, historyGeneration == generation else { return }
                mergeApplications(apps)
            } catch {
                // Some tokens cannot access /application; keep the message appid fallback.
            }
        }
    }

    func loadMoreMessages() {
        guard isMainWindowOpen, hasMoreMessages, !isRefreshing, !isLoadingMore else { return }
        let generation = historyGeneration
        let appID = selectedAppID
        isLoadingMore = true
        historyLoadError = false
        historyTask = Task {
            defer {
                if historyGeneration == generation {
                    isLoadingMore = false
                    historyTask = nil
                }
            }
            await loadHistoryPage(generation: generation, appID: appID)
        }
    }

    private func cancelHistoryLoading() {
        historyGeneration = UUID()
        historyTask?.cancel()
        historyTask = nil
        isRefreshing = false
        isLoadingMore = false
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
        messages.prefix(Self.statusBarMessageLimit).map { $0 }
    }

    func didSelectSidebarApp() {
        refreshMessages()
    }

    func selectSidebarApp(_ appID: Int) {
        selectedAppID = appID
        didSelectSidebarApp()
    }

    func focusMessage(_ messageID: Int) {
        if selectedAppID != Self.allAppsSelectionID {
            selectedAppID = Self.allAppsSelectionID
            refreshMessages()
        }
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
        let connection = connectionGeneration
        deletingMessageIDs.insert(message.id)
        Task {
            defer { deletingMessageIDs.remove(message.id) }
            do {
                try await apiService.deleteMessage(serverURL: serverURL, token: clientToken, messageID: message.id)
            } catch {
                guard connectionGeneration == connection else { return }
                upsertMessage(removedMessage)
                lastConnectionErrorText = L10n.format("error.delete_message_failed", error.localizedDescription)
            }
        }
    }

    private func connectIfPossible() {
        socketService.connect(serverURL: serverURL, token: clientToken)
    }

    private static func currentLaunchAtLoginEnabled() -> Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// 后台可靠性同步:增量拉取本地没有的新消息(比全量拉 100 条省得多的解析与分配)。
    /// 官方 since 语义:只返回比 since 更新(更高 ID)的消息。
    private func syncRecentMessagesForReliability() async {
        if isRefreshing || isBackgroundSyncing { return }
        isBackgroundSyncing = true
        let connection = connectionGeneration
        defer { isBackgroundSyncing = false }

        do {
            guard let newestKnown = messages.map(\.id).max() else {
                let recent = try await fetchMessageSnapshot(targetCount: Self.statusBarMessageLimit)
                guard !Task.isCancelled, connectionGeneration == connection else { return }
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
                guard !Task.isCancelled, connectionGeneration == connection else { return }
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
                guard !Task.isCancelled, connectionGeneration == connection else { return }
                await ingestSyncedMessages(recent)
            }
        } catch {
            if currentConnectionState != .connected {
                lastConnectionErrorText = L10n.format("error.fetch_history_failed", error.localizedDescription)
            }
        }
    }

    private func ingestSyncedMessages(_ recent: [GotifyMessage]) async {
        let newestKnownID = messages.map(\.id).max()
        // 分页历史不参与补发通知;快照只合并比最新已知 ID 更新的消息。
        let newMessages = recent.filter { item in
            newestKnownID.map { item.id > $0 } ?? true
        }

        upsertMessages(newMessages)

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

    private func loadHistoryPage(generation: UUID, appID: Int) async {
        let cutoffDate = appID == Self.allAppsSelectionID ? nil
            : Calendar.current.date(byAdding: .day, value: -90, to: Date())
        let isFirstPage = nextHistorySince == nil
        let newestKnownID = messages.map(\.id).max()
        var cursor = nextHistorySince
        var collected: [GotifyMessage] = []
        var canContinue = true

        do {
            // 按应用筛选时,跳过其他应用的消息,最多收集一页匹配消息。
            repeat {
                try Task.checkCancellation()
                let page = try await apiService.fetchMessagesPage(
                    serverURL: serverURL,
                    token: clientToken,
                    limit: Self.historyPageSize - collected.count,
                    since: cursor
                )
                guard !Task.isCancelled, historyGeneration == generation, isMainWindowOpen else { return }

                collected.append(contentsOf: page.messages.filter { item in
                    guard appID != Self.allAppsSelectionID else { return true }
                    guard item.appID == appID else { return false }
                    guard let cutoffDate else { return true }
                    return item.date.map { $0 >= cutoffDate } ?? false
                })
                let reachedCutoff = cutoffDate.map { cutoff in
                    page.messages.compactMap(\.date).contains { $0 < cutoff }
                } ?? false
                canContinue = !page.messages.isEmpty && !reachedCutoff
                    && page.nextSince != nil && page.nextSince != cursor
                cursor = page.nextSince
            } while canContinue && collected.count < Self.historyPageSize

            nextHistorySince = cursor
            hasMoreMessages = canContinue
            if isFirstPage && appID == Self.allAppsSelectionID {
                replaceSnapshot(collected, preservingMessagesNewerThan: newestKnownID)
            } else {
                upsertMessages(collected)
            }
            historyLoadError = false
        } catch {
            guard !Task.isCancelled, historyGeneration == generation else { return }
            historyLoadError = true
            lastConnectionErrorText = L10n.format("error.fetch_history_failed", error.localizedDescription)
        }
    }

    private func fetchMessageSnapshot(targetCount: Int) async throws -> [GotifyMessage] {
        let desiredCount = max(1, targetCount)
        var collected: [GotifyMessage] = []
        var since: Int? = nil

        while collected.count < desiredCount {
            try Task.checkCancellation()
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

    private func replaceSnapshot(_ incoming: [GotifyMessage], preservingMessagesNewerThan newestKnownID: Int?) {
        let arrivedWhileLoading = messages.filter { item in
            newestKnownID.map { item.id > $0 } ?? true
        }
        let unique = Dictionary((incoming + arrivedWhileLoading).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        messages = unique.values.sorted(by: Self.sortMessages)
        trimMessagesWhenWindowClosed()
        mergeApplicationsFromMessages()
    }

    private func upsertMessage(_ message: GotifyMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        messages.sort(by: Self.sortMessages)
        trimMessagesWhenWindowClosed()
        mergeApplicationsFromMessages()
    }

    private func upsertMessages(_ incoming: [GotifyMessage]) {
        guard !incoming.isEmpty else { return }
        var mergedByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for item in incoming {
            mergedByID[item.id] = item
        }
        messages = mergedByID.values.sorted(by: Self.sortMessages)
        trimMessagesWhenWindowClosed()
        mergeApplicationsFromMessages()
    }

    /// 关闭主页后仅保留菜单栏需要的最近 8 条,重新打开时从第一页加载。
    private func trimMessagesWhenWindowClosed() {
        guard !isMainWindowOpen else { return }
        messages = messages.prefix(Self.statusBarMessageLimit).map { $0 }
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
        historyTask?.cancel()
        if let workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver)
        }
    }
}
