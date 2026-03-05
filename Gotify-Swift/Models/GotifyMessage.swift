import Foundation

struct GotifyMessage: Identifiable, Decodable {
    let id: Int
    let appID: Int?
    let title: String
    let message: String
    let priority: Int?
    let date: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case appID = "appid"
        case title
        case message
        case priority
        case date
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        appID = try container.decodeIfPresent(Int.self, forKey: .appID)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        message = try container.decode(String.self, forKey: .message)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)

        if let dateString = try container.decodeIfPresent(String.self, forKey: .date) {
            date = Self.parseDate(dateString)
        } else {
            date = nil
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        if let parsed = Self.iso8601WithFractional.date(from: text) {
            return parsed
        }
        return Self.iso8601Basic.date(from: text)
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
