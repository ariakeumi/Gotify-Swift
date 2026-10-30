import Foundation

private final class MockServer {
    static let shared = MockServer()
    private let lock = NSLock()
    private var records: [[String: Any]] = []
    private var recordedQueries: [[String: String]] = []
    private var nextStatus = 200
    private var nextDelay: TimeInterval = 0

    func reset(count: Int = 135, oldMessageCount: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        let formatter = ISO8601DateFormatter()
        records = stride(from: count, through: 1, by: -1).map { id in
            let age: TimeInterval = id <= oldMessageCount ? 91 * 86_400 : Double(count - id)
            return ["id": id, "appid": id % 2 + 1, "title": "Message \(id)",
                    "message": "Body \(id)", "date": formatter.string(from: Date().addingTimeInterval(-age))]
        }
        recordedQueries = []
        nextStatus = 200
        nextDelay = 0
    }

    func configureNextMessageResponse(status: Int = 200, delay: TimeInterval = 0) {
        lock.lock()
        defer { lock.unlock() }
        nextStatus = status
        nextDelay = delay
    }

    func queries() -> [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedQueries
    }

    func response(for url: URL) -> (Int, Data, TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard url.lastPathComponent == "message" else {
            return (200, Data("[]".utf8), 0)
        }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        recordedQueries.append(query)
        let status = nextStatus
        let delay = nextDelay
        nextStatus = 200
        nextDelay = 0
        guard status == 200 else { return (status, Data("Mock failure".utf8), delay) }
        let limit = Int(query["limit"] ?? "50")!
        let since = query["since"].flatMap(Int.init)
        let available = records.filter { record in since.map { (record["id"] as! Int) < $0 } ?? true }
        let page = Array(available.prefix(limit))
        var paging: [String: Any] = [:]
        if available.count > page.count, let last = page.last?["id"] as? Int {
            paging["next"] = "/message?limit=\(limit)&since=\(last)"
        }
        let data = try! JSONSerialization.data(withJSONObject: ["messages": page, "paging": paging])
        return (status, data, delay)
    }
}

private final class MockURLProtocol: URLProtocol {
    private var responseTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let (status, data, delay) = MockServer.shared.response(for: url)
        responseTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                try Task.checkCancellation()
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {}
        }
    }

    override func stopLoading() { responseTask?.cancel() }
}

