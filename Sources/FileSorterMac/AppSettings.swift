import Foundation

struct AppSettings: Codable {
    var recursive: Bool = false
    var seekSeconds: Double = 15
    var removeDuplicatesAutomatically: Bool = true
    var defaultMode: String = "manual"
    var autoSortConfidenceThreshold: Double = 0.8
    var autoCreateUsernameFolders: Bool = true
    var duplicatePreviewAutoplay: Bool = true
    var largeBatchTagConfirmationThreshold: Int = 100
    var browserApp: String = ""
    var browserPrivate: Bool = false
    var trackedPeople: [String] = []
    var personFaceHashesByName: [String: [UInt64]] = [:]
    var personRejectedFaceHashesByName: [String: [UInt64]] = [:]
    var personFileHashesByName: [String: [String]] = [:]
    var personRejectedFileHashesByName: [String: [String]] = [:]
    var recentSourceDirectories: [String] = []
    var recentDestinationDirectories: [String] = []

    private enum CodingKeys: String, CodingKey {
        case recursive
        case seekSeconds
        case removeDuplicatesAutomatically
        case defaultMode
        case autoSortConfidenceThreshold
        case autoCreateUsernameFolders
        case duplicatePreviewAutoplay
        case largeBatchTagConfirmationThreshold
        case browserApp
        case browserPrivate
        case similarityTrainingEnabled
        case similarityLearnedFacePairs
        case trackedPeople
        case personFaceHashesByName
        case personRejectedFaceHashesByName
        case personFileHashesByName
        case personRejectedFileHashesByName
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
        defaultMode = try container.decodeIfPresent(String.self, forKey: .defaultMode) ?? "manual"
        autoSortConfidenceThreshold = try container.decodeIfPresent(Double.self, forKey: .autoSortConfidenceThreshold) ?? 0.8
        autoCreateUsernameFolders = try container.decodeIfPresent(Bool.self, forKey: .autoCreateUsernameFolders) ?? true
        duplicatePreviewAutoplay = try container.decodeIfPresent(Bool.self, forKey: .duplicatePreviewAutoplay) ?? true
        largeBatchTagConfirmationThreshold = try container.decodeIfPresent(Int.self, forKey: .largeBatchTagConfirmationThreshold) ?? 100
        browserApp = try container.decodeIfPresent(String.self, forKey: .browserApp) ?? ""
        browserPrivate = try container.decodeIfPresent(Bool.self, forKey: .browserPrivate) ?? false
        trackedPeople = try container.decodeIfPresent([String].self, forKey: .trackedPeople) ?? []
        personFaceHashesByName = try container.decodeIfPresent([String: [UInt64]].self, forKey: .personFaceHashesByName) ?? [:]
        personRejectedFaceHashesByName = try container.decodeIfPresent([String: [UInt64]].self, forKey: .personRejectedFaceHashesByName) ?? [:]
        personFileHashesByName = try container.decodeIfPresent([String: [String]].self, forKey: .personFileHashesByName) ?? [:]
        personRejectedFileHashesByName = try container.decodeIfPresent([String: [String]].self, forKey: .personRejectedFileHashesByName) ?? [:]

        _ = try container.decodeIfPresent(Bool.self, forKey: .similarityTrainingEnabled)
        _ = try container.decodeIfPresent([String].self, forKey: .similarityLearnedFacePairs)

        let legacyRecent = try container.decodeIfPresent([String].self, forKey: .recentDirectories) ?? []
        recentSourceDirectories = try container.decodeIfPresent([String].self, forKey: .recentSourceDirectories) ?? legacyRecent
        recentDestinationDirectories = try container.decodeIfPresent([String].self, forKey: .recentDestinationDirectories) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recursive, forKey: .recursive)
        try container.encode(seekSeconds, forKey: .seekSeconds)
        try container.encode(removeDuplicatesAutomatically, forKey: .removeDuplicatesAutomatically)
        try container.encode(defaultMode, forKey: .defaultMode)
        try container.encode(autoSortConfidenceThreshold, forKey: .autoSortConfidenceThreshold)
        try container.encode(autoCreateUsernameFolders, forKey: .autoCreateUsernameFolders)
        try container.encode(duplicatePreviewAutoplay, forKey: .duplicatePreviewAutoplay)
        try container.encode(largeBatchTagConfirmationThreshold, forKey: .largeBatchTagConfirmationThreshold)
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

    var hasLegacyPeopleRecognitionData: Bool {
        !trackedPeople.isEmpty ||
        !personFaceHashesByName.isEmpty ||
        !personRejectedFaceHashesByName.isEmpty ||
        !personFileHashesByName.isEmpty ||
        !personRejectedFileHashesByName.isEmpty
    }

    mutating func clearLegacyPeopleRecognitionData() {
        trackedPeople = []
        personFaceHashesByName = [:]
        personRejectedFaceHashesByName = [:]
        personFileHashesByName = [:]
        personRejectedFileHashesByName = [:]
    }
}
