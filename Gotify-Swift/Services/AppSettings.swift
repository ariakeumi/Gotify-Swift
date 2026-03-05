import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Keys.serverURL) }
    }

    @Published var clientToken: String {
        didSet { UserDefaults.standard.set(clientToken, forKey: Keys.clientToken) }
    }

    @Published var messageFontSize: Double {
        didSet { UserDefaults.standard.set(messageFontSize, forKey: Keys.messageFontSize) }
    }

    private enum Keys {
        static let serverURL = "gotify.serverURL"
        static let clientToken = "gotify.clientToken"
        static let messageFontSize = "gotify.messageFontSize"
    }

    private init() {
        serverURL = UserDefaults.standard.string(forKey: Keys.serverURL) ?? ""
        clientToken = UserDefaults.standard.string(forKey: Keys.clientToken) ?? ""
        let savedSize = UserDefaults.standard.double(forKey: Keys.messageFontSize)
        messageFontSize = savedSize == 0 ? 14 : savedSize
    }
}