@main
private struct HistoryLoadingTests {
    @MainActor
    static func makeViewModel() -> MainViewModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let viewModel = MainViewModel(apiService: GotifyAPIService(session: URLSession(configuration: configuration)))
        viewModel.serverURL = "https://history-tests.invalid"
        viewModel.clientToken = "test-token"
        return viewModel
    }

    @MainActor
    static func waitUntil(_ condition: () -> Bool, _ description: String) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Timed out: \(description)")
    }

    @MainActor
    static func waitForIdle(_ viewModel: MainViewModel) async throws {
        try await waitUntil({ !viewModel.isRefreshing && !viewModel.isLoadingMore }, "history loading")
    }

    @MainActor
    static func main() async throws {
        let server = MockServer.shared
        server.reset()
        let viewModel = makeViewModel()
        viewModel.mainWindowDidOpen()
        try await waitForIdle(viewModel)
        precondition(viewModel.messages.count == 50)
        precondition(server.queries().count == 1 && server.queries()[0]["limit"] == "50")
        precondition(server.queries()[0]["since"] == nil)
        viewModel.loadMoreMessages()
        viewModel.loadMoreMessages()
        try await waitForIdle(viewModel)
        precondition(viewModel.messages.count == 100 && server.queries().count == 2)
        precondition(server.queries()[1]["since"] == "86")
        viewModel.loadMoreMessages()
        try await waitForIdle(viewModel)
        precondition(viewModel.messages.count == 135 && !viewModel.hasMoreMessages)
        precondition(Set(viewModel.messages.map(\.id)).count == 135)
        viewModel.loadMoreMessages()
        precondition(server.queries().count == 3)
        print("PASS: initial 50, next 50, final partial page, duplicate request guard, end of history")

        viewModel.mainWindowWillClose()
        precondition(!viewModel.isMainWindowOpen && !viewModel.hasMoreMessages)
        precondition(viewModel.messages.count == 8 && viewModel.recentStatusBarMessages.count == 8)
        precondition(viewModel.messages.capacity < 50)
        viewModel.loadMoreMessages()
        precondition(server.queries().count == 3)
        viewModel.mainWindowDidOpen()
        try await waitForIdle(viewModel)
        precondition(viewModel.messages.count == 50 && server.queries().last?["since"] == nil)
        print("PASS: close releases history, retains 8 menu messages, reopen starts from first page")

        server.configureNextMessageResponse(delay: 0.25)
        let beforeClose = server.queries().count
        viewModel.loadMoreMessages()
        try await waitUntil({ server.queries().count > beforeClose }, "delayed page request")
        viewModel.mainWindowWillClose()
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(viewModel.messages.count == 8 && !viewModel.isLoadingMore)
        viewModel.mainWindowDidOpen()
        try await waitForIdle(viewModel)
        precondition(viewModel.messages.count == 50)
        print("PASS: close cancels in-flight request and prevents late history restoration")

        server.configureNextMessageResponse(status: 500)
        viewModel.loadMoreMessages()
        try await waitForIdle(viewModel)
        precondition(viewModel.historyLoadError && viewModel.hasMoreMessages && viewModel.messages.count == 50)
        let failedCursor = server.queries().last?["since"]
        viewModel.loadMoreMessages()
        try await waitForIdle(viewModel)
        precondition(!viewModel.historyLoadError && viewModel.messages.count == 100)
        precondition(server.queries().last?["since"] == failedCursor)
        print("PASS: failed page retains data and retries the same cursor")
        viewModel.mainWindowWillClose()

        server.reset(count: 140, oldMessageCount: 10)
        let filtered = makeViewModel()
        filtered.mainWindowDidOpen()
        try await waitForIdle(filtered)
        filtered.selectSidebarApp(1)
        try await waitForIdle(filtered)
        precondition(filtered.filteredMessages.count == 50)
        precondition(filtered.filteredMessages.allSatisfy { $0.appID == 1 })
        filtered.loadMoreMessages()
        try await waitForIdle(filtered)
        precondition(filtered.filteredMessages.count == 65 && !filtered.hasMoreMessages)
        precondition(filtered.filteredMessages.allSatisfy { $0.id > 10 })
        precondition(server.queries().allSatisfy { Int($0["limit"]!)! <= 50 })
        print("PASS: application filter pages matching messages and stops at 90 days")

        server.configureNextMessageResponse(delay: 0.25)
        let beforeSwitch = server.queries().count
        filtered.selectSidebarApp(2)
        try await waitUntil({ server.queries().count > beforeSwitch }, "delayed application request")
        filtered.selectSidebarApp(MainViewModel.allAppsSelectionID)
        try await waitForIdle(filtered)
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(filtered.messages.count == 50 && filtered.messages.last?.id == 91)
        precondition(filtered.selectedAppID == MainViewModel.allAppsSelectionID)
        print("PASS: rapid application switching discards cancelled results")

        server.reset(count: 0)
        filtered.refreshMessages()
        try await waitForIdle(filtered)
        precondition(filtered.messages.isEmpty && !filtered.hasMoreMessages)
        print("PASS: refresh removes messages deleted on server and handles empty history")
        filtered.mainWindowWillClose()

        server.reset(count: 23)
        let background = makeViewModel()
        background.refreshMessages()
        try await waitForIdle(background)
        precondition(!background.isMainWindowOpen && background.messages.count == 8)
        precondition(server.queries().first?["limit"] == "8")
        print("PASS: background refresh only requests and retains 8 messages")
    }
}
