import Foundation

struct AppSettings: Codable {
    var recursive: Bool = false
    var seekSeconds: Double = 15
    var removeDuplicatesAutomatically: Bool = true
    var browserApp: String = ""
    var browserPrivate: Bool = false
    var recentSourceDirectories: [String] = []
    var recentDestinationDirectories: [String] = []

    private enum CodingKeys: String, CodingKey {
        case recursive
        case seekSeconds
        case removeDuplicatesAutomatically
        case browserApp
        case browserPrivate
        case recentSourceDirectories
        case recentDestinationDirectories
        case recentDirectories
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recursive = try container.decodeIfPresent(Bool.self, forKey: .recursive) ?? false
        seekSeconds = try container.decodeIfPresent(Double.self, forKey: .seekSeconds) ?? 15
        removeDuplicatesAutomatically = try container.decodeIfPresent(Bool.self, forKey: .removeDuplicatesAutomatically) ?? true
        browserApp = try container.decodeIfPresent(String.self, forKey: .browserApp) ?? ""
        browserPrivate = try container.decodeIfPresent(Bool.self, forKey: .browserPrivate) ?? false

        let legacyRecent = try container.decodeIfPresent([String].self, forKey: .recentDirectories) ?? []
        recentSourceDirectories = try container.decodeIfPresent([String].self, forKey: .recentSourceDirectories) ?? legacyRecent
        recentDestinationDirectories = try container.decodeIfPresent([String].self, forKey: .recentDestinationDirectories) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recursive, forKey: .recursive)
        try container.encode(seekSeconds, forKey: .seekSeconds)
        try container.encode(removeDuplicatesAutomatically, forKey: .removeDuplicatesAutomatically)
        try container.encode(browserApp, forKey: .browserApp)
        try container.encode(browserPrivate, forKey: .browserPrivate)
        try container.encode(recentSourceDirectories, forKey: .recentSourceDirectories)
        try container.encode(recentDestinationDirectories, forKey: .recentDestinationDirectories)
    }

    mutating func pushRecentSourceDirectory(_ url: URL, maxCount: Int = 5) {
        let value = url.path
        var next = [value]
        next.append(contentsOf: recentSourceDirectories.filter { $0 != value })
        recentSourceDirectories = Array(next.prefix(maxCount))
    }

    mutating func pushRecentDestinationDirectory(_ url: URL, maxCount: Int = 5) {
        let value = url.path
        var next = [value]
        next.append(contentsOf: recentDestinationDirectories.filter { $0 != value })
        recentDestinationDirectories = Array(next.prefix(maxCount))
    }
}
