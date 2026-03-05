import Foundation

struct GotifyApplication: Identifiable, Decodable, Hashable {
    let id: Int
    let name: String
    let image: String?
    let description: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case image
        case description
    }
}
