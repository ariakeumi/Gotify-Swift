import Foundation

actor AppIconCache {
    private var memoryCache: [String: Data] = [:]
    private let cacheDirectory: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        cacheDirectory = base.appendingPathComponent("GotifyIconCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func load(forKey key: String) -> Data? {
        if let data = memoryCache[key] {
            return data
        }
        let fileURL = cacheDirectory.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        memoryCache[key] = data
        return data
    }

    func store(_ data: Data, forKey key: String) {
        memoryCache[key] = data
        let fileURL = cacheDirectory.appendingPathComponent(key)
        try? data.write(to: fileURL, options: .atomic)
    }
}
