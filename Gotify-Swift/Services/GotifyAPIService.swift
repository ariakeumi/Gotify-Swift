import Foundation

final class GotifyAPIService {
    struct MessagePage {
        let messages: [GotifyMessage]
        let nextSince: Int?
    }

    enum APIError: LocalizedError {
        case invalidInput
        case invalidURL
        case invalidResponse
        case httpError(statusCode: Int, details: String)

        var errorDescription: String? {
            switch self {
            case .invalidInput:
                return "服务器地址或 Token 为空"
            case .invalidURL:
                return "服务器地址格式不正确"
            case .invalidResponse:
                return "服务器返回了无效响应"
            case .httpError(let statusCode, let details):
                if details.isEmpty {
                    return "HTTP \(statusCode)"
                }
                return "HTTP \(statusCode): \(details)"
            }
        }
    }

    func fetchRecentMessages(serverURL rawServerURL: String, token rawToken: String, limit: Int = 50) async throws -> [GotifyMessage] {
        let serverURL = rawServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty, !token.isEmpty else { throw APIError.invalidInput }
        guard let baseURL = normalizedBaseURL(from: serverURL) else { throw APIError.invalidURL }

        var components = URLComponents(url: baseURL.appendingPathComponent("message"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "limit", value: "\(max(1, limit))")
        ]
        guard let url = components?.url else { throw APIError.invalidURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let details = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(statusCode: http.statusCode, details: details)
        }

        let decoder = JSONDecoder()
        let payload = try decoder.decode(MessagesPayload.self, from: data)
        return payload.messages
    }

    func fetchMessagesPage(
        serverURL rawServerURL: String,
        token rawToken: String,
        limit: Int = 100,
        since: Int?
    ) async throws -> MessagePage {
        let serverURL = rawServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty, !token.isEmpty else { throw APIError.invalidInput }
        guard let baseURL = normalizedBaseURL(from: serverURL) else { throw APIError.invalidURL }

        var components = URLComponents(url: baseURL.appendingPathComponent("message"), resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "limit", value: "\(max(1, limit))")
        ]
        if let since {
            queryItems.append(URLQueryItem(name: "since", value: "\(since)"))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw APIError.invalidURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let details = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(statusCode: http.statusCode, details: details)
        }

        let decoder = JSONDecoder()
        let payload = try decoder.decode(MessagesPayload.self, from: data)
        return MessagePage(messages: payload.messages, nextSince: payload.nextSince)
    }

    func fetchApplications(serverURL rawServerURL: String, token rawToken: String) async throws -> [GotifyApplication] {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw APIError.invalidInput }
        let url = try buildURL(serverURL: rawServerURL, path: "application")
        let (data, response) = try await request(url: url, token: token)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let details = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(statusCode: http.statusCode, details: details)
        }
        let decoder = JSONDecoder()
        return try decoder.decode(ApplicationsPayload.self, from: data).applications
    }

    func fetchAppIcon(
        serverURL rawServerURL: String,
        token rawToken: String,
        appID: Int,
        imageRef: String?
    ) async throws -> Data {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw APIError.invalidInput }
        let candidateURLs = try buildImageCandidateURLs(serverURL: rawServerURL, appID: appID, imageRef: imageRef)

        var lastError: Error = APIError.invalidResponse
        for url in candidateURLs {
            do {
                let (data, response) = try await request(url: url, token: token)
                guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
                guard (200...299).contains(http.statusCode) else {
                    let details = String(data: data, encoding: .utf8) ?? ""
                    throw APIError.httpError(statusCode: http.statusCode, details: details)
                }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func deleteMessage(serverURL rawServerURL: String, token rawToken: String, messageID: Int) async throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw APIError.invalidInput }

        let headerURL = try buildURL(serverURL: rawServerURL, path: "message/\(messageID)")
        do {
            _ = try await deleteRequest(url: headerURL, token: token, useHeader: true)
            return
        } catch {
            var components = URLComponents(url: headerURL, resolvingAgainstBaseURL: false)
            var query = components?.queryItems ?? []
            query.append(URLQueryItem(name: "token", value: token))
            components?.queryItems = query
            guard let fallbackURL = components?.url else { throw APIError.invalidURL }
            _ = try await deleteRequest(url: fallbackURL, token: token, useHeader: false)
        }
    }

    private func normalizedBaseURL(from rawServerURL: String) -> URL? {
        let normalized = rawServerURL.contains("://") ? rawServerURL : "https://\(rawServerURL)"
        guard var components = URLComponents(string: normalized) else { return nil }
        guard components.host != nil else { return nil }
        if components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url
    }

    private func buildURL(serverURL: String, path: String) throws -> URL {
        guard let baseURL = normalizedBaseURL(from: serverURL) else { throw APIError.invalidURL }
        return baseURL.appendingPathComponent(path)
    }

    private func buildImageCandidateURLs(serverURL: String, appID: Int, imageRef: String?) throws -> [URL] {
        guard let baseURL = normalizedBaseURL(from: serverURL) else { throw APIError.invalidURL }
        var urls: [URL] = []

        if let imageRef, !imageRef.isEmpty {
            if let absolute = URL(string: imageRef), absolute.scheme != nil {
                urls.append(absolute)
            } else if imageRef.hasPrefix("/") {
                if var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
                    comps.path = imageRef
                    if let url = comps.url {
                        urls.append(url)
                    }
                }
            } else if imageRef.hasPrefix("image/") {
                urls.append(baseURL.appendingPathComponent(imageRef))
            } else {
                urls.append(baseURL.appendingPathComponent("image").appendingPathComponent(imageRef))
            }
        }

        urls.append(baseURL.appendingPathComponent("image").appendingPathComponent("\(appID)"))

        var seen: Set<URL> = []
        return urls.filter { seen.insert($0).inserted }
    }

    private func request(url: URL, token: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Gotify-Key")
        return try await URLSession.shared.data(for: request)
    }

    private func deleteRequest(url: URL, token: String, useHeader: Bool) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        if useHeader {
            request.setValue(token, forHTTPHeaderField: "X-Gotify-Key")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let details = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(statusCode: http.statusCode, details: details)
        }
        return (data, response)
    }
}

private struct MessagesPayload: Decodable {
    let messages: [GotifyMessage]
    let nextSince: Int?

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            messages = try keyed.decodeIfPresent([GotifyMessage].self, forKey: .messages) ?? []
            if let paging = try keyed.decodeIfPresent(Paging.self, forKey: .paging) {
                nextSince = paging.nextSince
            } else {
                nextSince = nil
            }
            return
        }
        let single = try decoder.singleValueContainer()
        messages = try single.decode([GotifyMessage].self)
        nextSince = nil
    }

    private enum CodingKeys: String, CodingKey {
        case messages
        case paging
    }

    private struct Paging: Decodable {
        let next: String?

        var nextSince: Int? {
            guard let next, !next.isEmpty else { return nil }
            guard let components = URLComponents(string: next) else { return nil }
            return components.queryItems?.first(where: { $0.name == "since" })?.value.flatMap(Int.init)
        }
    }
}

private struct ApplicationsPayload: Decodable {
    let applications: [GotifyApplication]

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            applications = try keyed.decodeIfPresent([GotifyApplication].self, forKey: .applications) ?? []
            return
        }
        let single = try decoder.singleValueContainer()
        applications = try single.decode([GotifyApplication].self)
    }

    private enum CodingKeys: String, CodingKey {
        case applications
    }
}
