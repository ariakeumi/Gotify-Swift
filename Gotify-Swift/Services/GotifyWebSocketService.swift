import Foundation

final class GotifyWebSocketService {
    typealias MessageHandler = @MainActor (GotifyMessage) -> Void
    typealias StateHandler = @MainActor (ConnectionState) -> Void

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isManuallyStopped = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var latestServerURL: String = ""
    private var latestToken: String = ""
    private var activeConnectionID = UUID()
    private let decoder: JSONDecoder

    var onMessage: MessageHandler?
    var onStateChange: StateHandler?

    init() {
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func connect(serverURL rawServerURL: String, token rawToken: String) {
        disconnect(manual: false)

        let serverURL = rawServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !serverURL.isEmpty, !token.isEmpty else {
            publishState(.failed("服务器地址或 Token 为空"))
            return
        }
        guard let webSocketURL = makeWebSocketURL(serverURL: serverURL, token: token) else {
            publishState(.failed("服务器地址格式不正确"))
            return
        }

        isManuallyStopped = false
        latestServerURL = serverURL
        latestToken = token
        let connectionID = UUID()
        activeConnectionID = connectionID
        publishState(.connecting)
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: webSocketURL)
        self.session = session
        self.task = task
        task.resume()
        publishState(.connected)

        listen(connectionID: connectionID)
    }

    func disconnect(manual: Bool = true) {
        isManuallyStopped = manual
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if manual {
            publishState(.idle)
        }
    }

    private func makeWebSocketURL(serverURL: String, token: String) -> URL? {
        let normalizedServerURL = normalizeServerURL(serverURL)
        guard var components = URLComponents(string: normalizedServerURL) else { return nil }
        guard components.host != nil else { return nil }

        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: components.scheme = "ws"
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/\(basePath.isEmpty ? "stream" : "\(basePath)/stream")"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }

    private func normalizeServerURL(_ serverURL: String) -> String {
        guard !serverURL.contains("://") else { return serverURL }
        return "https://\(serverURL)"
    }

    private func listen(connectionID: UUID) {
        task?.receive { [weak self] result in
            guard let self else { return }
            guard self.activeConnectionID == connectionID else { return }

            switch result {
            case .failure(let error):
                self.publishState(.failed("连接失败: \(self.describe(error))"))
                self.scheduleReconnectIfNeeded(connectionID: connectionID)
            case .success(let message):
                self.handle(message)
                self.listen(connectionID: connectionID)
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data

        switch message {
        case .data(let d):
            data = d
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            return
        }

        if let gotifyMessage = try? decoder.decode(GotifyMessage.self, from: data) {
            Task { @MainActor in
                self.onMessage?(gotifyMessage)
            }
        }
    }

    private func scheduleReconnectIfNeeded(connectionID: UUID) {
        guard !isManuallyStopped else { return }
        guard activeConnectionID == connectionID else { return }

        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.isManuallyStopped else { return }
            guard self.activeConnectionID == connectionID else { return }
            self.connect(serverURL: self.latestServerURL, token: self.latestToken)
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private func publishState(_ state: ConnectionState) {
        Task { @MainActor in
            self.onStateChange?(state)
        }
    }

    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)(\(nsError.code)) \(nsError.localizedDescription)"
    }
}
