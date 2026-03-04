import CryptoKit
import Foundation
import AppKit
import AVFoundation
import ImageIO
import Vision

@MainActor
final class AppModel: ObservableObject {
    private enum SessionFileOutcome {
        case moved
        case duplicate
        case renamed
        case skipped
    }

    private struct FolderSuggestion {
        let folder: String
        let hint: String
        let sourceDetail: String?
        let debugMessage: String?

        init(folder: String, hint: String, sourceDetail: String? = nil, debugMessage: String? = nil) {
            self.folder = folder
            self.hint = hint
            self.sourceDetail = sourceDetail
            self.debugMessage = debugMessage
        }
    }

    private struct FilenameSeriesInfo {
        let key: String
        let part: Int
        let total: Int?
        let kind: Kind

        enum Kind {
            case bracketed
            case numberedPrefix
        }
    }

    private enum UndoActionKind {
        case skipped
        case moved(resultURL: URL)
        case duplicated(trashedURL: URL?)
    }

    private struct UndoAction {
        let id = UUID()
        let sourceOriginalURL: URL
        let kind: UndoActionKind
        let previousSelection: String?
    }

    private struct DeletedPersonSnapshot {
        let name: String
        let faceHashes: Set<UInt64>
        let rejectedFaceHashes: Set<UInt64>
        let fileHashes: Set<String>
        let rejectedFileHashes: Set<String>
        let taggedPaths: [String]
        let selectedGroupIDs: [UUID]
        let reportGroupIDs: [UUID]
    }

    private struct ModeScanCache {
        let directoryPath: String
        let recursive: Bool
        let report: DuplicateScanReport
    }

    enum AppMode: String, Codable, CaseIterable, Identifiable {
        case manual
        case autoSort
        case duplicateFinder
        case similarityFinder

        var id: String { rawValue }

        var title: String {
            switch self {
            case .manual:
                return "Manual"
            case .autoSort:
                return "Auto Sort"
            case .duplicateFinder:
                return "Duplicate Finder"
            case .similarityFinder:
                return "People"
            }
        }
    }

    enum AutoSortItemOutcome: String, Codable {
        case moved
        case duplicate
        case renamed
        case needsReview
        case failed
    }

    struct AutoSortReportItem: Identifiable, Equatable {
        let id: UUID
        let sourcePath: String
        let fileName: String
        let targetFolder: String?
        let confidence: Double
        let outcome: AutoSortItemOutcome
        let message: String
        let undoActionID: UUID?
        var isUndone: Bool
    }

    struct AutoSortReport: Identifiable {
        let id = UUID()
        let startedAt: Date
        let finishedAt: Date
        let confidenceThreshold: Double
        var items: [AutoSortReportItem]

        var processedCount: Int { items.count }
        var movedCount: Int { items.filter { $0.outcome == .moved }.count }
        var duplicateCount: Int { items.filter { $0.outcome == .duplicate }.count }
        var renamedCount: Int { items.filter { $0.outcome == .renamed }.count }
        var reviewCount: Int { items.filter { $0.outcome == .needsReview }.count }
        var failedCount: Int { items.filter { $0.outcome == .failed }.count }
        var actionItems: [AutoSortReportItem] {
            items.filter {
                $0.outcome == .moved || $0.outcome == .duplicate || $0.outcome == .renamed
            }
        }
    }

    enum DuplicateMatchKind: String, Codable {
        case exactHash
        case similarMetadata
    }

    struct DuplicateCandidateFile: Identifiable, Equatable {
        let id = UUID()
        let path: String
        let name: String
        let size: Int64
        let durationSeconds: Double?
    }

    struct DuplicateCandidateGroup: Identifiable, Equatable {
        let id = UUID()
        let kind: DuplicateMatchKind
        let score: Double
        let reason: String
        let files: [DuplicateCandidateFile]
        var resolvedKeeperPaths: [String]?
        var resolvedDestinationFolder: String?
        var personName: String? = nil
        var isPersonReview: Bool = false
        var knownMatchPaths: [String]? = nil
    }

    struct DuplicateScanReport: Identifiable {
        let id = UUID()
        let startedAt: Date
        let finishedAt: Date
        let scannedFileCount: Int
        var groups: [DuplicateCandidateGroup]

        var exactGroupCount: Int { groups.filter { $0.kind == .exactHash }.count }
        var similarGroupCount: Int { groups.filter { $0.kind == .similarMetadata }.count }
        var resolvedGroupCount: Int { groups.filter { $0.resolvedKeeperPaths != nil }.count }
    }

    struct DuplicateScanProgress {
        enum Phase: String {
            case collecting = "Collecting Files"
            case profiling = "Profiling Metadata"
            case hashing = "Hash Matching"
            case comparing = "Similarity Matching"
            case faceMatching = "Face Matching"
            case personScoring = "Scoring People"
            case finalizing = "Finalizing"
        }

        let phase: Phase
        let currentFileName: String?
        let processed: Int
        let total: Int
        let startedAt: Date
        let potentialGroupCount: Int
        let exactGroupCount: Int
        let similarGroupCount: Int
        let faceIndexedCount: Int
        let faceMatchCount: Int
        let visualMatchCount: Int
        let personScoringPeopleProcessed: Int
        let personScoringPeopleTotal: Int
        let personScoringFilesProcessed: Int
        let personScoringFilesTotal: Int
        let personScoringMatchCount: Int

        init(
            phase: Phase,
            currentFileName: String?,
            processed: Int,
            total: Int,
            startedAt: Date = Date(),
            potentialGroupCount: Int = 0,
            exactGroupCount: Int = 0,
            similarGroupCount: Int = 0,
            faceIndexedCount: Int = 0,
            faceMatchCount: Int = 0,
            visualMatchCount: Int = 0,
            personScoringPeopleProcessed: Int = 0,
            personScoringPeopleTotal: Int = 0,
            personScoringFilesProcessed: Int = 0,
            personScoringFilesTotal: Int = 0,
            personScoringMatchCount: Int = 0
        ) {
            self.phase = phase
            self.currentFileName = currentFileName
            self.processed = processed
            self.total = total
            self.startedAt = startedAt
            self.potentialGroupCount = potentialGroupCount
            self.exactGroupCount = exactGroupCount
            self.similarGroupCount = similarGroupCount
            self.faceIndexedCount = faceIndexedCount
            self.faceMatchCount = faceMatchCount
            self.visualMatchCount = visualMatchCount
            self.personScoringPeopleProcessed = personScoringPeopleProcessed
            self.personScoringPeopleTotal = personScoringPeopleTotal
            self.personScoringFilesProcessed = personScoringFilesProcessed
            self.personScoringFilesTotal = personScoringFilesTotal
            self.personScoringMatchCount = personScoringMatchCount
        }

        var fractionComplete: Double {
            guard total > 0 else { return 0 }
            return max(0, min(1, Double(processed) / Double(total)))
        }
    }

    enum ActivitySeverity: String {
        case info
        case success
        case warning
        case error
    }

    struct ActivityLogEntry: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let severity: ActivitySeverity
    }

    struct SessionSummarySnapshot {
        let directoryPath: String?
        let processed: Int
        let total: Int
        let moved: Int
        let duplicates: Int
        let renamed: Int
        let skipped: Int
    }

    @Published private(set) var settings: AppSettings
    @Published private(set) var configPath: String

    @Published private(set) var currentDirectory: URL?
    @Published private(set) var destinationDirectoryOverride: URL?
    @Published private(set) var files: [URL] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var folders: [String] = []
    @Published private(set) var isLoadingDirectory: Bool = false
    @Published private(set) var appMode: AppMode = .manual
    @Published private(set) var isAutoSorting: Bool = false
    @Published private(set) var autoSortReport: AutoSortReport?
    @Published private(set) var isDuplicateScanning: Bool = false
    @Published private(set) var isDuplicateScanPaused: Bool = false
    @Published private(set) var duplicateScanReport: DuplicateScanReport?
    @Published private(set) var duplicateScanProgress: DuplicateScanProgress?
    @Published private(set) var selectedDuplicateGroupID: UUID?
    @Published private(set) var showKnownPersonReviewBatches: Bool = false
    @Published private(set) var focusedPersonSearchName: String?
    @Published private(set) var selectedDuplicateKeeperByGroupID: [UUID: Set<String>] = [:]
    @Published private(set) var selectedSimilarityTrainingByGroupID: [UUID: Set<String>] = [:]
    @Published private(set) var selectedPersonForGroupID: [UUID: String] = [:]
    @Published private(set) var trackedPeople: [String] = []
    @Published private(set) var taggedPersonByPath: [String: Set<String>] = [:]
    @Published private(set) var rejectedPersonMatchPathsByGroupID: [UUID: Set<String>] = [:]

    @Published var folderQuery: String = ""
    @Published var selectedFolder: String?
    @Published var statusMessage: String = "" {
        didSet {
            guard !statusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard statusMessage != oldValue else { return }
            let severity = classifySeverity(for: statusMessage)
            appendActivity(message: statusMessage, severity: severity)
            if let toast = toastSummary(for: statusMessage) {
                showStatusToast(message: toast, severity: severity)
            }
        }
    }
    @Published var removeDuplicatesAutomatically: Bool = true
    @Published private(set) var transientToastMessage: String = ""
    @Published private(set) var currentFileIcon: NSImage?
    @Published private(set) var currentFileMetadataLine: String = ""
    @Published private(set) var currentFileSourceURLs: [URL] = []
    @Published private(set) var isLoadingCurrentFileSources: Bool = false
    @Published private(set) var currentFolderSuggestionHint: String = ""
    @Published private(set) var currentFolderSuggestionSourceDetail: String = ""
    @Published private(set) var currentSuggestedFolder: String?
    @Published private(set) var lastMovedFolderContext: String?
    @Published private(set) var closedSessionSummary: SessionSummarySnapshot?
    @Published private(set) var activityLog: [ActivityLogEntry] = []
    @Published private(set) var statusToastEntry: ActivityLogEntry?
    @Published private(set) var sessionMovedCount: Int = 0
    @Published private(set) var sessionDuplicateCount: Int = 0
    @Published private(set) var sessionRenamedCount: Int = 0
    @Published private(set) var sessionSkippedCount: Int = 0

    private let configStore: ConfigStore
    private let peopleStore: PeopleRecognitionStore
    private let usernameRegex = try? NSRegularExpression(pattern: "@([A-Za-z0-9_]{2,32})")
    private let filenameSeriesRegex = try? NSRegularExpression(pattern: #"^\s*\d+\s*-\s*(.+?)\s*\[(\d+)\s*-\s*(\d+)\]\s*$"#)
    private let numberedPrefixRegex = try? NSRegularExpression(pattern: #"^\s*(\d{1,6})\s*-\s*(.+?)\s*$"#)
    private var lastSeekByPath: [String: Double] = [:]
    private let imageExt: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "tif", "heic"]
    private let videoExt: Set<String> = ["mp4", "mov", "avi", "mkv", "m4v", "webm", "flv"]
    private let audioExt: Set<String> = ["mp3", "wav", "aac", "flac", "m4a", "ogg", "opus"]
    private var rebuildTask: Task<Void, Never>?
    private var autoSortTask: Task<Void, Never>?
    private var duplicateScanTask: Task<Void, Never>?
    private var rebuildGeneration: Int = 0
    private var sessionOutcomeByPath: [String: SessionFileOutcome] = [:]
    private var sourceURLsByFilePath: [String: [URL]] = [:]
    private var suggestedFolderBySeriesKey: [String: String] = [:]
    private var destinationSeriesFolderByKey: [String: String] = [:]
    private var lastSuggestionDebugLogKey: String?
    private var statusToastTask: Task<Void, Never>?
    private var undoHistory: [UndoAction] = []
    private var pendingDuplicateRescanAfterRebuild: Bool = false
    private var duplicateHashCacheByFingerprint: [String: String] = [:]
    private var duplicateDurationCacheByFingerprint: [String: Double] = [:]
    private var duplicateVisualSignatureCacheByFingerprint: [String: DuplicateVisualSignature] = [:]
    private var duplicateVisualHashMissesByFingerprint = Set<String>()
    private var duplicateFaceHashesByPath: [String: [UInt64]] = [:]
    private var scanHashMissCount: Int = 0
    private var scanHashMissTotalSeconds: Double = 0
    private var learnedPersonFaceHashesByName: [String: Set<UInt64>] = [:]
    private var rejectedPersonFaceHashesByName: [String: Set<UInt64>] = [:]
    private var learnedPersonFileHashesByName: [String: Set<String>] = [:]
    private var rejectedPersonFileHashesByName: [String: Set<String>] = [:]
    private var deletedPeopleHistory: [DeletedPersonSnapshot] = []
    private var duplicateFinderScanCache: ModeScanCache?
    private var peopleScanCache: ModeScanCache?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let activityTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    init(configStore: ConfigStore = ConfigStore()) {
        self.configStore = configStore
        self.settings = configStore.load()
        self.configPath = configStore.configURL.path
        self.peopleStore = PeopleRecognitionStore(directoryURL: configStore.configURL.deletingLastPathComponent())
        self.removeDuplicatesAutomatically = self.settings.removeDuplicatesAutomatically
        self.appMode = AppMode(rawValue: self.settings.defaultMode) ?? .manual

        let didMigratePeopleData = bootstrapPeopleRecognitionState(legacySettings: self.settings)

        if self.settings.hasLegacyPeopleRecognitionData {
            var next = self.settings
            next.clearLegacyPeopleRecognitionData()
            self.settings = next
            self.configStore.save(next)
        }

        self.configStore.save(self.settings)

        if didMigratePeopleData {
            statusMessage = "People data migration complete. SQLite storage is now active."
        }
    }

    deinit {
        rebuildTask?.cancel()
        autoSortTask?.cancel()
        duplicateScanTask?.cancel()
        statusToastTask?.cancel()
    }

    var recentSourceDirectories: [String] {
        settings.recentSourceDirectories
    }

    var recentDestinationDirectories: [String] {
        settings.recentDestinationDirectories
    }

    var recursive: Bool {
        settings.recursive
    }

    var seekSeconds: Double {
        settings.seekSeconds
    }

    var defaultRemoveDuplicatesAutomatically: Bool {
        settings.removeDuplicatesAutomatically
    }

    var autoSortConfidenceThreshold: Double {
        settings.autoSortConfidenceThreshold
    }

    var autoCreateUsernameFoldersEnabled: Bool {
        settings.autoCreateUsernameFolders
    }

    var duplicatePreviewAutoplayEnabled: Bool {
        settings.duplicatePreviewAutoplay
    }

    var largeBatchTagConfirmationThreshold: Int {
        max(10, settings.largeBatchTagConfirmationThreshold)
    }

    var browserApp: String {
        settings.browserApp
    }

    var browserPrivate: Bool {
        settings.browserPrivate
    }

    var resolvedBrowserAppPath: String? {
        let appName = settings.browserApp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appName.isEmpty else { return nil }
        return resolvedBrowserAppURL(for: appName)?.path
    }

    var currentFile: URL? {
        guard index >= 0, index < files.count else { return nil }
        return files[index]
    }

    var destinationDirectory: URL? {
        destinationDirectoryOverride ?? currentDirectory
    }

    var destinationSummary: String {
        if let destinationDirectoryOverride {
            return destinationDirectoryOverride.path
        }
        return "Source folder"
    }

    var hasDestinationOverride: Bool {
        destinationDirectoryOverride != nil
    }

    var hasActiveVideoPreview: Bool {
        guard let currentFile else { return false }
        return videoExt.contains(currentFile.pathExtension.lowercased())
    }

    var hasActivePreviewFile: Bool {
        currentFile != nil
    }

    var contextualPinnedFolder: String? {
        if let suggested = currentSuggestedFolder,
           folders.contains(where: { $0.caseInsensitiveCompare(suggested) == .orderedSame }) {
            return suggested
        }

        if let lastMovedFolderContext,
           folders.contains(where: { $0.caseInsensitiveCompare(lastMovedFolderContext) == .orderedSame }) {
            return lastMovedFolderContext
        }

        return nil
    }

    var canUndo: Bool {
        !undoHistory.isEmpty
    }

    var canUndoDeletedPerson: Bool {
        !deletedPeopleHistory.isEmpty
    }

    var hasClosedSessionSummary: Bool {
        closedSessionSummary != nil && currentDirectory == nil && currentFile == nil
    }

    var isSessionComplete: Bool {
        guard currentDirectory != nil else { return false }
        guard !isLoadingDirectory else { return false }
        guard !files.isEmpty else { return false }
        return currentFile == nil
    }

    var isSessionEmpty: Bool {
        guard currentDirectory != nil else { return false }
        guard !isLoadingDirectory else { return false }
        return files.isEmpty
    }

    var sessionProcessedCount: Int {
        sessionOutcomeByPath.count
    }

    var sessionTotalCount: Int {
        files.count
    }

    var progressLine: String {
        guard let directory = currentDirectory else { return "No folder selected" }
        if isLoadingDirectory {
            return "Loading… • \(directory.path)"
        }
        return "\(min(index + 1, max(files.count, 1)))/\(files.count) • \(directory.path)"
    }

    func activityTimestamp(for date: Date) -> String {
        Self.activityTimeFormatter.string(from: date)
    }

    func setRecursive(_ value: Bool) {
        let current = currentFile
        mutateSettings { $0.recursive = value }
        invalidateModeScanCaches()

        if appMode == .duplicateFinder || appMode == .similarityFinder,
           isDuplicateScanning || duplicateScanReport != nil {
            stopDuplicateScan()
            duplicateScanReport = nil
            duplicateScanProgress = nil
            selectedDuplicateGroupID = nil
            selectedDuplicateKeeperByGroupID = [:]
            selectedSimilarityTrainingByGroupID = [:]
            selectedPersonForGroupID = [:]
            taggedPersonByPath = [:]
            rejectedPersonMatchPathsByGroupID = [:]
            pendingDuplicateRescanAfterRebuild = true
            statusMessage = "Recursive setting changed — re-running duplicate scan…"
        }

        if let directory = currentDirectory {
            rebuildSession(directory: directory, recursive: value, preferredCurrent: current)
        }
    }

    func setSeekSeconds(_ value: Double) {
        let clamped = max(1, min(120, value.rounded()))
        let previous = settings.seekSeconds
        mutateSettings { $0.seekSeconds = clamped }
        if previous != clamped {
            statusMessage = "Seek step set to \(Int(clamped)) seconds."
        }
    }

    func setRemoveDuplicatesAutomatically(_ value: Bool) {
        removeDuplicatesAutomatically = value
        statusMessage = value ? "Remove Duplicates enabled." : "Remove Duplicates disabled."
    }

    func setDefaultRemoveDuplicatesAutomatically(_ value: Bool) {
        mutateSettings { $0.removeDuplicatesAutomatically = value }
        statusMessage = value ? "Default duplicate removal enabled." : "Default duplicate removal disabled."
    }

    func setAppMode(_ value: AppMode) {
        let previousMode = appMode
        appMode = value
        mutateSettings { $0.defaultMode = value.rawValue }

        let wasScanMode = previousMode == .duplicateFinder || previousMode == .similarityFinder
        let isScanMode = value == .duplicateFinder || value == .similarityFinder

        if value != .autoSort {
            stopAutoSort()
        }
        if value != .duplicateFinder && value != .similarityFinder {
            stopDuplicateScan()
        }

        if wasScanMode || isScanMode {
            duplicateScanProgress = nil
            duplicateScanReport = nil
            selectedDuplicateGroupID = nil
            selectedDuplicateKeeperByGroupID = [:]
            selectedSimilarityTrainingByGroupID = [:]
            selectedPersonForGroupID = [:]
            taggedPersonByPath = [:]
            rejectedPersonMatchPathsByGroupID = [:]
            duplicateFaceHashesByPath = [:]
        }

        if isScanMode,
           let directory = currentDirectory,
           !isLoadingDirectory {
            if let cachedReport = cachedScanReport(for: value, directory: directory, recursive: recursive) {
                duplicateScanReport = cachedReport
                ensureSelectedDuplicateGroupIsVisible()
                statusMessage = "Mode set to \(value.title) (loaded cached scan)."
                return
            }

            startDuplicateScan()
            statusMessage = "Mode set to \(value.title). Re-running mode-specific scan…"
            return
        }

        if (previousMode == .duplicateFinder || previousMode == .similarityFinder),
           (value != .duplicateFinder && value != .similarityFinder),
           let directory = currentDirectory {
            let preferredCurrent = currentFile
            pruneMissingFilesFromSession()
            rebuildSession(directory: directory, recursive: recursive, preferredCurrent: preferredCurrent)
        }

        statusMessage = "Mode set to \(value.title)."
    }

    func setAutoSortConfidenceThreshold(_ value: Double) {
        let clamped = max(0.5, min(0.99, value))
        mutateSettings { $0.autoSortConfidenceThreshold = clamped }
        statusMessage = "Auto-sort confidence set to \(Int((clamped * 100).rounded()))%."
    }

    func setAutoCreateUsernameFoldersEnabled(_ value: Bool) {
        mutateSettings { $0.autoCreateUsernameFolders = value }
        statusMessage = value ? "Auto-create username folders enabled." : "Auto-create username folders disabled."
    }

    func setDuplicatePreviewAutoplayEnabled(_ value: Bool) {
        mutateSettings { $0.duplicatePreviewAutoplay = value }
        statusMessage = value ? "Preview autoplay enabled." : "Preview autoplay disabled."
    }

    func setLargeBatchTagConfirmationThreshold(_ value: Int) {
        let clamped = max(10, min(1000, value))
        mutateSettings { $0.largeBatchTagConfirmationThreshold = clamped }
        statusMessage = "Batch tag confirm threshold set to \(clamped) files."
    }

    @discardableResult
    func addTrackedPerson(_ rawName: String) -> String? {
        guard let name = normalizedPersonName(rawName) else { return nil }
        let isNew = !trackedPeople.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        if isNew {
            trackedPeople.append(name)
            trackedPeople.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        if learnedPersonFaceHashesByName[name] == nil {
            learnedPersonFaceHashesByName[name] = []
        }
        if rejectedPersonFaceHashesByName[name] == nil {
            rejectedPersonFaceHashesByName[name] = []
        }
        if learnedPersonFileHashesByName[name] == nil {
            learnedPersonFileHashesByName[name] = []
        }
        if rejectedPersonFileHashesByName[name] == nil {
            rejectedPersonFileHashesByName[name] = []
        }

        persistPeopleRecognitionSettings()
        statusMessage = isNew ? "Now tracking person: \(name)." : "Person already tracked: \(name)."
        return name
    }

    func removeTrackedPerson(_ name: String) {
        let taggedPaths = taggedPersonByPath.compactMap { path, names in
            names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) ? path : nil
        }
        let selectedGroupIDs = selectedPersonForGroupID.compactMap { groupID, selectedName in
            selectedName.caseInsensitiveCompare(name) == .orderedSame ? groupID : nil
        }
        let reportGroupIDs: [UUID] = duplicateScanReport?.groups.compactMap { group in
            guard let personName = group.personName,
                  personName.caseInsensitiveCompare(name) == .orderedSame
            else { return nil }
            return group.id
        } ?? []

        let snapshot = DeletedPersonSnapshot(
            name: name,
            faceHashes: learnedPersonFaceHashesByName[name] ?? [],
            rejectedFaceHashes: rejectedPersonFaceHashesByName[name] ?? [],
            fileHashes: learnedPersonFileHashesByName[name] ?? [],
            rejectedFileHashes: rejectedPersonFileHashesByName[name] ?? [],
            taggedPaths: taggedPaths,
            selectedGroupIDs: selectedGroupIDs,
            reportGroupIDs: reportGroupIDs
        )
        deletedPeopleHistory.append(snapshot)

        trackedPeople.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        learnedPersonFaceHashesByName.removeValue(forKey: name)
        rejectedPersonFaceHashesByName.removeValue(forKey: name)
        learnedPersonFileHashesByName.removeValue(forKey: name)
        rejectedPersonFileHashesByName.removeValue(forKey: name)
        selectedPersonForGroupID = selectedPersonForGroupID.filter { $0.value.caseInsensitiveCompare(name) != .orderedSame }
        taggedPersonByPath = taggedPersonByPath.reduce(into: [:]) { result, pair in
            let filtered = pair.value.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
            if !filtered.isEmpty {
                result[pair.key] = Set(filtered)
            }
        }

        if var report = duplicateScanReport {
            for index in report.groups.indices {
                if report.groups[index].personName?.caseInsensitiveCompare(name) == .orderedSame {
                    report.groups[index].personName = nil
                    report.groups[index].isPersonReview = false
                }
            }
            duplicateScanReport = report
        }

        persistPeopleRecognitionSettings()
        statusMessage = "Removed person: \(name)."
    }

    func undoLastDeletedPerson() {
        guard let snapshot = deletedPeopleHistory.popLast() else {
            statusMessage = "Nothing to undo for person deletion."
            return
        }

        if !trackedPeople.contains(where: { $0.caseInsensitiveCompare(snapshot.name) == .orderedSame }) {
            trackedPeople.append(snapshot.name)
            trackedPeople.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        learnedPersonFaceHashesByName[snapshot.name] = snapshot.faceHashes
        rejectedPersonFaceHashesByName[snapshot.name] = snapshot.rejectedFaceHashes
        learnedPersonFileHashesByName[snapshot.name] = snapshot.fileHashes
        rejectedPersonFileHashesByName[snapshot.name] = snapshot.rejectedFileHashes

        for groupID in snapshot.selectedGroupIDs {
            selectedPersonForGroupID[groupID] = snapshot.name
        }

        for path in snapshot.taggedPaths {
            var tags = taggedPersonByPath[path] ?? []
            tags.insert(snapshot.name)
            taggedPersonByPath[path] = tags
        }

        if var report = duplicateScanReport {
            for index in report.groups.indices where snapshot.reportGroupIDs.contains(report.groups[index].id) {
                report.groups[index].personName = snapshot.name
                report.groups[index].isPersonReview = true
            }
            duplicateScanReport = report
        }

        persistPeopleRecognitionSettings()
        statusMessage = "Restored deleted person: \(snapshot.name)."
    }

    func renameTrackedPerson(oldName: String, newRawName: String) {
        guard let newName = normalizedPersonName(newRawName) else {
            statusMessage = "Enter a valid person name."
            return
        }

        guard oldName.caseInsensitiveCompare(newName) != .orderedSame else {
            statusMessage = "Name unchanged."
            return
        }

        if trackedPeople.contains(where: { $0.caseInsensitiveCompare(newName) == .orderedSame }) {
            statusMessage = "A person named \(newName) already exists."
            return
        }

        guard let oldIndex = trackedPeople.firstIndex(where: { $0.caseInsensitiveCompare(oldName) == .orderedSame }) else {
            statusMessage = "Person not found: \(oldName)."
            return
        }

        trackedPeople[oldIndex] = newName
        learnedPersonFaceHashesByName[newName] = learnedPersonFaceHashesByName.removeValue(forKey: oldName) ?? []
        rejectedPersonFaceHashesByName[newName] = rejectedPersonFaceHashesByName.removeValue(forKey: oldName) ?? []
        learnedPersonFileHashesByName[newName] = learnedPersonFileHashesByName.removeValue(forKey: oldName) ?? []
        rejectedPersonFileHashesByName[newName] = rejectedPersonFileHashesByName.removeValue(forKey: oldName) ?? []

        for (groupID, selectedName) in selectedPersonForGroupID where selectedName.caseInsensitiveCompare(oldName) == .orderedSame {
            selectedPersonForGroupID[groupID] = newName
        }
        for (path, taggedNames) in taggedPersonByPath {
            if taggedNames.contains(where: { $0.caseInsensitiveCompare(oldName) == .orderedSame }) {
                var updated = taggedNames.filter { $0.caseInsensitiveCompare(oldName) != .orderedSame }
                updated.insert(newName)
                taggedPersonByPath[path] = Set(updated)
            }
        }

        if var report = duplicateScanReport {
            for idx in report.groups.indices {
                if report.groups[idx].personName?.caseInsensitiveCompare(oldName) == .orderedSame {
                    report.groups[idx].personName = newName
                }
            }
            duplicateScanReport = report
        }

        persistPeopleRecognitionSettings()
        statusMessage = "Renamed \(oldName) to \(newName)."
    }

    func setSelectedPersonForGroup(groupID: UUID, rawName: String) {
        guard let name = addTrackedPerson(rawName) else {
            selectedPersonForGroupID.removeValue(forKey: groupID)
            return
        }
        selectedPersonForGroupID[groupID] = name
        statusMessage = "Selected \(name) for this batch."
    }

    func selectedPersonName(for group: DuplicateCandidateGroup) -> String? {
        if let selected = selectedPersonForGroupID[group.id], !selected.isEmpty {
            return selected
        }
        if let personName = group.personName, !personName.isEmpty {
            return personName
        }
        return trackedPeople.first
    }

    func taggedPersonName(for path: String) -> String? {
        taggedPeople(for: path).first
    }

    func taggedPeople(for path: String) -> [String] {
        Array(taggedPersonByPath[path] ?? [])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var canTagCurrentFileAsPerson: Bool {
        guard appMode == .manual,
              let currentFile
        else { return false }
        let ext = currentFile.pathExtension.lowercased()
        return imageExt.contains(ext) || videoExt.contains(ext)
    }

    var currentFileTaggedPeople: [String] {
        guard let currentFile else { return [] }
        return taggedPeople(for: currentFile.path)
    }

    @discardableResult
    func tagCurrentFileAsPerson(rawPersonName: String) -> Bool {
        guard appMode == .manual else {
            statusMessage = "Switch to Manual mode first."
            return false
        }

        guard let currentFile else {
            statusMessage = "No active file."
            return false
        }

        guard canTagCurrentFileAsPerson else {
            statusMessage = "People tags are available only for images/videos in Manual mode."
            return false
        }

        guard let personName = addTrackedPerson(rawPersonName) else {
            statusMessage = "Enter a person name first."
            return false
        }

        var tags = taggedPersonByPath[currentFile.path] ?? []
        let wasInserted = tags.insert(personName).inserted
        taggedPersonByPath[currentFile.path] = tags

        if let faceHashes = duplicateFaceHashesByPath[currentFile.path],
           !faceHashes.isEmpty {
            learnedPersonFaceHashesByName[personName, default: []].formUnion(faceHashes)
            rejectedPersonFaceHashesByName[personName] = (rejectedPersonFaceHashesByName[personName] ?? []).subtracting(faceHashes)
        }

        addKnownFileHashForPerson(path: currentFile.path, personName: personName)
        persistPeopleRecognitionSettings()
        selectedFolder = preferredSelectionForCurrentFile(fallback: selectedFolder)
        updateCurrentFilePresentation()

        statusMessage = wasInserted ? "Tagged as \(personName)." : "Already tagged as \(personName)."
        return true
    }

    func untagCurrentFilePerson(personName: String) {
        guard appMode == .manual,
              let currentFile
        else { return }

        untagSimilarityMatch(path: currentFile.path, personName: personName)
        selectedFolder = preferredSelectionForCurrentFile(fallback: selectedFolder)
        updateCurrentFilePresentation()
    }

    func detectedPeopleCount(for path: String) -> Int {
        duplicateFaceHashesByPath[path]?.count ?? 0
    }

    func isRejectedPersonMatch(groupID: UUID, path: String) -> Bool {
        rejectedPersonMatchPathsByGroupID[groupID]?.contains(path) ?? false
    }

    private func shouldAutoRejectReviewingPerson(path: String, reviewingPerson: String, addingPerson personName: String) -> Bool {
        guard reviewingPerson.caseInsensitiveCompare(personName) != .orderedSame else { return false }

        let detectedCount = detectedPeopleCount(for: path)
        if detectedCount <= 1 {
            return true
        }

        var prospectiveTags = taggedPersonByPath[path] ?? []
        prospectiveTags.insert(personName)

        let reviewingAlreadyTagged = prospectiveTags.contains {
            $0.caseInsensitiveCompare(reviewingPerson) == .orderedSame
        }
        if reviewingAlreadyTagged {
            return false
        }

        return prospectiveTags.count >= detectedCount
    }

    func tagSimilarityMatch(groupID: UUID, path: String, rawPersonName: String) {
        guard appMode == .similarityFinder else { return }
        guard let personName = addTrackedPerson(rawPersonName) else {
            statusMessage = "Enter a person name first."
            return
        }

        let faceHashes = duplicateFaceHashesByPath[path] ?? []

        if let report = duplicateScanReport,
           let group = report.groups.first(where: { $0.id == groupID }),
           group.isPersonReview,
           let reviewingPerson = group.personName,
           shouldAutoRejectReviewingPerson(path: path, reviewingPerson: reviewingPerson, addingPerson: personName) {
            confirmPersonMatch(groupID: groupID, path: path, isMatch: false)
        }

        selectedPersonForGroupID[groupID] = personName
        var tags = taggedPersonByPath[path] ?? []
        tags.insert(personName)
        taggedPersonByPath[path] = tags
        if !faceHashes.isEmpty {
            learnedPersonFaceHashesByName[personName, default: []].formUnion(faceHashes)
            rejectedPersonFaceHashesByName[personName] = (rejectedPersonFaceHashesByName[personName] ?? []).subtracting(faceHashes)
        }
        addKnownFileHashForPerson(path: path, personName: personName)
        persistPeopleRecognitionSettings()
        statusMessage = "Tagged as \(personName)."
    }

    func tagSimilarityBatch(groupID: UUID, rawPersonName: String, paths: [String]? = nil) {
        guard appMode == .similarityFinder else { return }
        guard let personName = addTrackedPerson(rawPersonName) else {
            statusMessage = "Enter a person name first."
            return
        }

        guard let report = duplicateScanReport,
              let group = report.groups.first(where: { $0.id == groupID })
        else {
            statusMessage = "Similarity group not found."
            return
        }

        let targetPaths: [String]
        if let paths {
            let valid = Set(group.files.map(\ .path))
            targetPaths = paths.filter { valid.contains($0) }
        } else {
            targetPaths = group.files.map(\ .path)
        }

        guard !targetPaths.isEmpty else {
            statusMessage = "No files available to tag in this batch."
            return
        }

        selectedPersonForGroupID[groupID] = personName

        let reviewingPerson = (group.isPersonReview ? group.personName : nil)
        var taggedCount = 0
        var noFaceCount = 0
        var autoNoCount = 0

        for path in targetPaths {
            let faceHashes = duplicateFaceHashesByPath[path] ?? []
            let hasDetectedFaces = !faceHashes.isEmpty
            if !hasDetectedFaces {
                noFaceCount += 1
            }

                if let reviewingPerson,
                    shouldAutoRejectReviewingPerson(path: path, reviewingPerson: reviewingPerson, addingPerson: personName) {
                rejectedPersonMatchPathsByGroupID[groupID, default: []].insert(path)
                if var tags = taggedPersonByPath[path], tags.contains(where: { $0.caseInsensitiveCompare(reviewingPerson) == .orderedSame }) {
                    tags = Set(tags.filter { $0.caseInsensitiveCompare(reviewingPerson) != .orderedSame })
                    if tags.isEmpty {
                        taggedPersonByPath.removeValue(forKey: path)
                    } else {
                        taggedPersonByPath[path] = tags
                    }
                }
                if hasDetectedFaces {
                    rejectedPersonFaceHashesByName[reviewingPerson, default: []].formUnion(faceHashes)
                }
                addRejectedFileHashForPerson(path: path, personName: reviewingPerson)
                autoNoCount += 1
            }

            var tags = taggedPersonByPath[path] ?? []
            tags.insert(personName)
            taggedPersonByPath[path] = tags
            if hasDetectedFaces {
                learnedPersonFaceHashesByName[personName, default: []].formUnion(faceHashes)
                rejectedPersonFaceHashesByName[personName] = (rejectedPersonFaceHashesByName[personName] ?? []).subtracting(faceHashes)
            }
            addKnownFileHashForPerson(path: path, personName: personName)
            taggedCount += 1
        }

        persistPeopleRecognitionSettings()

        var summary = "Tagged \(taggedCount) file"
        if taggedCount != 1 { summary += "s" }
        summary += " as \(personName)."
        if autoNoCount > 0 {
            summary += " Auto-marked No for \(autoNoCount) file"
            if autoNoCount != 1 { summary += "s" }
            summary += " in current review person."
        }
        if noFaceCount > 0 {
            summary += " \(noFaceCount) tagged without detected faces (excluded from face-learning)."
        }
        statusMessage = summary
    }

    func confirmPersonMatch(groupID: UUID, path: String, isMatch: Bool) {
        guard appMode == .similarityFinder else { return }
        guard let report = duplicateScanReport,
              let group = report.groups.first(where: { $0.id == groupID }),
              let personName = group.personName,
              !personName.isEmpty
        else { return }

        let faceHashes = duplicateFaceHashesByPath[path] ?? []
        let hasDetectedFaces = !faceHashes.isEmpty

        if isMatch {
            var tags = taggedPersonByPath[path] ?? []
            tags.insert(personName)
            taggedPersonByPath[path] = tags
            rejectedPersonMatchPathsByGroupID[groupID]?.remove(path)
            if rejectedPersonMatchPathsByGroupID[groupID]?.isEmpty == true {
                rejectedPersonMatchPathsByGroupID.removeValue(forKey: groupID)
            }
            if hasDetectedFaces {
                learnedPersonFaceHashesByName[personName, default: []].formUnion(faceHashes)
                rejectedPersonFaceHashesByName[personName] = (rejectedPersonFaceHashesByName[personName] ?? []).subtracting(faceHashes)
            }
            addKnownFileHashForPerson(path: path, personName: personName)
            statusMessage = "Confirmed \(personName)."
        } else {
            rejectedPersonMatchPathsByGroupID[groupID, default: []].insert(path)
            if var tags = taggedPersonByPath[path], tags.contains(where: { $0.caseInsensitiveCompare(personName) == .orderedSame }) {
                tags = Set(tags.filter { $0.caseInsensitiveCompare(personName) != .orderedSame })
                if tags.isEmpty {
                    taggedPersonByPath.removeValue(forKey: path)
                } else {
                    taggedPersonByPath[path] = tags
                }
            }
            if hasDetectedFaces {
                rejectedPersonFaceHashesByName[personName, default: []].formUnion(faceHashes)
            }
            addRejectedFileHashForPerson(path: path, personName: personName)
            statusMessage = "Marked as not \(personName)."
        }
        persistPeopleRecognitionSettings()
    }

    func untagSimilarityMatch(path: String, personName: String) {
        guard var tags = taggedPersonByPath[path] else { return }
        let previousCount = tags.count
        tags = Set(tags.filter { $0.caseInsensitiveCompare(personName) != .orderedSame })
        guard tags.count != previousCount else { return }

        if tags.isEmpty {
            taggedPersonByPath.removeValue(forKey: path)
        } else {
            taggedPersonByPath[path] = tags
        }

        let hash = cachedOrComputeFileHash(at: URL(fileURLWithPath: path))
        if !hash.isEmpty {
            learnedPersonFileHashesByName[personName]?.remove(hash)
        }

        persistPeopleRecognitionSettings()
        statusMessage = "Removed tag \(personName)."
    }

    func confirmSelectedPersonMatches(groupID: UUID, isMatch: Bool) {
        guard let report = duplicateScanReport,
              let group = report.groups.first(where: { $0.id == groupID })
        else { return }

        let selected = selectedSimilarityTrainingPaths(for: group)
        guard !selected.isEmpty else {
            statusMessage = "Select at least one file first."
            return
        }

        for path in selected {
            confirmPersonMatch(groupID: groupID, path: path, isMatch: isMatch)
        }
    }

    func clearAutoSortReport() {
        autoSortReport = nil
        statusMessage = "Cleared auto-sort report."
    }

    func clearDuplicateScanReport() {
        clearScanCache(for: appMode)
        duplicateScanReport = nil
        selectedDuplicateGroupID = nil
        selectedDuplicateKeeperByGroupID = [:]
        selectedSimilarityTrainingByGroupID = [:]
        selectedPersonForGroupID = [:]
        taggedPersonByPath = [:]
        rejectedPersonMatchPathsByGroupID = [:]
        duplicateFaceHashesByPath = [:]
        statusMessage = "Cleared scan report."
    }


    func toggleSimilarityTrainingSelection(groupID: UUID, path: String) {
        guard let report = duplicateScanReport,
              let group = report.groups.first(where: { $0.id == groupID }),
              group.resolvedKeeperPaths == nil,
              group.files.contains(where: { $0.path == path })
        else { return }

        var selected = selectedSimilarityTrainingByGroupID[groupID] ?? []
        if selected.contains(path) {
            selected.remove(path)
        } else {
            selected.insert(path)
        }

        if selected.isEmpty {
            selectedSimilarityTrainingByGroupID.removeValue(forKey: groupID)
        } else {
            selectedSimilarityTrainingByGroupID[groupID] = selected
        }

        statusMessage = selected.isEmpty ? "Selection cleared for batch." : "Selection updated (\(selected.count) selected)."
    }

    func selectedSimilarityTrainingPaths(for group: DuplicateCandidateGroup) -> Set<String> {
        guard let selected = selectedSimilarityTrainingByGroupID[group.id],
              !selected.isEmpty
        else {
            return []
        }

        let valid = selected.filter { path in
            group.files.contains(where: { $0.path == path })
        }
        return Set(valid)
    }

    func selectedSimilarityTrainingCount(for group: DuplicateCandidateGroup) -> Int {
        selectedSimilarityTrainingPaths(for: group).count
    }

    func selectDuplicateGroup(_ groupID: UUID) {
        guard let report = duplicateScanReport,
              visibleDuplicateGroups(in: report).contains(where: { $0.id == groupID })
        else { return }
        selectedDuplicateGroupID = groupID
    }

    func setShowKnownPersonReviewBatches(_ value: Bool) {
        showKnownPersonReviewBatches = value
        ensureSelectedDuplicateGroupIsVisible()
    }

    func runFocusedPersonSearch(_ rawPersonName: String) {
        guard appMode == .similarityFinder else {
            statusMessage = "Switch to People mode first."
            return
        }

        guard let personName = normalizedPersonName(rawPersonName) else {
            statusMessage = "Enter a valid person name."
            return
        }

        guard trackedPeople.contains(where: { $0.caseInsensitiveCompare(personName) == .orderedSame }) else {
            statusMessage = "Track \(personName) first before searching."
            return
        }

        focusedPersonSearchName = personName
        restartDuplicateScan()
    }

    func clearFocusedPersonSearch() {
        guard focusedPersonSearchName != nil else { return }
        focusedPersonSearchName = nil
        if appMode == .similarityFinder {
            restartDuplicateScan()
        }
    }

    func moveDuplicateGroupSelection(direction: Int) {
        guard let report = duplicateScanReport,
              !report.groups.isEmpty
        else { return }

        let visibleGroups = visibleDuplicateGroups(in: report)
        guard !visibleGroups.isEmpty else {
            selectedDuplicateGroupID = nil
            return
        }

        let currentIndex: Int
        if let selectedDuplicateGroupID,
           let found = visibleGroups.firstIndex(where: { $0.id == selectedDuplicateGroupID }) {
            currentIndex = found
        } else {
            currentIndex = 0
        }

        let nextIndex = max(0, min(visibleGroups.count - 1, currentIndex + direction))
        selectedDuplicateGroupID = visibleGroups[nextIndex].id
    }

    func chooseDuplicateKeeperByNumber(_ number: Int) {
        guard appMode != .similarityFinder else { return }
        guard number >= 1,
              let group = selectedDuplicateGroup(),
              number <= group.files.count
        else { return }

        let keeperPath = group.files[number - 1].path
        toggleDuplicateKeeper(groupID: group.id, keeperPath: keeperPath)
    }

    func setDuplicateKeeper(groupID: UUID, keeperPath: String) {
        guard let report = duplicateScanReport,
              let group = report.groups.first(where: { $0.id == groupID }),
              group.resolvedKeeperPaths == nil,
              group.files.contains(where: { $0.path == keeperPath })
        else { return }

        selectedDuplicateKeeperByGroupID[groupID] = [keeperPath]
    }

    func toggleDuplicateKeeper(groupID: UUID, keeperPath: String) {
        guard let report = duplicateScanReport,
              let group = report.groups.first(where: { $0.id == groupID }),
              group.resolvedKeeperPaths == nil,
              group.files.contains(where: { $0.path == keeperPath })
        else { return }

        var selected = selectedDuplicateKeeperByGroupID[groupID] ?? Set(group.files.prefix(1).map(\ .path))
        if selected.contains(keeperPath) {
            selected.remove(keeperPath)
        } else {
            selected.insert(keeperPath)
        }

        if selected.isEmpty,
           let fallback = group.files.first?.path {
            selected.insert(fallback)
        }

        selectedDuplicateKeeperByGroupID[groupID] = selected
    }

    func selectedKeeperPaths(for group: DuplicateCandidateGroup) -> Set<String> {
        if let resolved = group.resolvedKeeperPaths {
            return Set(resolved)
        }

        if let selected = selectedDuplicateKeeperByGroupID[group.id],
           !selected.isEmpty {
            let valid = selected.filter { path in
                group.files.contains(where: { $0.path == path })
            }
            if !valid.isEmpty {
                return valid
            }
        }

        if let fallback = group.files.first?.path {
            return [fallback]
        }

        return []
    }

    func selectedKeeperPath(for group: DuplicateCandidateGroup) -> String {
        if let resolved = group.resolvedKeeperPaths?.first {
            return resolved
        }

        let selected = selectedKeeperPaths(for: group)
        if let first = selected.first {
            return first
        }

        return group.files.first?.path ?? ""
    }

    func selectedKeeperCount(for group: DuplicateCandidateGroup) -> Int {
        selectedKeeperPaths(for: group).count
    }

    func isDuplicateGroupResolved(_ groupID: UUID) -> Bool {
        guard let report = duplicateScanReport,
              let group = report.groups.first(where: { $0.id == groupID })
        else { return false }
        return group.resolvedKeeperPaths != nil
    }

    func duplicateGroupPosition(for groupID: UUID) -> Int? {
        guard let report = duplicateScanReport,
              let idx = visibleDuplicateGroups(in: report).firstIndex(where: { $0.id == groupID })
        else { return nil }
        return idx + 1
    }

    func duplicateGroupTotalCount() -> Int {
        guard let report = duplicateScanReport else { return 0 }
        return visibleDuplicateGroups(in: report).count
    }

    func applySelectedDuplicateResolution() {
        guard let group = selectedDuplicateGroup() else { return }
        guard group.resolvedKeeperPaths == nil else {
            statusMessage = "Selected duplicate group is already resolved."
            return
        }

        if appMode == .similarityFinder {
            resolveSimilarityGroup(groupID: group.id)
            return
        }

        let keepers = selectedKeeperPaths(for: group)
        guard !keepers.isEmpty else {
            statusMessage = "Select at least one file to keep."
            return
        }

        resolveDuplicateGroup(groupID: group.id, keeperPaths: keepers)
    }

    func resolveDuplicateGroup(groupID: UUID, keeperPath: String) {
        resolveDuplicateGroup(groupID: groupID, keeperPaths: [keeperPath])
    }

    func resolveDuplicateGroup(groupID: UUID, keeperPaths: Set<String>) {
        if appMode == .similarityFinder {
            resolveSimilarityGroup(groupID: groupID)
            return
        }

        guard !keeperPaths.isEmpty else {
            statusMessage = "Select at least one file to keep."
            return
        }

        guard var report = duplicateScanReport,
              let groupIndex = report.groups.firstIndex(where: { $0.id == groupID })
        else {
            statusMessage = "Duplicate group not found."
            return
        }

        var group = report.groups[groupIndex]
        guard group.resolvedKeeperPaths == nil else {
            statusMessage = "That duplicate group is already resolved."
            return
        }

        let validKeeperPaths = keeperPaths.filter { path in
            group.files.contains(where: { $0.path == path })
        }
        guard !validKeeperPaths.isEmpty else {
            statusMessage = "Selected keepers are not in that group."
            return
        }

        var removedCount = 0
        var failures: [String] = []

        for file in group.files where !validKeeperPaths.contains(file.path) {
            do {
                if FileManager.default.fileExists(atPath: file.path) {
                    var trashedURL: NSURL?
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: &trashedURL)
                    removedCount += 1
                }
            } catch {
                failures.append(file.name)
            }
        }

        group.resolvedKeeperPaths = Array(validKeeperPaths)
        group.resolvedDestinationFolder = nil
        selectedDuplicateKeeperByGroupID[groupID] = validKeeperPaths
        report.groups[groupIndex] = group

        let nextUnresolvedAfterCurrent = report.groups[(groupIndex + 1)...].first { $0.resolvedKeeperPaths == nil }?.id
        let firstUnresolved = report.groups.first { $0.resolvedKeeperPaths == nil }?.id

        if let nextGroupID = nextUnresolvedAfterCurrent ?? firstUnresolved {
            selectedDuplicateGroupID = nextGroupID
        } else {
            selectedDuplicateGroupID = nil
        }

        duplicateScanReport = report

        let resolvedPosition = groupIndex + 1
        let totalGroups = report.groups.count
        if failures.isEmpty {
            statusMessage = "Resolved group \(resolvedPosition)/\(totalGroups): kept \(validKeeperPaths.count), moved \(removedCount) to Trash."
        } else {
            statusMessage = "Partial resolve \(resolvedPosition)/\(totalGroups): moved \(removedCount), failed \(failures.count)."
        }
    }

    func resolveSimilarityGroup(groupID: UUID) {
        guard appMode == .similarityFinder else {
            statusMessage = "Switch to People mode first."
            return
        }

        guard let destinationBase = destinationDirectory else {
            statusMessage = "Open a folder before sorting similarity groups."
            return
        }

        guard var report = duplicateScanReport,
              let groupIndex = report.groups.firstIndex(where: { $0.id == groupID })
        else {
            statusMessage = "Similarity group not found."
            return
        }

        let group = report.groups[groupIndex]
        guard group.resolvedKeeperPaths == nil else {
            statusMessage = "That similarity group is already sorted."
            return
        }

        let selectedPaths = selectedSimilarityTrainingPaths(for: group)
        let pathsToSort: Set<String> = selectedPaths.isEmpty ? Set(group.files.map(\ .path)) : selectedPaths

        let peopleRoot = destinationBase.appendingPathComponent("People Matches", isDirectory: true)
        let personFolder = suggestedSimilarityFolderName(for: group, sequence: groupIndex + 1)
        let targetDir = peopleRoot.appendingPathComponent(personFolder, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } catch {
            statusMessage = "Failed to create person folder: \(error.localizedDescription)"
            presentErrorSheet(title: "Create Folder Failed", message: error.localizedDescription)
            return
        }

        var sortedCount = 0
        var failures: [String] = []
        var movedOriginalPaths: [String] = []

        for file in group.files where pathsToSort.contains(file.path) {
            let sourceURL = URL(fileURLWithPath: file.path)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                failures.append(file.name)
                continue
            }

            do {
                let movedURL = try moveForSimilarityGrouping(source: sourceURL, targetDirectory: targetDir)
                sortedCount += 1
                movedOriginalPaths.append(file.path)
                registerSessionOutcome(movedURL.lastPathComponent == sourceURL.lastPathComponent ? .moved : .renamed, for: file.path)
            } catch {
                failures.append(file.name)
            }
        }

        guard !movedOriginalPaths.isEmpty else {
            statusMessage = "No files were sorted from that similarity group."
            return
        }

        let sortedPathSet = Set(movedOriginalPaths)
        let sortedFiles = group.files.filter { sortedPathSet.contains($0.path) }
        let remainingFiles = group.files.filter { !sortedPathSet.contains($0.path) }

        var replacementGroups: [DuplicateCandidateGroup] = [
            DuplicateCandidateGroup(
                kind: group.kind,
                score: group.score,
                reason: group.reason,
                files: sortedFiles,
                resolvedKeeperPaths: movedOriginalPaths,
                resolvedDestinationFolder: "People Matches/\(personFolder)"
            )
        ]

        if remainingFiles.count >= 2 {
            replacementGroups.append(
                DuplicateCandidateGroup(
                    kind: group.kind,
                    score: group.score,
                    reason: group.reason,
                    files: remainingFiles,
                    resolvedKeeperPaths: nil,
                    resolvedDestinationFolder: nil
                )
            )
        }

        report.groups.remove(at: groupIndex)
        report.groups.insert(contentsOf: replacementGroups, at: groupIndex)
        selectedSimilarityTrainingByGroupID.removeValue(forKey: groupID)
        selectedDuplicateKeeperByGroupID.removeValue(forKey: groupID)

        let nextUnresolvedAfterCurrent = report.groups[(groupIndex)...].first { $0.resolvedKeeperPaths == nil }?.id
        let firstUnresolved = report.groups.first { $0.resolvedKeeperPaths == nil }?.id

        if let nextGroupID = nextUnresolvedAfterCurrent ?? firstUnresolved {
            selectedDuplicateGroupID = nextGroupID
        } else {
            selectedDuplicateGroupID = nil
        }

        duplicateScanReport = report

        let resolvedPosition = groupIndex + 1
        let totalGroups = report.groups.count
        if failures.isEmpty {
            statusMessage = "Sorted group \(resolvedPosition)/\(totalGroups) into People Matches/\(personFolder) (\(sortedCount) files)."
        } else {
            statusMessage = "Partially sorted group \(resolvedPosition)/\(totalGroups): moved \(sortedCount), failed \(failures.count)."
        }
    }

    func startAutoSort() {
        guard appMode == .autoSort else {
            statusMessage = "Switch to Auto Sort mode first."
            return
        }

        guard currentDirectory != nil else {
            statusMessage = "Open a folder before starting auto-sort."
            return
        }

        guard !isLoadingDirectory else {
            statusMessage = "Wait for folder loading to finish."
            return
        }

        guard autoSortTask == nil else { return }

        autoSortReport = nil
        autoSortTask = Task { await runAutoSortLoop() }
    }

    func stopAutoSort() {
        autoSortTask?.cancel()
        autoSortTask = nil
        isAutoSorting = false
    }

    func startDuplicateScan() {
        guard appMode == .duplicateFinder || appMode == .similarityFinder else {
            statusMessage = "Switch to Duplicate Finder or People mode first."
            return
        }

        guard let currentDirectory else {
            statusMessage = "Open a folder before running duplicate scan."
            return
        }

        guard !isLoadingDirectory else {
            statusMessage = "Wait for folder loading to finish."
            return
        }

        guard duplicateScanTask == nil else { return }

        isDuplicateScanPaused = false
        duplicateScanReport = nil
        selectedDuplicateGroupID = nil
        selectedDuplicateKeeperByGroupID = [:]
        selectedSimilarityTrainingByGroupID = [:]
        selectedPersonForGroupID = [:]
        taggedPersonByPath = [:]
        rejectedPersonMatchPathsByGroupID = [:]
        duplicateScanProgress = DuplicateScanProgress(phase: .collecting, currentFileName: nil, processed: 0, total: 0)
        let includeExactMatches = appMode == .duplicateFinder
        let enableFaceMatching = appMode == .similarityFinder
        let focusedPersonName = appMode == .similarityFinder ? focusedPersonSearchName : nil
        duplicateScanTask = Task {
            await runDuplicateScanLoop(
                directory: currentDirectory,
                recursive: recursive,
                includeExactMatches: includeExactMatches,
                enableFaceMatching: enableFaceMatching,
                focusedPersonName: focusedPersonName
            )
        }
    }

    func pauseDuplicateScan() {
        guard duplicateScanTask != nil,
              isDuplicateScanning,
              !isDuplicateScanPaused
        else { return }

        isDuplicateScanPaused = true
        statusMessage = "Duplicate scan paused."
    }

    func resumeDuplicateScan() {
        guard duplicateScanTask != nil,
              isDuplicateScanning,
              isDuplicateScanPaused
        else { return }

        isDuplicateScanPaused = false
        statusMessage = "Duplicate scan resumed."
    }

    func restartDuplicateScan() {
        guard appMode == .duplicateFinder || appMode == .similarityFinder else {
            statusMessage = "Switch to Duplicate Finder or People mode first."
            return
        }

        stopDuplicateScan()
        startDuplicateScan()
    }

    func stopDuplicateScan() {
        duplicateScanTask?.cancel()
        duplicateScanTask = nil
        isDuplicateScanning = false
        isDuplicateScanPaused = false
        duplicateScanProgress = nil
        selectedSimilarityTrainingByGroupID = [:]
        selectedPersonForGroupID = [:]
        taggedPersonByPath = [:]
        rejectedPersonMatchPathsByGroupID = [:]
        duplicateFaceHashesByPath = [:]
    }

    func undoAutoSortItem(_ itemID: UUID) {
        guard var report = autoSortReport,
              let reportIndex = report.items.firstIndex(where: { $0.id == itemID })
        else {
            statusMessage = "Auto-sort result item not found."
            return
        }

        let item = report.items[reportIndex]
        guard !item.isUndone else {
            statusMessage = "That item is already undone."
            return
        }

        guard let undoActionID = item.undoActionID,
              let undoIndex = undoHistory.firstIndex(where: { $0.id == undoActionID })
        else {
            statusMessage = "Undo details are unavailable for this item."
            return
        }

        let action = undoHistory.remove(at: undoIndex)

        do {
            let message = try applyUndoAction(action)
            report.items[reportIndex].isUndone = true
            autoSortReport = report
            statusMessage = message
        } catch {
            statusMessage = "Undo failed: \(error.localizedDescription)"
            presentErrorSheet(title: "Undo Failed", message: error.localizedDescription)
        }
    }

    func chooseFolderInteractive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"

        if panel.runModal() == .OK, let directory = panel.url {
            startSession(directory: directory, recursive: recursive)
        }
    }

    func chooseDestinationInteractive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Destination"

        if panel.runModal() == .OK, let directory = panel.url {
            setDestinationOverride(directory.standardizedFileURL)
            statusMessage = "Destination override set."
        }
    }

    func clearDestinationOverride() {
        guard destinationDirectoryOverride != nil else { return }
        destinationDirectoryOverride = nil
        refreshDestinationFolders()
        statusMessage = "Destination reset to source folder."
    }

    func setBrowserApp(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        mutateSettings { $0.browserApp = trimmed }
        statusMessage = trimmed.isEmpty ? "Browser set to System Default." : "Browser set to \(trimmed)."
    }

    func setBrowserPrivate(_ value: Bool) {
        mutateSettings { $0.browserPrivate = value }
        statusMessage = value ? "Browser private mode enabled." : "Browser private mode disabled."
    }

    func availableBrowserApps() -> [String] {
        guard let probeURL = URL(string: "https://example.com") else {
            return browserApp.isEmpty ? [] : [browserApp]
        }

        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: probeURL)
        var names = Set<String>()

        for appURL in appURLs {
            if let bundle = Bundle(url: appURL) {
                if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                   !displayName.isEmpty {
                    names.insert(displayName)
                    continue
                }

                if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                   !name.isEmpty {
                    names.insert(name)
                    continue
                }
            }

            names.insert(appURL.deletingPathExtension().lastPathComponent)
        }

        if !browserApp.isEmpty {
            names.insert(browserApp)
        }

        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func openBrowserContext() {
        guard let file = currentFile else {
            statusMessage = "No active file."
            return
        }

        let base = file.deletingPathExtension().lastPathComponent
        let sourceURLs = Self.metadataWhereFromURLs(for: file)
        guard let searchURL = Self.contextSearchURL(fileStem: base, sourceURLs: sourceURLs) else {
            statusMessage = "No search target available."
            presentErrorSheet(title: "No Browser Context", message: "No search target could be generated for the current file.")
            return
        }

        let opened = openURLsWithSettings([searchURL])
        statusMessage = opened ? "Opened search context." : "Failed to open browser context."
        if !opened {
            presentErrorSheet(title: "Open Context Failed", message: "The selected browser could not be launched with the requested URLs.")
        }
    }

    func openExternalURL(_ url: URL) {
        let opened = openURLsWithSettings([url])
        if !opened {
            statusMessage = "Failed to open URL."
            presentErrorSheet(title: "Open URL Failed", message: url.absoluteString)
        }
    }

    func revealCurrentInFinder() {
        guard let file = currentFile else {
            statusMessage = "No active file."
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([file])
        statusMessage = "Revealed in Finder."
    }

    func openRecentSource(path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "Recent folder unavailable: \(path)"
            presentErrorSheet(title: "Recent Folder Unavailable", message: path)
            return
        }
        startSession(directory: url, recursive: recursive)
    }

    func openRecentDestination(path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "Recent destination unavailable: \(path)"
            presentErrorSheet(title: "Recent Destination Unavailable", message: path)
            return
        }
        setDestinationOverride(url.standardizedFileURL)
        statusMessage = "Destination override set."
    }

    func startSession(directory: URL, recursive: Bool) {
        let resolved = directory.standardizedFileURL
        stopAutoSort()
        stopDuplicateScan()
        invalidateModeScanCaches()
        currentDirectory = resolved
        folderQuery = ""
        statusMessage = "Loading folder…"
        closedSessionSummary = nil
        autoSortReport = nil
        duplicateScanReport = nil
        duplicateScanProgress = nil
        selectedDuplicateGroupID = nil
        selectedDuplicateKeeperByGroupID = [:]
        selectedSimilarityTrainingByGroupID = [:]
        selectedPersonForGroupID = [:]
        taggedPersonByPath = [:]
        rejectedPersonMatchPathsByGroupID = [:]
        duplicateFaceHashesByPath = [:]
        resetSessionSummary()
        sourceURLsByFilePath = [:]
        suggestedFolderBySeriesKey = [:]
        destinationSeriesFolderByKey = [:]
        lastSuggestionDebugLogKey = nil
        lastMovedFolderContext = nil
        undoHistory = []

        mutateSettings {
            $0.recursive = recursive
            $0.pushRecentSourceDirectory(resolved)
        }

        rebuildSession(directory: resolved, recursive: recursive, preferredCurrent: nil)
    }

    func closeCurrentSession() {
        stopAutoSort()
        stopDuplicateScan()
        invalidateModeScanCaches()
        let shouldShowEarlyCloseSummary = currentDirectory != nil && currentFile != nil && sessionProcessedCount > 0
        let summarySnapshot = SessionSummarySnapshot(
            directoryPath: currentDirectory?.path,
            processed: sessionProcessedCount,
            total: sessionTotalCount,
            moved: sessionMovedCount,
            duplicates: sessionDuplicateCount,
            renamed: sessionRenamedCount,
            skipped: sessionSkippedCount
        )

        rebuildTask?.cancel()
        rebuildGeneration += 1

        currentDirectory = nil
        destinationDirectoryOverride = nil
        files = []
        index = 0
        folders = []
        isLoadingDirectory = false

        folderQuery = ""
        selectedFolder = nil
        currentFileIcon = nil
        currentFileMetadataLine = ""
        currentFileSourceURLs = []
        isLoadingCurrentFileSources = false
        currentFolderSuggestionHint = ""
        currentFolderSuggestionSourceDetail = ""
        currentSuggestedFolder = nil
        lastMovedFolderContext = nil
        closedSessionSummary = shouldShowEarlyCloseSummary ? summarySnapshot : nil
        autoSortReport = nil
        duplicateScanReport = nil
        duplicateScanProgress = nil
        selectedDuplicateGroupID = nil
        selectedDuplicateKeeperByGroupID = [:]
        selectedSimilarityTrainingByGroupID = [:]
        selectedPersonForGroupID = [:]
        taggedPersonByPath = [:]
        rejectedPersonMatchPathsByGroupID = [:]
        duplicateFaceHashesByPath = [:]
        resetSessionSummary()
        sourceURLsByFilePath = [:]
        undoHistory = []
        lastSuggestionDebugLogKey = nil
        statusMessage = "Closed folder."
    }

    func restartCurrentSession() {
        guard let currentDirectory else { return }
        stopAutoSort()
        stopDuplicateScan()
        invalidateModeScanCaches()
        folderQuery = ""
        selectedFolder = nil
        statusMessage = "Restarting folder…"
        closedSessionSummary = nil
        lastMovedFolderContext = nil
        resetSessionSummary()
        autoSortReport = nil
        duplicateScanReport = nil
        duplicateScanProgress = nil
        selectedDuplicateGroupID = nil
        selectedDuplicateKeeperByGroupID = [:]
        selectedSimilarityTrainingByGroupID = [:]
        selectedPersonForGroupID = [:]
        taggedPersonByPath = [:]
        rejectedPersonMatchPathsByGroupID = [:]
        duplicateFaceHashesByPath = [:]
        undoHistory = []
        suggestedFolderBySeriesKey = [:]
        destinationSeriesFolderByKey = [:]
        lastSuggestionDebugLogKey = nil
        rebuildSession(directory: currentDirectory, recursive: recursive, preferredCurrent: nil)
    }

    func dismissClosedSessionSummary() {
        closedSessionSummary = nil
    }

    func toggleRecursiveMode() {
        setRecursive(!recursive)
    }

    func clearRecentSources() {
        mutateSettings { $0.recentSourceDirectories = [] }
        statusMessage = "Cleared recent sources."
    }

    func clearRecentDestinations() {
        mutateSettings { $0.recentDestinationDirectories = [] }
        statusMessage = "Cleared recent destinations."
    }

    func skipCurrent() {
        guard !files.isEmpty, index < files.count, let source = currentFile else { return }
        registerSessionOutcome(.skipped, for: source.path)
        undoHistory.append(
            UndoAction(
                sourceOriginalURL: source,
                kind: .skipped,
                previousSelection: selectedFolder
            )
        )
        index = min(index + 1, files.count)
        updateCurrentFilePresentation()
        statusMessage = "Skipped current file."
    }

    func goBack() {
        guard let action = undoHistory.popLast() else {
            statusMessage = "Nothing to undo."
            return
        }

        do {
            statusMessage = try applyUndoAction(action)
        } catch {
            statusMessage = "Undo failed: \(error.localizedDescription)"
            presentErrorSheet(title: "Undo Failed", message: error.localizedDescription)
        }
    }

    func moveCurrent(targetFolderRaw: String?) {
        guard let source = currentFile, let destinationBase = destinationDirectory else {
            statusMessage = "Nothing to move."
            return
        }

        let selected = (targetFolderRaw ?? selectedFolder ?? folderQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else {
            statusMessage = "Type or select a target folder first."
            return
        }

        let targetDir = destinationBase.appendingPathComponent(selected, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

            if !folders.contains(selected) {
                folders.append(selected)
                folders.sort { $0.localizedStandardCompare($1) == .orderedAscending }
            }

            let result = try moveWithConflictHandling(source: source, targetDirectory: targetDir)
            switch result.outcome {
            case .moved:
                registerSessionOutcome(.moved, for: source.path)
                if let resultURL = result.resultURL {
                    undoHistory.append(
                        UndoAction(
                            sourceOriginalURL: source,
                            kind: .moved(resultURL: resultURL),
                            previousSelection: selectedFolder
                        )
                    )
                }
            case .duplicate:
                registerSessionOutcome(.duplicate, for: source.path)
                undoHistory.append(
                    UndoAction(
                        sourceOriginalURL: source,
                        kind: .duplicated(trashedURL: result.resultURL),
                        previousSelection: selectedFolder
                    )
                )
            case .renamed:
                registerSessionOutcome(.renamed, for: source.path)
                if let resultURL = result.resultURL {
                    undoHistory.append(
                        UndoAction(
                            sourceOriginalURL: source,
                            kind: .moved(resultURL: resultURL),
                            previousSelection: selectedFolder
                        )
                    )
                }
            }

            lastMovedFolderContext = selected
            if let seriesInfo = filenameSeriesInfo(for: source) {
                suggestedFolderBySeriesKey[seriesInfo.key] = selected
                destinationSeriesFolderByKey[seriesInfo.key] = selected
            }

            let previousSelection = selectedFolder
            index = min(index + 1, files.count)
            selectedFolder = preferredSelectionForCurrentFile(fallback: previousSelection)
            updateCurrentFilePresentation()
            statusMessage = result.message
        } catch let error as DuplicateRemovalCancelledError {
            statusMessage = error.localizedDescription
        } catch {
            statusMessage = "Move failed: \(error.localizedDescription)"
            presentErrorSheet(title: "Move Failed", message: error.localizedDescription)
        }
    }

    func rankedFolders() -> [String] {
        guard let current = currentFile else {
            return folders
        }

        let query = folderQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let suggested = suggestedFolder(for: current)

        if query.isEmpty {
            guard let suggested else { return folders }
            return [suggested] + folders.filter { $0.caseInsensitiveCompare(suggested) != .orderedSame }
        }

        let ranked = folders
            .enumerated()
            .map { (idx, folder) in
                (folder: folder, idx: idx, score: fuzzyScore(query: query, target: folder.lowercased()))
            }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.idx < rhs.idx
            }
            .map(\ .folder)

        if let suggested,
           ranked.contains(where: { $0.caseInsensitiveCompare(suggested) == .orderedSame }) {
            return [suggested] + ranked.filter { $0.caseInsensitiveCompare(suggested) != .orderedSame }
        }
        return ranked
    }

    func rememberSeek(seconds: Double, for fileURL: URL) {
        guard seconds.isFinite, seconds >= 0 else { return }
        lastSeekByPath[fileURL.path] = seconds
    }

    func rememberedSeek(for fileURL: URL) -> Double {
        lastSeekByPath[fileURL.path] ?? 0
    }

    private func mutateSettings(_ update: (inout AppSettings) -> Void) {
        var next = settings
        update(&next)
        settings = next
        configStore.save(next)
    }

    private func rebuildSession(directory: URL, recursive: Bool, preferredCurrent: URL?) {
        rebuildTask?.cancel()
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let destinationBase = destinationDirectoryOverride ?? directory

        isLoadingDirectory = true
        files = []
        index = 0
        currentFileIcon = nil
        currentFileMetadataLine = ""
        currentFileSourceURLs = []
        isLoadingCurrentFileSources = false
        currentFolderSuggestionHint = ""
        currentFolderSuggestionSourceDetail = ""
        currentSuggestedFolder = nil
        suggestedFolderBySeriesKey = [:]
        destinationSeriesFolderByKey = [:]
        lastSuggestionDebugLogKey = nil

        rebuildTask = Task { [directory, recursive, preferredCurrent] in
            async let filesTask = Task.detached(priority: .userInitiated) {
                Self.collectFiles(in: directory, recursive: recursive)
            }.value
            async let foldersTask = Task.detached(priority: .userInitiated) {
                Self.collectFolders(in: destinationBase)
            }.value

            let (loadedFiles, loadedFolders) = await (filesTask, foldersTask)
            guard !Task.isCancelled else { return }
            guard generation == self.rebuildGeneration else { return }

            self.files = loadedFiles
            self.folders = loadedFolders
            self.destinationSeriesFolderByKey = Self.collectSeriesFolderMappings(in: destinationBase, folders: loadedFolders, parser: self.filenameSeriesInfoFromStem)
            let previousSelection = self.selectedFolder

            if let preferredCurrent,
               let position = loadedFiles.firstIndex(where: { $0.path == preferredCurrent.path }) {
                self.index = position
            } else {
                self.index = 0
            }

            self.selectedFolder = self.preferredSelectionForCurrentFile(fallback: previousSelection)
            self.updateCurrentFilePresentation()
            self.isLoadingDirectory = false

                if self.pendingDuplicateRescanAfterRebuild,
                    (self.appMode == .duplicateFinder || self.appMode == .similarityFinder),
               self.currentDirectory != nil {
                self.pendingDuplicateRescanAfterRebuild = false
                self.startDuplicateScan()
            }

            if loadedFiles.isEmpty {
                self.statusMessage = "No files found in selected folder."
            } else if self.statusMessage == "Loading folder…" {
                self.statusMessage = ""
            }
        }
    }

    private func pruneMissingFilesFromSession() {
        guard !files.isEmpty else { return }

        let currentPath = currentFile?.path
        files = files.filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !files.isEmpty else {
            index = 0
            updateCurrentFilePresentation()
            return
        }

        if let currentPath,
           let matchedIndex = files.firstIndex(where: { $0.path == currentPath }) {
            index = matchedIndex
        } else {
            index = min(index, files.count - 1)
        }

        updateCurrentFilePresentation()
    }

    private func setDestinationOverride(_ directory: URL) {
        destinationDirectoryOverride = directory
        mutateSettings {
            $0.pushRecentDestinationDirectory(directory)
        }
        refreshDestinationFolders()
    }

    private func refreshDestinationFolders() {
        guard let destinationDirectory else {
            folders = []
            destinationSeriesFolderByKey = [:]
            selectedFolder = nil
            return
        }

        let previousSelection = selectedFolder
        folders = Self.collectFolders(in: destinationDirectory)
        destinationSeriesFolderByKey = Self.collectSeriesFolderMappings(in: destinationDirectory, folders: folders, parser: filenameSeriesInfoFromStem)
        selectedFolder = preferredSelectionForCurrentFile(fallback: previousSelection)
    }

    private func preferredSelectionForCurrentFile(fallback: String?) -> String? {
        if let currentFile,
           let suggested = suggestedFolder(for: currentFile) {
            return suggested
        }

        if let fallback,
           let matched = folders.first(where: { $0.caseInsensitiveCompare(fallback) == .orderedSame }) {
            return matched
        }

        return nil
    }

    private func resetSessionSummary() {
        sessionOutcomeByPath = [:]
        sessionMovedCount = 0
        sessionDuplicateCount = 0
        sessionRenamedCount = 0
        sessionSkippedCount = 0
    }

    private struct AutoSortDecision {
        let targetFolder: String?
        let confidence: Double
        let reason: String
    }

    private func runAutoSortLoop() async {
        isAutoSorting = true
        statusMessage = "Auto-sort started."

        let startedAt = Date()
        let threshold = autoSortConfidenceThreshold
        var items: [AutoSortReportItem] = []

        while !Task.isCancelled {
            guard let source = currentFile else { break }

            let decision = await autoSortDecision(for: source)
            let reportID = UUID()

            if let targetFolder = decision.targetFolder,
               decision.confidence >= threshold {
                let sourcePathBefore = source.path
                let undoCountBefore = undoHistory.count
                let movedBefore = sessionMovedCount
                let duplicateBefore = sessionDuplicateCount
                let renamedBefore = sessionRenamedCount

                moveCurrent(targetFolderRaw: targetFolder)

                if currentFile?.path != sourcePathBefore {
                    let outcome: AutoSortItemOutcome
                    if sessionMovedCount > movedBefore {
                        outcome = .moved
                    } else if sessionDuplicateCount > duplicateBefore {
                        outcome = .duplicate
                    } else if sessionRenamedCount > renamedBefore {
                        outcome = .renamed
                    } else {
                        outcome = .moved
                    }

                    let undoActionID = undoHistory.count > undoCountBefore ? undoHistory.last?.id : nil

                    items.append(
                        AutoSortReportItem(
                            id: reportID,
                            sourcePath: sourcePathBefore,
                            fileName: URL(fileURLWithPath: sourcePathBefore).lastPathComponent,
                            targetFolder: targetFolder,
                            confidence: decision.confidence,
                            outcome: outcome,
                            message: statusMessage,
                            undoActionID: undoActionID,
                            isUndone: false
                        )
                    )
                } else {
                    skipCurrent()
                    items.append(
                        AutoSortReportItem(
                            id: reportID,
                            sourcePath: sourcePathBefore,
                            fileName: URL(fileURLWithPath: sourcePathBefore).lastPathComponent,
                            targetFolder: targetFolder,
                            confidence: decision.confidence,
                            outcome: .failed,
                            message: statusMessage,
                            undoActionID: nil,
                            isUndone: false
                        )
                    )
                }
            } else {
                let sourcePath = source.path
                let reason = decision.reason.isEmpty ? "No confident folder match." : decision.reason
                skipCurrent()
                items.append(
                    AutoSortReportItem(
                        id: reportID,
                        sourcePath: sourcePath,
                        fileName: source.lastPathComponent,
                        targetFolder: nil,
                        confidence: decision.confidence,
                        outcome: .needsReview,
                        message: "Queued for manual review: \(reason)",
                        undoActionID: nil,
                        isUndone: false
                    )
                )
            }

            await Task.yield()
            try? await Task.sleep(nanoseconds: 35_000_000)
        }

        isAutoSorting = false
        autoSortTask = nil
        autoSortReport = AutoSortReport(
            startedAt: startedAt,
            finishedAt: Date(),
            confidenceThreshold: threshold,
            items: items
        )

        if Task.isCancelled {
            statusMessage = "Auto-sort stopped."
        } else {
            statusMessage = "Auto-sort complete: \(items.count) files processed."
        }
    }

    private func autoSortDecision(for file: URL) async -> AutoSortDecision {
        if let suggestion = await suggestedFolderMatchForAutoSort(for: file) {
            let hint = suggestion.hint.lowercased()
            let sourceDetail = suggestion.sourceDetail?.lowercased() ?? ""

            let confidence: Double
            if hint.contains("auto-create from username") {
                confidence = 0.96
            } else 
            if sourceDetail.contains("existing sorted folders") {
                confidence = 0.95
            } else if sourceDetail.contains("current session") {
                confidence = 0.9
            } else if hint.contains("username") {
                confidence = 0.87
            } else if hint.contains("filename text") {
                confidence = 0.74
            } else {
                confidence = 0.8
            }

            return AutoSortDecision(targetFolder: suggestion.folder, confidence: confidence, reason: suggestion.hint)
        }

        let stem = file.deletingPathExtension().lastPathComponent.lowercased()
        if let fallback = folders.first(where: { stem.contains($0.lowercased()) }) {
            return AutoSortDecision(targetFolder: fallback, confidence: 0.68, reason: "Matched folder name in filename")
        }

        return AutoSortDecision(targetFolder: nil, confidence: 0, reason: "No suggestion")
    }

    private func suggestedFolderMatchForAutoSort(for file: URL) async -> FolderSuggestion? {
        if let seriesSuggestion = seriesSuggestedFolder(for: file) {
            return seriesSuggestion
        }

        let fileName = file.lastPathComponent
        if let username = extractUsername(from: fileName),
           let match = folders.first(where: { $0.caseInsensitiveCompare(username) == .orderedSame }) {
            return FolderSuggestion(folder: match, hint: "Suggested from filename username: @\(username)", sourceDetail: nil)
        }

        if let metadataMatch = await metadataSuggestedFolderForAutoSort(for: file) {
            return metadataMatch
        }

        if autoCreateUsernameFoldersEnabled,
           let autoCreateUsername = await highConfidenceAutoCreateFolderUsername(for: file) {
            return FolderSuggestion(
                folder: autoCreateUsername,
                hint: "Auto-create from username: @\(autoCreateUsername)",
                sourceDetail: "Match source: high-confidence username",
                debugMessage: "Auto-sort username folder creation candidate: @\(autoCreateUsername)"
            )
        }

        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.lowercased()
        if let match = folders.first(where: { stem.contains($0.lowercased()) }) {
            return FolderSuggestion(folder: match, hint: "Suggested from filename text", sourceDetail: nil)
        }

        return nil
    }

    private func metadataSuggestedFolderForAutoSort(for file: URL) async -> FolderSuggestion? {
        if let cached = sourceURLsByFilePath[file.path] {
            for sourceURL in cached {
                if let match = metadataFolderMatch(from: sourceURL) {
                    return match
                }
            }
            return nil
        }

        let urls = await Task.detached(priority: .utility) {
            Self.metadataWhereFromURLs(for: file)
        }.value

        sourceURLsByFilePath[file.path] = urls
        for sourceURL in urls {
            if let match = metadataFolderMatch(from: sourceURL) {
                return match
            }
        }

        return nil
    }

    private func highConfidenceAutoCreateFolderUsername(for file: URL) async -> String? {
        if let extracted = extractUsername(from: file.lastPathComponent),
           isHighConfidenceUsernameToken(extracted) {
            return resolvedFolderName(forCandidate: extracted)
        }

        let urls: [URL]
        if let cached = sourceURLsByFilePath[file.path] {
            urls = cached
        } else {
            let fetched = await Task.detached(priority: .utility) {
                Self.metadataWhereFromURLs(for: file)
            }.value
            sourceURLsByFilePath[file.path] = fetched
            urls = fetched
        }

        for sourceURL in urls {
            for candidate in socialUsernameCandidates(from: sourceURL) {
                if isHighConfidenceUsernameToken(candidate) {
                    return resolvedFolderName(forCandidate: candidate)
                }
            }
        }

        return nil
    }

    private func resolvedFolderName(forCandidate candidate: String) -> String {
        if let existing = folderMatch(forCandidate: candidate) {
            return existing
        }
        return candidate
    }

    private func isHighConfidenceUsernameToken(_ token: String) -> Bool {
        let cleaned = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))

        guard !cleaned.isEmpty else { return false }
        guard cleaned.count >= 3, cleaned.count <= 15 else { return false }

        let valid = cleaned.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        guard valid else { return false }

        let hasLetter = cleaned.contains { $0.isLetter }
        return hasLetter
    }

    private func applyUndoAction(_ action: UndoAction) throws -> String {
        switch action.kind {
        case .skipped:
            index = max(0, index - 1)
            removeSessionOutcome(for: action.sourceOriginalURL.path)
            selectedFolder = action.previousSelection
            updateCurrentFilePresentation()
            return "Undid skip."

        case .moved(let resultURL):
            try moveFileBackToSource(from: resultURL, to: action.sourceOriginalURL)
            index = max(0, index - 1)
            removeSessionOutcome(for: action.sourceOriginalURL.path)
            selectedFolder = action.previousSelection
            updateCurrentFilePresentation()
            return "Undid move for \(action.sourceOriginalURL.lastPathComponent)."

        case .duplicated(let trashedURL):
            guard let trashedURL else {
                return "Unable to undo duplicate removal."
            }
            try restoreFromTrash(trashedURL: trashedURL, to: action.sourceOriginalURL)
            index = max(0, index - 1)
            removeSessionOutcome(for: action.sourceOriginalURL.path)
            selectedFolder = action.previousSelection
            updateCurrentFilePresentation()
            return "Restored duplicate for \(action.sourceOriginalURL.lastPathComponent)."
        }
    }

    private enum DuplicateVisualKind {
        case image
        case video
        case other
    }

    private struct DuplicateVisualSignature {
        let hash: UInt64
        let faceHashes: [UInt64]
        let width: Int
        let height: Int

        var faceHash: UInt64? {
            faceHashes.first
        }

        var aspectRatio: Double {
            guard width > 0, height > 0 else { return 0 }
            return Double(width) / Double(height)
        }

        var pixelArea: Int64 {
            Int64(width) * Int64(height)
        }
    }

    private struct DuplicateDescriptor {
        let url: URL
        let size: Int64
        let ext: String
        let fingerprint: String
        let durationSeconds: Double?
        let visualKind: DuplicateVisualKind
        let visualSignature: DuplicateVisualSignature?
    }

    private func runDuplicateScanLoop(
        directory: URL,
        recursive: Bool,
        includeExactMatches: Bool,
        enableFaceMatching: Bool,
        focusedPersonName: String?
    ) async {
        isDuplicateScanning = true
        isDuplicateScanPaused = false
        scanHashMissCount = 0
        scanHashMissTotalSeconds = 0
        statusMessage = includeExactMatches ? "Duplicate scan started." : "People scan started."

        let startedAt = Date()
        duplicateScanProgress = DuplicateScanProgress(
            phase: .collecting,
            currentFileName: nil,
            processed: 0,
            total: 0,
            startedAt: startedAt,
            potentialGroupCount: 0,
            exactGroupCount: 0,
            similarGroupCount: 0
        )
        let scanFiles = await Task.detached(priority: .userInitiated) {
            Self.collectFiles(in: directory, recursive: recursive)
        }.value

        let peopleModeOnly = enableFaceMatching && !includeExactMatches
        let filteredScanFiles: [URL]
        if peopleModeOnly {
            filteredScanFiles = scanFiles.filter { file in
                let ext = file.pathExtension.lowercased()
                let kind = duplicateVisualKind(forExtension: ext)
                return kind == .image || kind == .video
            }
        } else {
            filteredScanFiles = scanFiles
        }
        let skippedNonMatchableCount = max(0, scanFiles.count - filteredScanFiles.count)

        duplicateScanProgress = DuplicateScanProgress(
            phase: .profiling,
            currentFileName: nil,
            processed: 0,
            total: filteredScanFiles.count,
            startedAt: startedAt,
            potentialGroupCount: 0,
            exactGroupCount: 0,
            similarGroupCount: 0
        )

        if Task.isCancelled {
            isDuplicateScanning = false
            isDuplicateScanPaused = false
            duplicateScanTask = nil
            duplicateScanProgress = nil
            statusMessage = includeExactMatches ? "Duplicate scan stopped." : "People scan stopped."
            return
        }

        var descriptors: [DuplicateDescriptor] = []
        descriptors.reserveCapacity(filteredScanFiles.count)
        duplicateFaceHashesByPath = [:]
        var sizeFrequency: [Int64: Int] = [:]
        var potentialGroupCount = 0
        var faceIndexedCount = 0

        for (index, file) in filteredScanFiles.enumerated() {
            guard await waitIfDuplicateScanPaused() else { break }
            if Task.isCancelled { break }
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let fileSize = Int64(values?.fileSize ?? 0)
            let modifiedAt = values?.contentModificationDate
            let ext = file.pathExtension.lowercased()
            let fingerprint = duplicateFingerprint(for: file, size: fileSize, modifiedAt: modifiedAt)
            let duration = await cachedVideoDuration(for: file, ext: ext, fingerprint: fingerprint)
            let visualKind = duplicateVisualKind(forExtension: ext)
            let visualSignature = await cachedVisualSignature(for: file, ext: ext, fingerprint: fingerprint, kind: visualKind)
            if visualSignature?.faceHash != nil {
                faceIndexedCount += 1
            }
            descriptors.append(
                DuplicateDescriptor(
                    url: file,
                    size: fileSize,
                    ext: ext,
                    fingerprint: fingerprint,
                    durationSeconds: duration,
                    visualKind: visualKind,
                    visualSignature: visualSignature
                )
            )

            if let faceHashes = visualSignature?.faceHashes,
               !faceHashes.isEmpty {
                duplicateFaceHashesByPath[file.path] = faceHashes
            }

            let nextSizeCount = (sizeFrequency[fileSize] ?? 0) + 1
            sizeFrequency[fileSize] = nextSizeCount
            if nextSizeCount == 2 {
                potentialGroupCount += 1
            }

            duplicateScanProgress = DuplicateScanProgress(
                phase: .profiling,
                currentFileName: file.lastPathComponent,
                processed: index + 1,
                total: filteredScanFiles.count,
                startedAt: startedAt,
                potentialGroupCount: potentialGroupCount,
                exactGroupCount: 0,
                similarGroupCount: 0,
                faceIndexedCount: faceIndexedCount,
                faceMatchCount: 0,
                visualMatchCount: 0
            )

            if index % 8 == 0 {
                await Task.yield()
            }
        }

        var exactGroups: [DuplicateCandidateGroup] = []
        var exactPathPairs = Set<String>()

        if includeExactMatches {
            let sizeBuckets = Dictionary(grouping: descriptors, by: { $0.size })
                .filter { $0.value.count > 1 }

            duplicateScanProgress = DuplicateScanProgress(
                phase: .hashing,
                currentFileName: nil,
                processed: 0,
                total: max(sizeBuckets.count, 1),
                startedAt: startedAt,
                potentialGroupCount: potentialGroupCount,
                exactGroupCount: 0,
                similarGroupCount: 0
            )

            for (bucketIndex, (_, bucket)) in sizeBuckets.enumerated() {
                guard await waitIfDuplicateScanPaused() else { break }
                if Task.isCancelled { break }

                var byHash: [String: [DuplicateDescriptor]] = [:]
                for descriptor in bucket {
                    guard await waitIfDuplicateScanPaused() else { break }
                    if Task.isCancelled { break }
                    let hash = await cachedFileHash(for: descriptor)
                    if hash.isEmpty { continue }
                    byHash[hash, default: []].append(descriptor)
                }

                for (_, hashMatches) in byHash where hashMatches.count > 1 {
                    let files = hashMatches.map {
                        DuplicateCandidateFile(
                            path: $0.url.path,
                            name: $0.url.lastPathComponent,
                            size: $0.size,
                            durationSeconds: $0.durationSeconds
                        )
                    }

                    for index in 0..<hashMatches.count {
                        for other in (index + 1)..<hashMatches.count {
                            exactPathPairs.insert(Self.pairKey(hashMatches[index].url.path, hashMatches[other].url.path))
                        }
                    }

                    exactGroups.append(
                        DuplicateCandidateGroup(
                            kind: .exactHash,
                            score: 1.0,
                            reason: "Exact content hash match",
                            files: files,
                            resolvedKeeperPaths: nil,
                            resolvedDestinationFolder: nil
                        )
                    )
                }

                duplicateScanProgress = DuplicateScanProgress(
                    phase: .hashing,
                    currentFileName: nil,
                    processed: bucketIndex + 1,
                    total: max(sizeBuckets.count, 1),
                    startedAt: startedAt,
                    potentialGroupCount: potentialGroupCount,
                    exactGroupCount: exactGroups.count,
                    similarGroupCount: 0
                )

                if bucketIndex % 4 == 0 {
                    await Task.yield()
                }
            }
        }

        var similarGroups: [DuplicateCandidateGroup] = []
        var similarAdjacency: [String: Set<String>] = [:]
        var similarScoreByPairKey: [String: Double] = [:]
        var similarReasonByPairKey: [String: String] = [:]
        var faceMatchCount = 0
        var visualMatchCount = 0

        func isFaceReason(_ reason: String) -> Bool {
            reason.localizedCaseInsensitiveContains("face")
        }

        func applyReasonDelta(from oldReason: String?, to newReason: String) {
            if let oldReason {
                if isFaceReason(oldReason) {
                    faceMatchCount = max(0, faceMatchCount - 1)
                } else {
                    visualMatchCount = max(0, visualMatchCount - 1)
                }
            }

            if isFaceReason(newReason) {
                faceMatchCount += 1
            } else {
                visualMatchCount += 1
            }
        }

        let imageMaxHammingDistance = 8
        let videoMaxHammingDistance = 12
        let minimumVideoRuntimeSimilarity = 0.93
        let minimumVideoAspectSimilarity = 0.94
        let minimumVideoAreaSimilarity = 0.85
        let nearThreshold = 0.79
        let maxComparisonsPerFile = 220
        let maxAcceptedSimilarPairsPerFile = 8
        let strongNearMatchMaxHammingDistance = 4
        let maxSimilarPairsTotal = 45_000
        let maxSimilarNodesTotal = 8_000
        var didApplySimilarSafetyCap = false
        let descriptorsByExtension = Dictionary(grouping: descriptors, by: { $0.ext.isEmpty ? "<none>" : $0.ext })
        let sortedSimilarityBuckets = descriptorsByExtension
            .values
            .filter { $0.count > 1 }
            .map { $0.sorted { lhs, rhs in lhs.size < rhs.size } }
            .sorted {
                let lhsName = $0.first?.url.lastPathComponent ?? ""
                let rhsName = $1.first?.url.lastPathComponent ?? ""
                return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
            }
        let comparisonTotal = max(sortedSimilarityBuckets.reduce(0) { $0 + max($1.count - 1, 0) }, 1)
        var comparisonProcessed = 0

        if !sortedSimilarityBuckets.isEmpty {
            duplicateScanProgress = DuplicateScanProgress(
                phase: .comparing,
                currentFileName: nil,
                processed: 0,
                total: comparisonTotal,
                startedAt: startedAt,
                potentialGroupCount: potentialGroupCount,
                exactGroupCount: exactGroups.count,
                similarGroupCount: 0,
                faceIndexedCount: faceIndexedCount,
                faceMatchCount: 0,
                visualMatchCount: 0
            )

            for bucket in sortedSimilarityBuckets {
                for idx in 0..<(bucket.count - 1) {
                    guard await waitIfDuplicateScanPaused() else { break }
                    if Task.isCancelled { break }

                    let lhs = bucket[idx]
                    comparisonProcessed += 1
                    duplicateScanProgress = DuplicateScanProgress(
                        phase: .comparing,
                        currentFileName: lhs.url.lastPathComponent,
                        processed: comparisonProcessed,
                        total: comparisonTotal,
                        startedAt: startedAt,
                        potentialGroupCount: potentialGroupCount,
                        exactGroupCount: exactGroups.count,
                        similarGroupCount: similarAdjacency.count,
                        faceIndexedCount: faceIndexedCount,
                        faceMatchCount: faceMatchCount,
                        visualMatchCount: visualMatchCount
                    )

                    var comparisonsForLHS = 0
                    var acceptedPairsForLHS = 0
                    for jdx in (idx + 1)..<bucket.count {
                        guard await waitIfDuplicateScanPaused() else { break }
                        if Task.isCancelled { break }
                        if comparisonsForLHS >= maxComparisonsPerFile { break }
                        if similarScoreByPairKey.count >= maxSimilarPairsTotal {
                            didApplySimilarSafetyCap = true
                            break
                        }

                        let rhs = bucket[jdx]
                        comparisonsForLHS += 1

                        guard let lhsVisualSignature = lhs.visualSignature,
                            let rhsVisualSignature = rhs.visualSignature
                        else {
                            continue
                        }

                        guard lhs.visualKind == rhs.visualKind,
                              lhs.visualKind != .other
                        else {
                            continue
                        }

                        let maxHammingDistance = lhs.visualKind == .image ? imageMaxHammingDistance : videoMaxHammingDistance
                        let hammingDistance = Self.hammingDistance(lhsVisualSignature.hash, rhsVisualSignature.hash)
                        let faceMatch: (score: Double, pairKey: String)? = {
                            guard enableFaceMatching else { return nil }
                            return Self.bestFaceSimilarityWithPairKey(lhs: lhsVisualSignature.faceHashes, rhs: rhsVisualSignature.faceHashes)
                        }()
                        let faceScore = faceMatch?.score
                        let strongFaceMatch = (faceScore ?? 0) >= 0.84

                        if hammingDistance > maxHammingDistance && !strongFaceMatch {
                            continue
                        }

                        let isStrongNearMatch = hammingDistance <= strongNearMatchMaxHammingDistance || strongFaceMatch

                        if acceptedPairsForLHS >= maxAcceptedSimilarPairsPerFile,
                           !isStrongNearMatch {
                            break
                        }

                        let key = Self.pairKey(lhs.url.path, rhs.url.path)
                        if exactPathPairs.contains(key) { continue }

                        let visualScore = max(0, 1 - (Double(hammingDistance) / 64.0))
                        let score: Double
                        let reason: String

                        if lhs.visualKind == .video {
                            guard let lDur = lhs.durationSeconds,
                                  let rDur = rhs.durationSeconds,
                                  lDur > 0,
                                  rDur > 0
                            else {
                                continue
                            }

                            let aspectScore = Self.normalizedSimilarity(lhsVisualSignature.aspectRatio, rhsVisualSignature.aspectRatio)
                            if aspectScore < minimumVideoAspectSimilarity {
                                continue
                            }

                            let areaScore = Self.normalizedSimilarity(lhsVisualSignature.pixelArea, rhsVisualSignature.pixelArea)
                            if areaScore < minimumVideoAreaSimilarity {
                                continue
                            }

                            let runtimeScore = Self.normalizedSimilarity(lDur, rDur)
                            if runtimeScore < minimumVideoRuntimeSimilarity {
                                continue
                            }

                            let faceWeighted = faceScore ?? visualScore
                            score = (visualScore * 0.50) + (runtimeScore * 0.25) + (aspectScore * 0.10) + (areaScore * 0.05) + (faceWeighted * 0.10)
                            reason = enableFaceMatching && faceScore != nil ? "Similar face/frame + runtime" : "Similar non-dark frame + runtime"
                        } else {
                            if let faceScore, faceScore >= 0.84 {
                                score = (visualScore * 0.40) + (faceScore * 0.60)
                                reason = "Similar face + visual image"
                            } else {
                                score = visualScore
                                reason = "Visually similar image"
                            }
                        }

                        if score >= nearThreshold {
                            acceptedPairsForLHS += 1
                            if let existingScore = similarScoreByPairKey[key],
                               existingScore >= score {
                                continue
                            }

                            let projectedNodeCount = similarAdjacency.keys.count
                                + (similarAdjacency[lhs.url.path] == nil ? 1 : 0)
                                + (similarAdjacency[rhs.url.path] == nil ? 1 : 0)
                            if projectedNodeCount > maxSimilarNodesTotal {
                                didApplySimilarSafetyCap = true
                                break
                            }

                            similarAdjacency[lhs.url.path, default: []].insert(rhs.url.path)
                            similarAdjacency[rhs.url.path, default: []].insert(lhs.url.path)
                            similarScoreByPairKey[key] = score
                            let oldReason = similarReasonByPairKey[key]
                            if oldReason != reason {
                                applyReasonDelta(from: oldReason, to: reason)
                            }
                            similarReasonByPairKey[key] = reason
                        }
                    }

                    if idx % 8 == 0 {
                        await Task.yield()
                    }
                }

                if Task.isCancelled {
                    break
                }
                if didApplySimilarSafetyCap {
                    break
                }
            }
        }

        if enableFaceMatching {
            let faceMatchThreshold = 0.82
            let strongFaceMatchThreshold = 0.90
            let maxFaceComparisonsPerFile = 260
            let maxFacePairsTotal = 80_000

            let faceDescriptors = descriptors.filter { descriptor in
                !(descriptor.visualSignature?.faceHashes.isEmpty ?? true)
            }

            if faceDescriptors.count > 1 {
                let faceTotal = max(faceDescriptors.count - 1, 1)
                duplicateScanProgress = DuplicateScanProgress(
                    phase: .faceMatching,
                    currentFileName: nil,
                    processed: 0,
                    total: faceTotal,
                    startedAt: startedAt,
                    potentialGroupCount: potentialGroupCount,
                    exactGroupCount: exactGroups.count,
                    similarGroupCount: similarAdjacency.count,
                    faceIndexedCount: faceIndexedCount,
                    faceMatchCount: faceMatchCount,
                    visualMatchCount: visualMatchCount
                )

                for idx in 0..<(faceDescriptors.count - 1) {
                    guard await waitIfDuplicateScanPaused() else { break }
                    if Task.isCancelled { break }

                    let lhs = faceDescriptors[idx]
                    guard let lhsFaceHashes = lhs.visualSignature?.faceHashes,
                          !lhsFaceHashes.isEmpty
                      else { continue }
                    var faceComparisonsForLHS = 0

                    for jdx in (idx + 1)..<faceDescriptors.count {
                        guard await waitIfDuplicateScanPaused() else { break }
                        if Task.isCancelled { break }
                        if faceComparisonsForLHS >= maxFaceComparisonsPerFile { break }
                        if similarScoreByPairKey.count >= maxFacePairsTotal {
                            didApplySimilarSafetyCap = true
                            break
                        }

                        let rhs = faceDescriptors[jdx]
                        guard let rhsFaceHashes = rhs.visualSignature?.faceHashes,
                            !rhsFaceHashes.isEmpty
                        else { continue }
                        faceComparisonsForLHS += 1

                        let key = Self.pairKey(lhs.url.path, rhs.url.path)
                        if exactPathPairs.contains(key) { continue }

                        guard let faceMatch = Self.bestFaceSimilarityWithPairKey(lhs: lhsFaceHashes, rhs: rhsFaceHashes) else {
                            continue
                        }
                        let faceScore = faceMatch.score
                        if faceScore < faceMatchThreshold { continue }

                        if let existingScore = similarScoreByPairKey[key],
                           existingScore >= faceScore {
                            continue
                        }

                        let projectedNodeCount = similarAdjacency.keys.count
                            + (similarAdjacency[lhs.url.path] == nil ? 1 : 0)
                            + (similarAdjacency[rhs.url.path] == nil ? 1 : 0)
                        if projectedNodeCount > maxSimilarNodesTotal {
                            didApplySimilarSafetyCap = true
                            break
                        }

                        similarAdjacency[lhs.url.path, default: []].insert(rhs.url.path)
                        similarAdjacency[rhs.url.path, default: []].insert(lhs.url.path)
                        similarScoreByPairKey[key] = faceScore
                        let reason = faceScore >= strongFaceMatchThreshold ? "Strong face match" : "Similar face match"
                        let oldReason = similarReasonByPairKey[key]
                        if oldReason != reason {
                            applyReasonDelta(from: oldReason, to: reason)
                        }
                        similarReasonByPairKey[key] = reason
                    }

                    if idx % 8 == 0 {
                        await Task.yield()
                    }

                    duplicateScanProgress = DuplicateScanProgress(
                        phase: .faceMatching,
                        currentFileName: lhs.url.lastPathComponent,
                        processed: idx + 1,
                        total: faceTotal,
                        startedAt: startedAt,
                        potentialGroupCount: potentialGroupCount,
                        exactGroupCount: exactGroups.count,
                        similarGroupCount: similarAdjacency.count,
                        faceIndexedCount: faceIndexedCount,
                        faceMatchCount: faceMatchCount,
                        visualMatchCount: visualMatchCount
                    )

                    if didApplySimilarSafetyCap {
                        break
                    }
                }
            }
        }

        let descriptorsByPath = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.url.path, $0) })

        if !similarAdjacency.isEmpty {
            var visited = Set<String>()

            for startPath in similarAdjacency.keys where !visited.contains(startPath) {
                var stack = [startPath]
                var componentPaths: [String] = []

                while let current = stack.popLast() {
                    guard visited.insert(current).inserted else { continue }
                    componentPaths.append(current)
                    for neighbor in similarAdjacency[current] ?? [] where !visited.contains(neighbor) {
                        stack.append(neighbor)
                    }
                }

                guard componentPaths.count > 1 else { continue }

                var maxComponentScore = nearThreshold
                var hasRuntimeWeightedPair = false
                var hasVisualImagePair = false
                var hasFacePair = false
                var fileStrengthByPath: [String: Double] = [:]
                let componentPathSet = Set(componentPaths)
                for path in componentPaths {
                    for neighbor in similarAdjacency[path] ?? [] where componentPathSet.contains(neighbor) {
                        let key = Self.pairKey(path, neighbor)
                        if let score = similarScoreByPairKey[key], score > maxComponentScore {
                            maxComponentScore = score
                        }
                        if let score = similarScoreByPairKey[key] {
                            fileStrengthByPath[path] = max(fileStrengthByPath[path] ?? 0, score)
                            fileStrengthByPath[neighbor] = max(fileStrengthByPath[neighbor] ?? 0, score)
                        }
                        if let reason = similarReasonByPairKey[key] {
                            if reason == "Similar non-dark frame + runtime" || reason == "Similar face/frame + runtime" {
                                hasRuntimeWeightedPair = true
                            }
                            if reason == "Visually similar image" || reason == "Similar face + visual image" {
                                hasVisualImagePair = true
                            }
                            if reason == "Strong face match" || reason == "Similar face match" {
                                hasFacePair = true
                            }
                        }
                    }
                }

                let files = componentPaths
                    .compactMap { descriptorsByPath[$0] }
                    .map {
                        DuplicateCandidateFile(
                            path: $0.url.path,
                            name: $0.url.lastPathComponent,
                            size: $0.size,
                            durationSeconds: $0.durationSeconds
                        )
                    }
                    .sorted { lhs, rhs in
                        let lhsStrength = fileStrengthByPath[lhs.path] ?? maxComponentScore
                        let rhsStrength = fileStrengthByPath[rhs.path] ?? maxComponentScore
                        if lhsStrength != rhsStrength { return lhsStrength > rhsStrength }
                        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }

                similarGroups.append(
                    DuplicateCandidateGroup(
                        kind: .similarMetadata,
                        score: maxComponentScore,
                        reason: hasFacePair ? "Similar face match" : (hasRuntimeWeightedPair ? "Similar non-dark frame + runtime" : (hasVisualImagePair ? "Visually similar image" : "Visual similarity")),
                        files: files,
                        resolvedKeeperPaths: nil,
                        resolvedDestinationFolder: nil
                    )
                )
            }
        }

        if enableFaceMatching, similarGroups.count > 1 {
            let faceMergeThreshold = 0.84
            var parent = Array(0..<similarGroups.count)

            func find(_ node: Int) -> Int {
                var node = node
                while parent[node] != node {
                    parent[node] = parent[parent[node]]
                    node = parent[node]
                }
                return node
            }

            func union(_ lhs: Int, _ rhs: Int) {
                let rootL = find(lhs)
                let rootR = find(rhs)
                guard rootL != rootR else { return }
                parent[rootR] = rootL
            }

            func faceHashes(for group: DuplicateCandidateGroup) -> [UInt64] {
                var hashes: [UInt64] = []
                hashes.reserveCapacity(group.files.count)
                for file in group.files {
                    if let fileHashes = descriptorsByPath[file.path]?.visualSignature?.faceHashes,
                       !fileHashes.isEmpty {
                        hashes.append(contentsOf: fileHashes)
                    }
                }
                return hashes
            }

            func bestFaceScore(lhs: [UInt64], rhs: [UInt64]) -> Double {
                guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
                var best = 0.0
                for lHash in lhs {
                    for rHash in rhs {
                        let distance = Self.hammingDistance(lHash, rHash)
                        let score = max(0, 1 - (Double(distance) / 64.0))
                        if score > best {
                            best = score
                            if best >= 0.98 {
                                return best
                            }
                        }
                    }
                }
                return best
            }

            let groupFaceHashes = similarGroups.map(faceHashes)
            for idx in 0..<(similarGroups.count - 1) {
                if groupFaceHashes[idx].isEmpty { continue }
                for jdx in (idx + 1)..<similarGroups.count {
                    if groupFaceHashes[jdx].isEmpty { continue }
                    let score = bestFaceScore(lhs: groupFaceHashes[idx], rhs: groupFaceHashes[jdx])
                    if score >= faceMergeThreshold {
                        union(idx, jdx)
                    }
                }
            }

            var grouped: [Int: [DuplicateCandidateGroup]] = [:]
            for index in similarGroups.indices {
                grouped[find(index), default: []].append(similarGroups[index])
            }

            var mergedGroups: [DuplicateCandidateGroup] = []
            mergedGroups.reserveCapacity(grouped.count)

            for (_, memberGroups) in grouped {
                if memberGroups.count == 1, let group = memberGroups.first {
                    mergedGroups.append(group)
                    continue
                }

                var seen = Set<String>()
                var mergedFiles: [DuplicateCandidateFile] = []
                var mergedScore = nearThreshold
                var hasFaceReason = false
                for group in memberGroups {
                    mergedScore = max(mergedScore, group.score)
                    if group.reason.localizedCaseInsensitiveContains("face") {
                        hasFaceReason = true
                    }
                    for file in group.files where seen.insert(file.path).inserted {
                        mergedFiles.append(file)
                    }
                }

                mergedFiles.sort { lhs, rhs in
                    let lhsFace = descriptorsByPath[lhs.path]?.visualSignature?.faceHash
                    let rhsFace = descriptorsByPath[rhs.path]?.visualSignature?.faceHash
                    if lhsFace != nil && rhsFace == nil { return true }
                    if lhsFace == nil && rhsFace != nil { return false }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }

                mergedGroups.append(
                    DuplicateCandidateGroup(
                        kind: .similarMetadata,
                        score: mergedScore,
                        reason: hasFaceReason ? "Similar face match" : "Visual similarity",
                        files: mergedFiles,
                        resolvedKeeperPaths: nil,
                        resolvedDestinationFolder: nil
                    )
                )
            }

            similarGroups = mergedGroups
        }

        var personGroups: [DuplicateCandidateGroup] = []
        var focusedPersonSearchActive = false
        var focusedSearchPersonLabel: String?
        let showDuplicateStyleGroupsInResults = includeExactMatches
        if enableFaceMatching,
           !trackedPeople.isEmpty,
           !learnedPersonFaceHashesByName.isEmpty {
            let focusedPerson = focusedPersonName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let peopleToSearch: [String]
            if let focusedPerson,
               !focusedPerson.isEmpty,
               trackedPeople.contains(where: { $0.caseInsensitiveCompare(focusedPerson) == .orderedSame }) {
                peopleToSearch = trackedPeople.filter { $0.caseInsensitiveCompare(focusedPerson) == .orderedSame }
            } else {
                peopleToSearch = trackedPeople
            }

            focusedPersonSearchActive = (focusedPerson != nil && !(focusedPerson?.isEmpty ?? true) && peopleToSearch.count == 1)
            focusedSearchPersonLabel = focusedPersonSearchActive ? peopleToSearch.first : nil

            let knownPeopleByFileHash = learnedPersonFileHashesByName.reduce(into: [String: Set<String>]()) { result, pair in
                for hash in pair.value {
                    result[hash, default: []].insert(pair.key)
                }
            }

            var peopleProcessed = 0
            let peopleTotal = max(peopleToSearch.count, 1)
            let filesPerPerson = descriptors.count
            let personScoringFilesTotal = max(filesPerPerson * peopleToSearch.count, 1)
            var personScoringFilesProcessed = 0
            var personScoringMatchCount = 0
            for personName in peopleToSearch {
                defer {
                    peopleProcessed += 1
                }

                duplicateScanProgress = DuplicateScanProgress(
                    phase: .personScoring,
                    currentFileName: personName,
                    processed: personScoringFilesProcessed,
                    total: personScoringFilesTotal,
                    startedAt: startedAt,
                    potentialGroupCount: potentialGroupCount,
                    exactGroupCount: exactGroups.count,
                    similarGroupCount: similarAdjacency.count,
                    faceIndexedCount: faceIndexedCount,
                    faceMatchCount: faceMatchCount,
                    visualMatchCount: visualMatchCount,
                    personScoringPeopleProcessed: peopleProcessed,
                    personScoringPeopleTotal: peopleTotal,
                    personScoringFilesProcessed: personScoringFilesProcessed,
                    personScoringFilesTotal: personScoringFilesTotal,
                    personScoringMatchCount: personScoringMatchCount
                )

                let personFaceHashes = Array(learnedPersonFaceHashesByName[personName] ?? [])
                guard !personFaceHashes.isEmpty else { continue }

                let rejectedHashes = rejectedPersonFaceHashesByName[personName] ?? []
                let knownFileHashes = learnedPersonFileHashesByName[personName] ?? []
                let rejectedFileHashes = rejectedPersonFileHashesByName[personName] ?? []
                var matches: [(file: DuplicateCandidateFile, score: Double)] = []
                var knownMatchPaths = Set<String>()
                matches.reserveCapacity(64)

                for (descriptorIndex, descriptor) in descriptors.enumerated() {
                    guard let visualSignature = descriptor.visualSignature else { continue }

                    personScoringFilesProcessed += 1

                    if descriptorIndex % 12 == 0 {
                        duplicateScanProgress = DuplicateScanProgress(
                            phase: .personScoring,
                            currentFileName: personName,
                            processed: personScoringFilesProcessed,
                            total: personScoringFilesTotal,
                            startedAt: startedAt,
                            potentialGroupCount: potentialGroupCount,
                            exactGroupCount: exactGroups.count,
                            similarGroupCount: similarAdjacency.count,
                            faceIndexedCount: faceIndexedCount,
                            faceMatchCount: faceMatchCount,
                            visualMatchCount: visualMatchCount,
                            personScoringPeopleProcessed: peopleProcessed,
                            personScoringPeopleTotal: peopleTotal,
                            personScoringFilesProcessed: personScoringFilesProcessed,
                            personScoringFilesTotal: personScoringFilesTotal,
                            personScoringMatchCount: personScoringMatchCount
                        )
                    }

                    let descriptorHash = await cachedFileHash(for: descriptor)
                    let knownPeopleForHash = (!descriptorHash.isEmpty ? knownPeopleByFileHash[descriptorHash] : nil) ?? []
                    let isKnownForCurrentPerson = knownPeopleForHash.contains(where: { $0.caseInsensitiveCompare(personName) == .orderedSame })
                    let detectedPeopleCount = max(visualSignature.faceHashes.count, duplicateFaceHashesByPath[descriptor.url.path]?.count ?? 0)
                    var assignedPeople = Set(knownPeopleForHash)
                    assignedPeople.formUnion(taggedPersonByPath[descriptor.url.path] ?? [])
                    let assignmentCapacityRemaining = detectedPeopleCount > 0 && assignedPeople.count < detectedPeopleCount

                    if !isKnownForCurrentPerson && !assignmentCapacityRemaining {
                        continue
                    }

                    let isKnownFileMatch = !descriptorHash.isEmpty && knownFileHashes.contains(descriptorHash)

                    if !descriptorHash.isEmpty,
                       rejectedFileHashes.contains(descriptorHash) {
                        continue
                    }

                    if isKnownFileMatch {
                        knownMatchPaths.insert(descriptor.url.path)
                        var tags = taggedPersonByPath[descriptor.url.path] ?? []
                        tags.insert(personName)
                        taggedPersonByPath[descriptor.url.path] = tags
                    }

                    if !isKnownFileMatch,
                       visualSignature.faceHashes.isEmpty {
                        continue
                    }

                    let faceScore: Double
                    if isKnownFileMatch {
                        faceScore = 1.0
                    } else {
                        guard let computedFaceScore = Self.bestFaceSimilarity(lhs: visualSignature.faceHashes, rhs: personFaceHashes),
                            computedFaceScore >= 0.78
                        else { continue }
                        faceScore = computedFaceScore
                    }

                    if !rejectedHashes.isEmpty,
                       !isKnownFileMatch,
                       visualSignature.faceHashes.allSatisfy({ rejectedHashes.contains($0) }) {
                        continue
                    }

                    let visualScore = bestVisualSimilarityBetween(
                        visualHash: visualSignature.hash,
                        descriptors: descriptors,
                        atPath: descriptor.url.path,
                        forPerson: personName,
                        usingPeopleAssignments: similarGroups
                    )
                    let weightedScore: Double
                    if isKnownFileMatch {
                        weightedScore = 1.0
                    } else {
                        weightedScore = (faceScore * 0.82) + (visualScore * 0.18)
                    }
                    guard weightedScore >= 0.76 else { continue }

                    matches.append((
                        file: DuplicateCandidateFile(
                            path: descriptor.url.path,
                            name: descriptor.url.lastPathComponent,
                            size: descriptor.size,
                            durationSeconds: descriptor.durationSeconds
                        ),
                        score: weightedScore
                    ))
                    personScoringMatchCount += 1
                }

                guard !matches.isEmpty else { continue }

                let sortedMatches = matches
                    .sorted { lhs, rhs in
                        if lhs.score != rhs.score { return lhs.score > rhs.score }
                        return lhs.file.name.localizedStandardCompare(rhs.file.name) == .orderedAscending
                    }
                    .prefix(48)

                let topFiles = sortedMatches.map(\ .file)
                let topScore = sortedMatches.first?.score ?? 0.0
                let topKnownPaths = topFiles.compactMap { knownMatchPaths.contains($0.path) ? $0.path : nil }
                let maxDetectedPeople = topFiles.map { detectedPeopleCount(for: $0.path) }.max() ?? 0
                let reasonSuffix = maxDetectedPeople > 1 ? " • up to \(maxDetectedPeople) people detected" : ""

                personGroups.append(
                    DuplicateCandidateGroup(
                        kind: .similarMetadata,
                        score: topScore,
                        reason: "Possible matches for \(personName)\(reasonSuffix)",
                        files: topFiles,
                        resolvedKeeperPaths: nil,
                        resolvedDestinationFolder: nil,
                        personName: personName,
                        isPersonReview: true,
                        knownMatchPaths: topKnownPaths
                    )
                )

                duplicateScanProgress = DuplicateScanProgress(
                    phase: .personScoring,
                    currentFileName: personName,
                    processed: personScoringFilesProcessed,
                    total: personScoringFilesTotal,
                    startedAt: startedAt,
                    potentialGroupCount: potentialGroupCount,
                    exactGroupCount: exactGroups.count,
                    similarGroupCount: similarAdjacency.count + personGroups.count,
                    faceIndexedCount: faceIndexedCount,
                    faceMatchCount: faceMatchCount,
                    visualMatchCount: visualMatchCount,
                    personScoringPeopleProcessed: min(peopleProcessed + 1, peopleTotal),
                    personScoringPeopleTotal: peopleTotal,
                    personScoringFilesProcessed: personScoringFilesProcessed,
                    personScoringFilesTotal: personScoringFilesTotal,
                    personScoringMatchCount: personScoringMatchCount
                )

                if peopleProcessed % 2 == 0 {
                    await Task.yield()
                }
            }
        }

        var catchAllGroups: [DuplicateCandidateGroup] = []
        if enableFaceMatching {
            let groupedPathsSource: [DuplicateCandidateGroup]
            if focusedPersonSearchActive || !showDuplicateStyleGroupsInResults {
                groupedPathsSource = personGroups
            } else {
                groupedPathsSource = personGroups + similarGroups
            }
            let groupedPaths = Set(groupedPathsSource.flatMap { group in
                group.files.map(\ .path)
            })

            let unmatchedDescriptors = descriptors
                .filter { !groupedPaths.contains($0.url.path) }
                .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }

            func toCandidateFile(_ descriptor: DuplicateDescriptor) -> DuplicateCandidateFile {
                DuplicateCandidateFile(
                    path: descriptor.url.path,
                    name: descriptor.url.lastPathComponent,
                    size: descriptor.size,
                    durationSeconds: descriptor.durationSeconds
                )
            }

            if focusedPersonSearchActive {
                if !unmatchedDescriptors.isEmpty {
                    let files = unmatchedDescriptors
                        .map(toCandidateFile)
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

                    let reason = focusedSearchPersonLabel.map { "Everything else (not likely \($0))" } ?? "Everything else (not likely focused person)"
                    catchAllGroups.append(
                        DuplicateCandidateGroup(
                            kind: .similarMetadata,
                            score: 0,
                            reason: reason,
                            files: files,
                            resolvedKeeperPaths: nil,
                            resolvedDestinationFolder: nil,
                            personName: focusedSearchPersonLabel,
                            isPersonReview: focusedSearchPersonLabel != nil,
                            knownMatchPaths: []
                        )
                    )
                }
            } else {
                func canClusterUnassigned(_ lhs: DuplicateDescriptor, _ rhs: DuplicateDescriptor) -> Bool {
                    guard lhs.visualKind == rhs.visualKind,
                          lhs.visualKind != .other,
                          let lhsSignature = lhs.visualSignature,
                          let rhsSignature = rhs.visualSignature
                    else { return false }

                    let distance = Self.hammingDistance(lhsSignature.hash, rhsSignature.hash)

                    if lhs.visualKind == .image {
                        return distance <= 9
                    }

                    if lhs.visualKind == .video {
                        guard let lhsDuration = lhs.durationSeconds,
                              let rhsDuration = rhs.durationSeconds,
                              lhsDuration > 0,
                              rhsDuration > 0
                        else { return false }

                        let runtimeScore = Self.normalizedSimilarity(lhsDuration, rhsDuration)
                        let aspectScore = Self.normalizedSimilarity(lhsSignature.aspectRatio, rhsSignature.aspectRatio)
                        return distance <= 11 && runtimeScore >= 0.94 && aspectScore >= 0.94
                    }

                    return false
                }

                var unassignedClusters: [[DuplicateDescriptor]] = []
                var unassignedMisc: [DuplicateDescriptor] = []

                for descriptor in unmatchedDescriptors {
                    if descriptor.visualKind == .other || descriptor.visualSignature == nil {
                        unassignedMisc.append(descriptor)
                        continue
                    }

                    var placed = false
                    for index in unassignedClusters.indices {
                        guard let representative = unassignedClusters[index].first else { continue }
                        if canClusterUnassigned(descriptor, representative) {
                            unassignedClusters[index].append(descriptor)
                            placed = true
                            break
                        }
                    }

                    if !placed {
                        unassignedClusters.append([descriptor])
                    }
                }

                var clusterNumber = 1
                for cluster in unassignedClusters {
                    if cluster.count == 1, let only = cluster.first {
                        unassignedMisc.append(only)
                        continue
                    }

                    let files = cluster
                        .map(toCandidateFile)
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

                    catchAllGroups.append(
                        DuplicateCandidateGroup(
                            kind: .similarMetadata,
                            score: 0.25,
                            reason: "Unassigned cluster \(clusterNumber)",
                            files: files,
                            resolvedKeeperPaths: nil,
                            resolvedDestinationFolder: nil,
                            personName: nil,
                            isPersonReview: false,
                            knownMatchPaths: []
                        )
                    )

                    clusterNumber += 1
                }

                if !unassignedMisc.isEmpty {
                    let files = unassignedMisc
                        .map(toCandidateFile)
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

                    catchAllGroups.append(
                        DuplicateCandidateGroup(
                            kind: .similarMetadata,
                            score: 0,
                            reason: "Unassigned files (manual review)",
                            files: files,
                            resolvedKeeperPaths: nil,
                            resolvedDestinationFolder: nil,
                            personName: nil,
                            isPersonReview: false,
                            knownMatchPaths: []
                        )
                    )
                }
            }
        }

        let groups = ((showDuplicateStyleGroupsInResults && !focusedPersonSearchActive ? exactGroups : [])
            + personGroups
            + (showDuplicateStyleGroupsInResults && !focusedPersonSearchActive ? similarGroups : [])
            + catchAllGroups)
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.files.first?.name.localizedStandardCompare(rhs.files.first?.name ?? "") == .orderedAscending
            }

        duplicateScanProgress = DuplicateScanProgress(
            phase: .finalizing,
            currentFileName: nil,
            processed: groups.count,
            total: max(groups.count, 1),
            startedAt: startedAt,
            potentialGroupCount: potentialGroupCount,
            exactGroupCount: exactGroups.count,
            similarGroupCount: similarGroups.count,
            faceIndexedCount: faceIndexedCount,
            faceMatchCount: faceMatchCount,
            visualMatchCount: visualMatchCount
        )

        isDuplicateScanning = false
        isDuplicateScanPaused = false
        duplicateScanTask = nil
        duplicateScanProgress = nil
        duplicateScanReport = DuplicateScanReport(
            startedAt: startedAt,
            finishedAt: Date(),
            scannedFileCount: descriptors.count,
            groups: groups
        )
        if !Task.isCancelled, focusedPersonName == nil {
            let modeForReport: AppMode = includeExactMatches ? .duplicateFinder : .similarityFinder
            storeScanCache(report: duplicateScanReport!, for: modeForReport, directory: directory, recursive: recursive)
        }
        ensureSelectedDuplicateGroupIsVisible()
        selectedDuplicateKeeperByGroupID = [:]
        selectedPersonForGroupID = [:]

        if Task.isCancelled {
            statusMessage = includeExactMatches ? "Duplicate scan stopped." : "People scan stopped."
        } else if didApplySimilarSafetyCap {
            statusMessage = includeExactMatches
                ? "Duplicate scan complete: \(groups.count) candidate groups. Similar matching was capped for performance."
                : (focusedPersonName == nil
                    ? "People scan complete: \(groups.count) candidate groups. Matching was capped for performance."
                    : "People search complete for \(focusedPersonName!): \(groups.count) candidate groups. Matching was capped for performance.")
        } else {
            statusMessage = includeExactMatches
                ? "Duplicate scan complete: \(groups.count) candidate groups."
                : (focusedPersonName == nil
                    ? "People scan complete: \(groups.count) candidate groups."
                    : "People search complete for \(focusedPersonName!): \(groups.count) candidate groups.")
        }

        if peopleModeOnly, skippedNonMatchableCount > 0 {
            statusMessage += " Skipped \(skippedNonMatchableCount) non-media file"
            if skippedNonMatchableCount != 1 {
                statusMessage += "s"
            }
            statusMessage += "."
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        let filesPerSecond = elapsed > 0 ? Double(filteredScanFiles.count) / elapsed : 0
        let avgHashMissMs = scanHashMissCount > 0
            ? (scanHashMissTotalSeconds / Double(scanHashMissCount)) * 1000
            : 0
        appendActivity(
            message: String(
                format: "Scan perf: %.1f files/s • hash misses %d (avg %.1f ms)",
                filesPerSecond,
                scanHashMissCount,
                avgHashMissMs
            ),
            severity: .info
        )
    }

    private func waitIfDuplicateScanPaused() async -> Bool {
        while isDuplicateScanPaused {
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        return !Task.isCancelled
    }

    private func duplicateFingerprint(for file: URL, size: Int64, modifiedAt: Date?) -> String {
        let modifiedComponent = modifiedAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "0"
        return "\(file.path)|\(size)|\(modifiedComponent)"
    }

    private func duplicateVisualKind(forExtension ext: String) -> DuplicateVisualKind {
        if imageExt.contains(ext) {
            return .image
        }
        if videoExt.contains(ext) {
            return .video
        }
        return .other
    }

    private func cachedVideoDuration(for file: URL, ext: String, fingerprint: String) async -> Double? {
        guard videoExt.contains(ext) else { return nil }

        if let cached = duplicateDurationCacheByFingerprint[fingerprint] {
            return cached < 0 ? nil : cached
        }

        let duration = await mediaDurationIfVideo(file)
        duplicateDurationCacheByFingerprint[fingerprint] = duration ?? -1
        return duration
    }

    private func cachedVisualSignature(for file: URL, ext: String, fingerprint: String, kind: DuplicateVisualKind) async -> DuplicateVisualSignature? {
        guard kind != .other else { return nil }

        if let cached = duplicateVisualSignatureCacheByFingerprint[fingerprint] {
            return cached
        }
        if duplicateVisualHashMissesByFingerprint.contains(fingerprint) {
            return nil
        }

        let signature: DuplicateVisualSignature?
        switch kind {
        case .image:
            signature = await Task.detached(priority: .utility) {
                Self.imageVisualSignatureStatic(at: file)
            }.value
        case .video:
            signature = await Task.detached(priority: .utility) {
                await Self.videoVisualSignatureStatic(at: file)
            }.value
        case .other:
            signature = nil
        }

        if let signature {
            duplicateVisualSignatureCacheByFingerprint[fingerprint] = signature
        } else {
            duplicateVisualHashMissesByFingerprint.insert(fingerprint)
        }

        return signature
    }

    private func cachedFileHash(for descriptor: DuplicateDescriptor) async -> String {
        if let cached = duplicateHashCacheByFingerprint[descriptor.fingerprint] {
            return cached
        }

        let hashStartedAt = Date()
        let hash = await Task.detached(priority: .utility) {
            Self.fileHashStatic(at: descriptor.url)
        }.value
        scanHashMissCount += 1
        scanHashMissTotalSeconds += Date().timeIntervalSince(hashStartedAt)

        if !hash.isEmpty {
            duplicateHashCacheByFingerprint[descriptor.fingerprint] = hash
        }
        return hash
    }

    private func bestVisualSimilarityBetween(
        visualHash: UInt64,
        descriptors: [DuplicateDescriptor],
        atPath: String,
        forPerson _: String,
        usingPeopleAssignments _: [DuplicateCandidateGroup]
    ) -> Double {
        var best = 0.0
        for descriptor in descriptors {
            guard descriptor.url.path != atPath,
                  let other = descriptor.visualSignature
            else { continue }
            let distance = Self.hammingDistance(visualHash, other.hash)
            let score = max(0, 1 - (Double(distance) / 64.0))
            if score > best {
                best = score
                if best >= 0.98 {
                    return best
                }
            }
        }

        return best
    }

    private func selectedDuplicateGroup() -> DuplicateCandidateGroup? {
        guard let report = duplicateScanReport,
              !report.groups.isEmpty
        else { return nil }

        let visibleGroups = visibleDuplicateGroups(in: report)
        guard !visibleGroups.isEmpty else { return nil }

        if let selectedDuplicateGroupID,
           let matched = visibleGroups.first(where: { $0.id == selectedDuplicateGroupID }) {
            return matched
        }

        return visibleGroups.first
    }

    private func visibleDuplicateGroups(in report: DuplicateScanReport) -> [DuplicateCandidateGroup] {
        guard appMode == .similarityFinder, !showKnownPersonReviewBatches else {
            return report.groups
        }

        return report.groups.filter { group in
            guard group.isPersonReview, group.personName != nil else {
                return true
            }

            let knownPaths = Set(group.knownMatchPaths ?? [])
            guard !group.files.isEmpty else { return false }
            let allKnown = group.files.allSatisfy { knownPaths.contains($0.path) }
            return !allKnown
        }
    }

    private func ensureSelectedDuplicateGroupIsVisible() {
        guard let report = duplicateScanReport else {
            selectedDuplicateGroupID = nil
            return
        }

        let visibleGroups = visibleDuplicateGroups(in: report)
        guard !visibleGroups.isEmpty else {
            selectedDuplicateGroupID = nil
            return
        }

        if let selectedDuplicateGroupID,
           visibleGroups.contains(where: { $0.id == selectedDuplicateGroupID }) {
            return
        }

        if let focusedPerson = focusedPersonSearchName,
           let preferredFocusedUnresolved = visibleGroups.first(where: { group in
               guard group.isPersonReview,
                     group.resolvedKeeperPaths == nil,
                     let groupPerson = group.personName
               else { return false }
               return groupPerson.caseInsensitiveCompare(focusedPerson) == .orderedSame
           }) {
            selectedDuplicateGroupID = preferredFocusedUnresolved.id
            return
        }

        if let focusedPerson = focusedPersonSearchName,
           let preferredFocused = visibleGroups.first(where: { group in
               guard group.isPersonReview,
                     let groupPerson = group.personName
               else { return false }
               return groupPerson.caseInsensitiveCompare(focusedPerson) == .orderedSame
           }) {
            selectedDuplicateGroupID = preferredFocused.id
            return
        }

        if let unresolved = visibleGroups.first(where: { $0.resolvedKeeperPaths == nil }) {
            selectedDuplicateGroupID = unresolved.id
            return
        }

        selectedDuplicateGroupID = visibleGroups.first?.id
    }

    private func mediaDurationIfVideo(_ file: URL) async -> Double? {
        let ext = file.pathExtension.lowercased()
        guard videoExt.contains(ext) else { return nil }

        let asset = AVURLAsset(url: file)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            return nil
        }

        let seconds = CMTimeGetSeconds(duration)
        if seconds.isFinite, seconds > 0 {
            return seconds
        }
        return nil
    }

    private func registerSessionOutcome(_ outcome: SessionFileOutcome, for path: String) {
        if let existing = sessionOutcomeByPath[path] {
            switch (existing, outcome) {
            case (.moved, .skipped), (.duplicate, .skipped), (.renamed, .skipped):
                return
            case (.moved, _), (.duplicate, _), (.renamed, _):
                return
            default:
                break
            }
        }

        sessionOutcomeByPath[path] = outcome
        refreshSessionOutcomeCounters()
    }

    private func removeSessionOutcome(for path: String) {
        sessionOutcomeByPath.removeValue(forKey: path)
        refreshSessionOutcomeCounters()
    }

    private func refreshSessionOutcomeCounters() {
        var moved = 0
        var duplicate = 0
        var renamed = 0
        var skipped = 0

        for outcome in sessionOutcomeByPath.values {
            switch outcome {
            case .moved:
                moved += 1
            case .duplicate:
                duplicate += 1
            case .renamed:
                renamed += 1
            case .skipped:
                skipped += 1
            }
        }

        sessionMovedCount = moved
        sessionDuplicateCount = duplicate
        sessionRenamedCount = renamed
        sessionSkippedCount = skipped
    }

    private func presentTransientToast(message: String) {
        transientToastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            if self.transientToastMessage == message {
                self.transientToastMessage = ""
            }
        }
    }

    private func appendActivity(message: String, severity: ActivitySeverity) {
        let entry = ActivityLogEntry(timestamp: Date(), message: message, severity: severity)
        activityLog.append(entry)
        if activityLog.count > 300 {
            activityLog.removeFirst(activityLog.count - 300)
        }
    }

    private func showStatusToast(message: String, severity: ActivitySeverity) {
        let entry = ActivityLogEntry(timestamp: Date(), message: message, severity: severity)
        statusToastEntry = entry
        statusToastTask?.cancel()
        statusToastTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            if self.statusToastEntry == entry {
                self.statusToastEntry = nil
            }
        }
    }

    private func classifySeverity(for message: String) -> ActivitySeverity {
        let normalized = message.lowercased()

        if normalized.contains("failed") || normalized.contains("error") || normalized.contains("unavailable") {
            return .error
        }

        if normalized.contains("duplicate") || normalized.contains("cancelled") || normalized.contains("skipped") || normalized.contains("warning") {
            return .warning
        }

        if normalized.contains("moved") || normalized.contains("opened") || normalized.contains("revealed") || normalized.contains("loaded") || normalized.contains("complete") || normalized.contains("renamed") || normalized.contains("tagged") || normalized.contains("confirmed") || normalized.contains("selected") || normalized.contains("set to") || normalized.contains("enabled") || normalized.contains("disabled") || normalized.contains("cleared") || normalized.contains("tracking") || normalized.contains("updated") {
            return .success
        }

        return .info
    }

    private func toastSummary(for message: String) -> String? {
        let normalized = message.lowercased()

        if normalized.hasPrefix("duplicate (trashed):") {
            return "Removed Duplicate"
        }
        if normalized.hasPrefix("moved:") || normalized.contains("moved:") {
            return "Moved File"
        }
        if normalized.hasPrefix("renamed:") || normalized.contains("renamed:") {
            return "Renamed File"
        }
        if normalized.contains("skipped") {
            return "Skipped File"
        }
        if normalized.contains("move failed") || normalized.contains("failed") || normalized.contains("error") {
            return "Action Failed"
        }

        return nil
    }

    private func updateCurrentFilePresentation() {
        guard let file = currentFile else {
            currentFileIcon = nil
            currentFileMetadataLine = ""
            currentFileSourceURLs = []
            isLoadingCurrentFileSources = false
            currentFolderSuggestionHint = ""
            currentFolderSuggestionSourceDetail = ""
            currentSuggestedFolder = nil
            return
        }

        if isAutoSorting {
            currentFileIcon = nil
            currentFileMetadataLine = ""
            currentFileSourceURLs = []
            isLoadingCurrentFileSources = false
            currentFolderSuggestionHint = ""
            currentFolderSuggestionSourceDetail = ""
            currentSuggestedFolder = nil
            return
        }

        currentFileIcon = NSWorkspace.shared.icon(forFile: file.path)

        var parts: [String] = []
        if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            if let fileSize = values.fileSize {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
            }
            if let modified = values.contentModificationDate {
                parts.append("Modified \(Self.dateFormatter.string(from: modified))")
            }
        }

        let baseLine = parts.joined(separator: " • ")
        currentFileMetadataLine = baseLine
        currentFileSourceURLs = []
        isLoadingCurrentFileSources = true
        applyFolderSuggestion(suggestedFolderMatch(for: file), for: file)

        let expectedPath = file.path
        Task {
            let media = await mediaMetadata(for: file)
            guard self.currentFile?.path == expectedPath else { return }
            guard let media, !media.isEmpty else { return }

            if baseLine.isEmpty {
                self.currentFileMetadataLine = media
            } else {
                self.currentFileMetadataLine = "\(baseLine) • \(media)"
            }
        }

        Task {
            let sources = await Task.detached(priority: .utility) {
                Self.metadataWhereFromURLs(for: file)
            }.value
            guard self.currentFile?.path == expectedPath else { return }
            self.sourceURLsByFilePath[expectedPath] = sources
            self.currentFileSourceURLs = sources
            self.isLoadingCurrentFileSources = false
            self.applyFolderSuggestion(self.suggestedFolderMatch(for: file), for: file)
        }
    }

    private func applyFolderSuggestion(_ suggestion: FolderSuggestion?, for file: URL) {
        if let suggestion {
            currentFolderSuggestionHint = suggestion.hint
            currentFolderSuggestionSourceDetail = suggestion.sourceDetail ?? ""
            currentSuggestedFolder = suggestion.folder

            if let debugMessage = suggestion.debugMessage {
                let debugKey = "\(file.path)|\(debugMessage)"
                if lastSuggestionDebugLogKey != debugKey {
                    appendActivity(message: debugMessage, severity: .info)
                    lastSuggestionDebugLogKey = debugKey
                }
            }
            return
        }

        currentFolderSuggestionHint = ""
        currentFolderSuggestionSourceDetail = ""
        currentSuggestedFolder = nil
    }

    private func mediaMetadata(for file: URL) async -> String? {
        let ext = file.pathExtension.lowercased()
        guard videoExt.contains(ext) || audioExt.contains(ext) else { return nil }

        let asset = AVURLAsset(url: file)
        var details: [String] = []

        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            return nil
        }

        let durationSeconds = CMTimeGetSeconds(duration)
        if durationSeconds.isFinite, durationSeconds > 0 {
            details.append(formatDuration(durationSeconds))
        }

        if let codec = await firstCodecLabel(in: asset) {
            details.append(codec)
        }

        return details.isEmpty ? nil : details.joined(separator: " • ")
    }

    private func firstCodecLabel(in asset: AVAsset) async -> String? {
        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
           let formatDescriptions = try? await videoTrack.load(.formatDescriptions),
           let desc = formatDescriptions.first {
            let subtype = CMFormatDescriptionGetMediaSubType(desc)
            return fourCCString(subtype)
        }

        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let formatDescriptions = try? await audioTrack.load(.formatDescriptions),
           let desc = formatDescriptions.first {
            let subtype = CMFormatDescriptionGetMediaSubType(desc)
            return fourCCString(subtype)
        }

        return nil
    }

    private func fourCCString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 <= 126 }
        if printable {
            return String(bytes: bytes, encoding: .ascii)?.lowercased() ?? "codec:\(value)"
        }
        return "codec:\(value)"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private nonisolated static func contextSearchURL(fileStem: String, sourceURLs: [URL]) -> URL? {
        let trimmedStem = fileStem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStem.isEmpty else { return nil }

        let vectors = searchVectors(from: trimmedStem)
        var query = vectors.first ?? trimmedStem
        if let hostHint = preferredSourceHost(from: sourceURLs) {
            query += " site:\(hostHint)"
        }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }

    private nonisolated static func preferredSourceHost(from sourceURLs: [URL]) -> String? {
        let hosts = sourceURLs
            .compactMap { $0.host?.lowercased() }
            .compactMap(baseDomain(for:))
            .filter { !$0.isEmpty }
        guard !hosts.isEmpty else { return nil }

        let counts = Dictionary(hosts.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }?.key
    }

    private nonisolated static func searchVectors(from stem: String) -> [String] {
        let lower = stem.lowercased()
        let parts = lower
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }

        let numericIDs = parts.filter { token in
            token.count >= 5 && token.allSatisfy(\ .isNumber)
        }
        if !numericIDs.isEmpty {
            return numericIDs
        }

        let noiseTokens: Set<String> = [
            "uhd", "fhd", "hd", "sd", "fps", "video", "clip", "source",
            "x264", "x265", "h264", "h265", "hevc", "avc", "hdr", "mov", "mp4", "mkv", "webm",
        ]

        let informative = parts.filter { token in
            if token.count < 3 { return false }
            if noiseTokens.contains(token) { return false }
            if token.allSatisfy(\ .isNumber) { return false }

            if token.hasSuffix("p"),
               token.dropLast().allSatisfy(\ .isNumber) {
                return false
            }

            return true
        }

        if !informative.isEmpty {
            return [informative.prefix(4).joined(separator: " ")]
        }

        return [stem]
    }

    private nonisolated static func baseDomain(for host: String) -> String? {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host.isEmpty ? nil : host }

        let last = labels[labels.count - 1]
        let secondLast = labels[labels.count - 2]

        if last.count == 2, secondLast.count <= 3, labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }

        return labels.suffix(2).joined(separator: ".")
    }

    private nonisolated static func metadataWhereFromURLs(for file: URL) -> [URL] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
        process.arguments = ["-raw", "-name", "kMDItemWhereFroms", file.path]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  raw != "(null)"
            else { return [] }

            let regex = try NSRegularExpression(pattern: "\"(.*?)\"")
            let range = NSRange(location: 0, length: raw.utf16.count)
            let matches = regex.matches(in: raw, range: range)
            return matches.compactMap { match -> URL? in
                guard match.numberOfRanges > 1,
                      let matchRange = Range(match.range(at: 1), in: raw)
                else { return nil }
                let value = String(raw[matchRange])
                return URL(string: value)
            }
            .filter { url in
                guard let scheme = url.scheme?.lowercased() else { return false }
                return scheme == "http" || scheme == "https"
            }
        } catch {
            return []
        }
    }

    private func openURLsWithSettings(_ urls: [URL]) -> Bool {
        let appName = settings.browserApp.trimmingCharacters(in: .whitespacesAndNewlines)

        if appName.isEmpty {
            for url in urls {
                NSWorkspace.shared.open(url)
            }
            return true
        }

        guard let appURL = resolvedBrowserAppURL(for: appName) else {
            return false
        }

        let privateFlag = settings.browserPrivate ? browserPrivateFlag(for: appName) : nil

        if privateFlag == nil {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration)
            return true
        }

        for url in urls {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

            if let privateFlag {
                process.arguments = ["-na", appURL.path, "--args", privateFlag, url.absoluteString]
            } else {
                process.arguments = ["-a", appURL.path, url.absoluteString]
            }

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    return false
                }
            } catch {
                return false
            }
        }

        return true
    }

    private func resolvedBrowserAppURL(for appName: String) -> URL? {
        guard let probeURL = URL(string: "https://example.com") else { return nil }
        let target = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        let candidates = NSWorkspace.shared.urlsForApplications(toOpen: probeURL)
        if candidates.isEmpty { return nil }

        let loweredTarget = target.lowercased()
        for appURL in candidates {
            if let bundle = Bundle(url: appURL) {
                if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                   displayName.lowercased() == loweredTarget {
                    return appURL
                }
                if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                   name.lowercased() == loweredTarget {
                    return appURL
                }
                if let bundleID = bundle.bundleIdentifier,
                   bundleID.lowercased() == loweredTarget {
                    return appURL
                }
            }

            let fileName = appURL.deletingPathExtension().lastPathComponent.lowercased()
            if fileName == loweredTarget {
                return appURL
            }
        }

        return candidates.first
    }

    private func browserPrivateFlag(for appName: String) -> String? {
        let lower = appName.lowercased()
        if lower.contains("brave") { return "--incognito" }
        if lower.contains("chrome") { return "--incognito" }
        if lower.contains("edge") { return "--inprivate" }
        if lower.contains("firefox") { return "--private-window" }
        if lower.contains("arc") { return "--incognito" }
        return nil
    }

    private func presentErrorSheet(title: String, message: String) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private nonisolated static func collectFiles(in directory: URL, recursive: Bool) -> [URL] {
        let manager = FileManager.default
        var results: [URL] = []

        if recursive {
            if let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey], options: [.skipsPackageDescendants]) {
                for case let candidate as URL in enumerator {
                    if candidate.lastPathComponent.hasPrefix(".") { continue }
                    let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
                    if values?.isHidden == true { continue }
                    if values?.isRegularFile == true {
                        results.append(candidate)
                    }
                }
            }
        } else {
            let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey], options: [])) ?? []
            for candidate in entries {
                if candidate.lastPathComponent.hasPrefix(".") { continue }
                let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
                if values?.isHidden == true { continue }
                if values?.isRegularFile == true {
                    results.append(candidate)
                }
            }
        }

        return results.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private nonisolated static func collectFolders(in directory: URL) -> [String] {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey], options: [])) ?? []
        let names = entries.compactMap { url -> String? in
            if url.lastPathComponent.hasPrefix(".") { return nil }
            if url.lastPathComponent == "_unsorted_" { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
            if values?.isHidden == true { return nil }
            guard values?.isDirectory == true else { return nil }
            return url.lastPathComponent
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func suggestedFolder(for file: URL) -> String? {
        suggestedFolderMatch(for: file)?.folder
    }

    private func suggestedFolderMatch(for file: URL) -> FolderSuggestion? {
        if let seriesSuggestion = seriesSuggestedFolder(for: file) {
            return seriesSuggestion
        }

        return directSuggestedFolderMatch(for: file)
    }

    private func directSuggestedFolderMatch(for file: URL) -> FolderSuggestion? {
        let tagged = taggedPeople(for: file.path)
        if !tagged.isEmpty {
            if let existingMatch = tagged.compactMap({ taggedName in
                folders.first(where: { $0.caseInsensitiveCompare(taggedName) == .orderedSame })
            }).first {
                return FolderSuggestion(
                    folder: existingMatch,
                    hint: "Suggested from person tag",
                    sourceDetail: "Match source: tagged people"
                )
            }

            if let firstTagged = tagged.first {
                return FolderSuggestion(
                    folder: firstTagged,
                    hint: "Suggested new folder from person tag",
                    sourceDetail: "Match source: tagged people"
                )
            }
        }

        let fileName = file.lastPathComponent

        if let username = extractUsername(from: fileName),
           let match = folders.first(where: { $0.caseInsensitiveCompare(username) == .orderedSame }) {
            return FolderSuggestion(folder: match, hint: "Suggested from filename username: @\(username)", sourceDetail: nil)
        }

        if let match = metadataSuggestedFolder(for: file) {
            return match
        }

        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.lowercased()
        if let match = folders.first(where: { stem.contains($0.lowercased()) }) {
            return FolderSuggestion(folder: match, hint: "Suggested from filename text", sourceDetail: nil)
        }

        return nil
    }

    private func seriesSuggestedFolder(for file: URL) -> FolderSuggestion? {
        guard let seriesInfo = filenameSeriesInfo(for: file) else { return nil }
        let setHint = seriesHintText(for: seriesInfo)

        if let learnedFolder = suggestedFolderBySeriesKey[seriesInfo.key],
           let match = folders.first(where: { $0.caseInsensitiveCompare(learnedFolder) == .orderedSame }) {
            return FolderSuggestion(
                folder: match,
                hint: setHint,
                sourceDetail: "Match source: current session",
                debugMessage: nil
            )
        }

        if let existingFolder = destinationSeriesFolderByKey[seriesInfo.key],
           let match = folders.first(where: { $0.caseInsensitiveCompare(existingFolder) == .orderedSame }) {
            return FolderSuggestion(
                folder: match,
                hint: "Suggested from existing \(setHint.lowercased())",
                sourceDetail: "Match source: existing sorted folders",
                debugMessage: nil
            )
        }

        for candidate in files {
            if candidate.path == file.path { continue }
            guard let candidateSeriesInfo = filenameSeriesInfo(for: candidate),
                  candidateSeriesInfo.key == seriesInfo.key
            else { continue }

            if let match = directSuggestedFolderMatch(for: candidate) {
                return FolderSuggestion(
                    folder: match.folder,
                    hint: setHint,
                    sourceDetail: "Match source: another file in this queue",
                    debugMessage: nil
                )
            }
        }

        return nil
    }

    private func metadataSuggestedFolder(for file: URL) -> FolderSuggestion? {
        guard let sourceURLs = sourceURLsByFilePath[file.path] else {
            return nil
        }

        for sourceURL in sourceURLs {
            if let match = metadataFolderMatch(from: sourceURL) {
                return match
            }
        }

        return nil
    }

    private func metadataFolderMatch(from sourceURL: URL) -> FolderSuggestion? {
        for candidate in metadataUsernameCandidates(from: sourceURL) {
            if let match = folderMatch(forCandidate: candidate) {
                let host = sourceURL.host?.lowercased() ?? "unknown-host"
                let debug = "Metadata suggestion: @\(candidate) via \(host)"
                return FolderSuggestion(
                    folder: match,
                    hint: "Suggested from metadata: @\(candidate)",
                    sourceDetail: "Match source: metadata URL",
                    debugMessage: debug
                )
            }
        }

        return nil
    }

    private func metadataUsernameCandidates(from sourceURL: URL) -> [String] {
        var orderedCandidates: [String] = []
        var seen = Set<String>()

        func add(_ value: String?) {
            guard let value,
                  !value.isEmpty
            else { return }
            let lowered = value.lowercased()
            guard !seen.contains(lowered) else { return }
            seen.insert(lowered)
            orderedCandidates.append(value)
        }

        for candidate in socialUsernameCandidates(from: sourceURL) {
            add(candidate)
        }

        if let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) {
            let usernameKeys = Set([
                "screen_name", "username", "user", "author", "creator", "handle", "owner", "profile", "account", "by", "u",
            ])

            for item in components.queryItems ?? [] {
                if usernameKeys.contains(item.name.lowercased()) {
                    add(extractUsernameToken(from: item.value))
                }

                if let nested = extractFirstUsernameFromNestedURL(value: item.value) {
                    add(nested)
                }
            }
        }

        for candidate in usernameMatches(in: sourceURL.absoluteString) {
            add(candidate)
        }

        return orderedCandidates
    }

    private func socialUsernameCandidates(from sourceURL: URL) -> [String] {
        guard let host = sourceURL.host?.lowercased() else { return [] }
        let supportedHosts = Set([
            "twitter.com", "www.twitter.com", "mobile.twitter.com", "m.twitter.com",
            "x.com", "www.x.com", "mobile.x.com", "m.x.com",
        ])
        guard supportedHosts.contains(host) else { return [] }

        let blocked = Set(["i", "intent", "home", "explore", "search", "share", "hashtag", "messages", "settings", "compose"])
        let parts = sourceURL.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        var candidates: [String] = []
        var seen = Set<String>()

        func add(_ value: String?) {
            guard let value,
                  !value.isEmpty
            else { return }
            let lowered = value.lowercased()
            guard !seen.contains(lowered) else { return }
            seen.insert(lowered)
            candidates.append(value)
        }

        if let first = parts.first {
            let cleanedFirst = first.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            let lower = cleanedFirst.lowercased()
            if !blocked.contains(lower),
               lower != "status" {
                add(extractUsernameToken(from: cleanedFirst))
            }
        }

        for (index, part) in parts.enumerated() where part.lowercased() == "status" {
            guard index > 0 else { continue }
            let previous = parts[index - 1].trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            add(extractUsernameToken(from: previous))
        }

        for part in parts where part.hasPrefix("@") {
            add(extractUsernameToken(from: part))
        }

        return candidates
    }

    private func extractFirstUsernameFromNestedURL(value: String?) -> String? {
        guard let value,
              !value.isEmpty
        else { return nil }

        if let directURL = URL(string: value),
           let nested = socialUsernameCandidates(from: directURL).first {
            return nested
        }

        if let decoded = value.removingPercentEncoding,
           let decodedURL = URL(string: decoded),
           let nested = socialUsernameCandidates(from: decodedURL).first {
            return nested
        }

        return usernameMatches(in: value).first
    }

    private func extractUsernameToken(from value: String?) -> String? {
        guard let value,
              !value.isEmpty
        else { return nil }

        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@#?/&=.,:;!()[]{}\"'"))
        guard !trimmed.isEmpty else { return nil }

        if let regex = try? NSRegularExpression(pattern: "([A-Za-z0-9_]{2,32})") {
            let nsRange = NSRange(location: 0, length: trimmed.utf16.count)
            if let hit = regex.firstMatch(in: trimmed, range: nsRange),
               hit.numberOfRanges > 1,
               let range = Range(hit.range(at: 1), in: trimmed) {
                return String(trimmed[range])
            }
        }

        return nil
    }

    private func usernameMatches(in text: String) -> [String] {
        let patterns = [
            "(?:x|twitter)\\.com/(?:@)?([A-Za-z0-9_]{2,32})",
            "@([A-Za-z0-9_]{2,32})",
        ]

        var results: [String] = []
        var seen = Set<String>()

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(location: 0, length: text.utf16.count)
            for hit in regex.matches(in: text, range: range) {
                guard hit.numberOfRanges > 1,
                      let matchRange = Range(hit.range(at: 1), in: text)
                else { continue }
                let candidate = String(text[matchRange])
                let lowered = candidate.lowercased()
                if !seen.contains(lowered) {
                    seen.insert(lowered)
                    results.append(candidate)
                }
            }
        }

        return results
    }

    private func folderMatch(forCandidate candidate: String?) -> String? {
        guard var token = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }

        if token.hasPrefix("@") {
            token.removeFirst()
        }

        guard !token.isEmpty else { return nil }
        return folders.first { $0.caseInsensitiveCompare(token) == .orderedSame }
    }

    private func extractUsername(from fileName: String) -> String? {
        guard let usernameRegex,
              let match = usernameRegex.firstMatch(in: fileName, range: NSRange(location: 0, length: fileName.utf16.count)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: fileName)
        else { return nil }
        return String(fileName[range])
    }

    private func filenameSeriesInfo(for file: URL) -> FilenameSeriesInfo? {
        let stem = file.deletingPathExtension().lastPathComponent
        return filenameSeriesInfoFromStem(stem)
    }

    private func filenameSeriesInfoFromStem(_ stem: String) -> FilenameSeriesInfo? {
        guard let filenameSeriesRegex else { return nil }

        let range = NSRange(location: 0, length: stem.utf16.count)
        if let match = filenameSeriesRegex.firstMatch(in: stem, range: range),
           match.numberOfRanges == 4,
           let titleRange = Range(match.range(at: 1), in: stem),
           let partRange = Range(match.range(at: 2), in: stem),
           let totalRange = Range(match.range(at: 3), in: stem),
           let part = Int(stem[partRange]),
           let total = Int(stem[totalRange]),
           total > 1,
           part >= 1,
           part <= total {
            let normalizedTitle = normalizeSeriesTitle(String(stem[titleRange]))
            if !normalizedTitle.isEmpty {
                return FilenameSeriesInfo(
                    key: "\(normalizedTitle)|\(total)",
                    part: part,
                    total: total,
                    kind: .bracketed
                )
            }
        }

        guard let numberedPrefixRegex,
              let prefixMatch = numberedPrefixRegex.firstMatch(in: stem, range: range),
              prefixMatch.numberOfRanges == 3,
              let partRange = Range(prefixMatch.range(at: 1), in: stem),
              let titleRange = Range(prefixMatch.range(at: 2), in: stem),
              let part = Int(stem[partRange]),
              part >= 1
        else { return nil }

        let normalizedTitle = normalizeSeriesTitle(String(stem[titleRange]))
        guard let fallbackKey = numberedPrefixFallbackKey(for: normalizedTitle) else { return nil }

        return FilenameSeriesInfo(
            key: fallbackKey,
            part: part,
            total: nil,
            kind: .numberedPrefix
        )
    }

    private func numberedPrefixFallbackKey(for normalizedTitle: String) -> String? {
        guard normalizedTitle.count >= 12 else { return nil }
        let prefix = String(normalizedTitle.prefix(42))
        guard !prefix.isEmpty else { return nil }
        return "prefix|\(prefix)"
    }

    private func seriesHintText(for info: FilenameSeriesInfo) -> String {
        switch info.kind {
        case .bracketed:
            if let total = info.total {
                return "Suggested from filename set [\(info.part) - \(total)]"
            }
            return "Suggested from filename set"
        case .numberedPrefix:
            return "Suggested from numbered filename prefix"
        }
    }

    private nonisolated static func collectSeriesFolderMappings(
        in destinationDirectory: URL,
        folders: [String],
        parser: @escaping (String) -> FilenameSeriesInfo?
    ) -> [String: String] {
        guard !folders.isEmpty else { return [:] }

        let manager = FileManager.default
        var mappings: [String: String] = [:]

        for folderName in folders {
            let folderURL = destinationDirectory.appendingPathComponent(folderName, isDirectory: true)
            let entries = (try? manager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                options: [.skipsPackageDescendants]
            )) ?? []

            for fileURL in entries {
                if fileURL.lastPathComponent.hasPrefix(".") { continue }
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
                if values?.isHidden == true { continue }
                guard values?.isRegularFile == true else { continue }

                let stem = fileURL.deletingPathExtension().lastPathComponent
                guard let info = parser(stem) else { continue }
                if mappings[info.key] == nil {
                    mappings[info.key] = folderName
                }
            }
        }

        return mappings
    }

    private func normalizeSeriesTitle(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func fuzzyScore(query: String, target: String) -> Int {
        if query.isEmpty { return 0 }
        if query == target { return 3 }
        if target.hasPrefix(query) || target.contains(query) { return 2 }

        var cursor = target.startIndex
        for character in query {
            if let idx = target[cursor...].firstIndex(of: character) {
                cursor = target.index(after: idx)
            } else {
                return 0
            }
        }
        return 1
    }

    private struct MoveResult {
        enum Outcome {
            case moved
            case duplicate
            case renamed
        }

        let outcome: Outcome
        let message: String
        let resultURL: URL?
    }

    private struct DuplicateRemovalCancelledError: LocalizedError {
        var errorDescription: String? { "Duplicate removal cancelled." }
    }

    private struct TrashFailedError: LocalizedError {
        let underlying: Error
        var errorDescription: String? { "Could not move duplicate to Trash: \(underlying.localizedDescription)" }
    }

    private func suggestedSimilarityFolderName(for group: DuplicateCandidateGroup, sequence: Int) -> String {
        let preferred = group.files.first?.name ?? ""
        let stem = URL(fileURLWithPath: preferred).deletingPathExtension().lastPathComponent
        let cleaned = stem
            .replacingOccurrences(of: #"[^\p{L}\p{N}\-_ ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let fallback = String(format: "Person %03d", sequence)
        if cleaned.isEmpty {
            return fallback
        }

        if cleaned.count > 48 {
            let idx = cleaned.index(cleaned.startIndex, offsetBy: 48)
            return String(cleaned[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned
    }

    private func normalizedPersonName(_ raw: String) -> String? {
        let collapsed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }

    private func persistPeopleRecognitionSettings() {
        let snapshot = makePeopleRecognitionSnapshot()
        trackedPeople = snapshot.trackedPeople
        invalidateModeScanCaches()

        do {
            try peopleStore.saveSnapshot(snapshot)
        } catch {
            statusMessage = "Failed to save people database: \(error.localizedDescription)"
        }
    }

    private func cachedScanReport(for mode: AppMode, directory: URL, recursive: Bool) -> DuplicateScanReport? {
        let targetPath = directory.standardizedFileURL.path
        let cache: ModeScanCache?
        switch mode {
        case .duplicateFinder:
            cache = duplicateFinderScanCache
        case .similarityFinder:
            cache = peopleScanCache
        default:
            cache = nil
        }

        guard let cache,
              cache.directoryPath == targetPath,
              cache.recursive == recursive
        else { return nil }

        return cache.report
    }

    private func storeScanCache(report: DuplicateScanReport, for mode: AppMode, directory: URL, recursive: Bool) {
        let cache = ModeScanCache(
            directoryPath: directory.standardizedFileURL.path,
            recursive: recursive,
            report: report
        )

        switch mode {
        case .duplicateFinder:
            duplicateFinderScanCache = cache
        case .similarityFinder:
            peopleScanCache = cache
        default:
            break
        }
    }

    private func clearScanCache(for mode: AppMode) {
        switch mode {
        case .duplicateFinder:
            duplicateFinderScanCache = nil
        case .similarityFinder:
            peopleScanCache = nil
        default:
            break
        }
    }

    private func invalidateModeScanCaches() {
        duplicateFinderScanCache = nil
        peopleScanCache = nil
    }

    private func makePeopleRecognitionSnapshot() -> PeopleRecognitionSnapshot {
        let sortedPeople = trackedPeople.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return PeopleRecognitionSnapshot(
            trackedPeople: sortedPeople,
            learnedFaceHashesByName: learnedPersonFaceHashesByName,
            rejectedFaceHashesByName: rejectedPersonFaceHashesByName,
            learnedFileHashesByName: learnedPersonFileHashesByName,
            rejectedFileHashesByName: rejectedPersonFileHashesByName
        )
    }

    private static func legacyPeopleRecognitionSnapshot(from settings: AppSettings) -> PeopleRecognitionSnapshot {
        PeopleRecognitionSnapshot(
            trackedPeople: settings.trackedPeople,
            learnedFaceHashesByName: Dictionary(uniqueKeysWithValues: settings.personFaceHashesByName.map { key, value in
                (key, Set(value))
            }),
            rejectedFaceHashesByName: Dictionary(uniqueKeysWithValues: settings.personRejectedFaceHashesByName.map { key, value in
                (key, Set(value))
            }),
            learnedFileHashesByName: Dictionary(uniqueKeysWithValues: settings.personFileHashesByName.map { key, value in
                (key, Set(value))
            }),
            rejectedFileHashesByName: Dictionary(uniqueKeysWithValues: settings.personRejectedFileHashesByName.map { key, value in
                (key, Set(value))
            })
        )
    }

    private func applyPeopleRecognitionSnapshot(_ snapshot: PeopleRecognitionSnapshot) {
        trackedPeople = snapshot.trackedPeople.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        learnedPersonFaceHashesByName = snapshot.learnedFaceHashesByName
        rejectedPersonFaceHashesByName = snapshot.rejectedFaceHashesByName
        learnedPersonFileHashesByName = snapshot.learnedFileHashesByName
        rejectedPersonFileHashesByName = snapshot.rejectedFileHashesByName
    }

    private func bootstrapPeopleRecognitionState(legacySettings: AppSettings) -> Bool {
        let legacySnapshot = Self.legacyPeopleRecognitionSnapshot(from: legacySettings)
        let dbSnapshot = (try? peopleStore.loadSnapshot()) ?? .empty

        if dbSnapshot.isEmpty && !legacySnapshot.isEmpty {
            applyPeopleRecognitionSnapshot(legacySnapshot)
            do {
                try peopleStore.saveSnapshot(legacySnapshot)
                return true
            } catch {
                statusMessage = "Failed to finalize people migration: \(error.localizedDescription)"
                return false
            }
        } else {
            applyPeopleRecognitionSnapshot(dbSnapshot)
            return false
        }
    }

    private func addKnownFileHashForPerson(path: String, personName: String) {
        let hash = cachedOrComputeFileHash(at: URL(fileURLWithPath: path))
        guard !hash.isEmpty else { return }

        learnedPersonFileHashesByName[personName, default: []].insert(hash)
        rejectedPersonFileHashesByName[personName]?.remove(hash)
    }

    private func addRejectedFileHashForPerson(path: String, personName: String) {
        let hash = cachedOrComputeFileHash(at: URL(fileURLWithPath: path))
        guard !hash.isEmpty else { return }
        rejectedPersonFileHashesByName[personName, default: []].insert(hash)
        learnedPersonFileHashesByName[personName]?.remove(hash)
    }

    private func cachedOrComputeFileHash(at url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = Int64(values?.fileSize ?? 0)
        let modifiedAt = values?.contentModificationDate
        let fingerprint = duplicateFingerprint(for: url, size: fileSize, modifiedAt: modifiedAt)

        if let cached = duplicateHashCacheByFingerprint[fingerprint] {
            return cached
        }

        let hash = fileHash(at: url)
        if !hash.isEmpty {
            duplicateHashCacheByFingerprint[fingerprint] = hash
        }
        return hash
    }

    private func moveForSimilarityGrouping(source: URL, targetDirectory: URL) throws -> URL {
        let manager = FileManager.default
        let fileName = source.lastPathComponent
        let initial = targetDirectory.appendingPathComponent(fileName)

        if !manager.fileExists(atPath: initial.path) {
            try manager.moveItem(at: source, to: initial)
            return initial
        }

        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var counter = 2

        while true {
            let candidateName = ext.isEmpty ? "\(stem)_\(counter)" : "\(stem)_\(counter).\(ext)"
            let candidate = targetDirectory.appendingPathComponent(candidateName)
            if !manager.fileExists(atPath: candidate.path) {
                try manager.moveItem(at: source, to: candidate)
                return candidate
            }
            counter += 1
        }
    }

    private func moveWithConflictHandling(source: URL, targetDirectory: URL) throws -> MoveResult {
        let manager = FileManager.default
        let fileName = source.lastPathComponent
        let initial = targetDirectory.appendingPathComponent(fileName)
        let sourceHash = fileHash(at: source)

        if let existingDuplicate = firstDuplicateMatch(in: targetDirectory, matchingHash: sourceHash, excludingPath: source.path) {
            guard shouldRemoveDuplicate(source: source, duplicateAt: existingDuplicate) else {
                throw DuplicateRemovalCancelledError()
            }
            let trashedURL = try moveToTrash(source)
            return MoveResult(
                outcome: .duplicate,
                message: "duplicate (trashed): \(source.lastPathComponent) matches \(existingDuplicate.lastPathComponent) in \(targetDirectory.lastPathComponent)",
                resultURL: trashedURL
            )
        }

        if !manager.fileExists(atPath: initial.path) {
            try manager.moveItem(at: source, to: initial)
            return MoveResult(outcome: .moved, message: "moved: \(source.lastPathComponent) to \(targetDirectory.lastPathComponent)", resultURL: initial)
        }

        if sourceHash == fileHash(at: initial) {
            guard shouldRemoveDuplicate(source: source, duplicateAt: initial) else {
                throw DuplicateRemovalCancelledError()
            }
            let trashedURL = try moveToTrash(source)
            return MoveResult(
                outcome: .duplicate,
                message: "duplicate (trashed): \(source.lastPathComponent) matches \(initial.lastPathComponent) in \(targetDirectory.lastPathComponent)",
                resultURL: trashedURL
            )
        }

        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var counter = 2

        while true {
            let candidateName = ext.isEmpty ? "\(stem)_\(counter)" : "\(stem)_\(counter).\(ext)"
            let candidate = targetDirectory.appendingPathComponent(candidateName)
            if !manager.fileExists(atPath: candidate.path) {
                try manager.moveItem(at: source, to: candidate)
                return MoveResult(outcome: .renamed, message: "renamed: \(source.lastPathComponent) in \(targetDirectory.lastPathComponent)", resultURL: candidate)
            }
            counter += 1
        }
    }

    private func firstDuplicateMatch(in directory: URL, matchingHash hash: String, excludingPath: String) -> URL? {
        guard !hash.isEmpty else { return nil }

        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsPackageDescendants]
        )) ?? []

        for candidate in entries {
            if candidate.path == excludingPath { continue }
            let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
            if values?.isHidden == true { continue }
            guard values?.isRegularFile == true else { continue }
            if fileHash(at: candidate) == hash {
                return candidate
            }
        }

        return nil
    }

    private func moveToTrash(_ url: URL) throws -> URL? {
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return resultingURL as URL?
        } catch {
            throw TrashFailedError(underlying: error)
        }
    }

    private func moveFileBackToSource(from resultURL: URL, to sourceURL: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: resultURL.path) else {
            throw NSError(domain: "FileSorterMac", code: 1101, userInfo: [NSLocalizedDescriptionKey: "Cannot undo because moved file is no longer available at destination."])
        }

        if manager.fileExists(atPath: sourceURL.path) {
            throw NSError(domain: "FileSorterMac", code: 1102, userInfo: [NSLocalizedDescriptionKey: "Cannot undo because a file already exists at the original location."])
        }

        try manager.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: resultURL, to: sourceURL)
    }

    private func restoreFromTrash(trashedURL: URL, to sourceURL: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: trashedURL.path) else {
            throw NSError(domain: "FileSorterMac", code: 1103, userInfo: [NSLocalizedDescriptionKey: "Cannot undo because the trashed duplicate is unavailable."])
        }

        if manager.fileExists(atPath: sourceURL.path) {
            throw NSError(domain: "FileSorterMac", code: 1104, userInfo: [NSLocalizedDescriptionKey: "Cannot restore duplicate because a file already exists at the original location."])
        }

        try manager.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: trashedURL, to: sourceURL)
    }

    private nonisolated static func pairKey(_ lhs: String, _ rhs: String) -> String {
        lhs < rhs ? "\(lhs)|\(rhs)" : "\(rhs)|\(lhs)"
    }

    private nonisolated static func normalizedSimilarity<T: BinaryFloatingPoint>(_ lhs: T, _ rhs: T) -> Double {
        let left = Double(lhs)
        let right = Double(rhs)
        guard left.isFinite, right.isFinite else { return 0 }

        let denominator = max(abs(left), abs(right), 1)
        let delta = abs(left - right)
        return max(0, min(1, 1 - (delta / denominator)))
    }

    private nonisolated static func normalizedSimilarity(_ lhs: Int64, _ rhs: Int64) -> Double {
        let left = Double(lhs)
        let right = Double(rhs)
        let denominator = max(abs(left), abs(right), 1)
        let delta = abs(left - right)
        return max(0, min(1, 1 - (delta / denominator)))
    }

    private nonisolated static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        Int((lhs ^ rhs).nonzeroBitCount)
    }

    private nonisolated static func imageVisualSignatureStatic(at url: URL) -> DuplicateVisualSignature? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }

        guard let hash = perceptualHash64(from: image) else { return nil }
        let faceHashes = faceHashes(from: image, maxCount: 3)
        return DuplicateVisualSignature(hash: hash, faceHashes: faceHashes, width: image.width, height: image.height)
    }

    private nonisolated static func videoVisualSignatureStatic(at url: URL) async -> DuplicateVisualSignature? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let durationTime: CMTime
        do {
            durationTime = try await asset.load(.duration)
        } catch {
            durationTime = .zero
        }
        let durationSeconds = CMTimeGetSeconds(durationTime)
        let sampleFractions: [Double] = [0.00, 0.08, 0.16, 0.26, 0.38, 0.50, 0.62, 0.74, 0.86, 0.96]
        let minimumLuma = 0.04
        let faceProbeLimit = 12

        var fallbackImage: CGImage?
        var selectedVisualImage: CGImage?
        var collectedFaceHashes: [UInt64] = []
        var faceProbeCount = 0
        let maxVideoFaceHashes = 6

        let introSkipSeconds: Double = {
            guard durationSeconds.isFinite, durationSeconds > 0 else { return 0 }
            if durationSeconds >= 120 {
                return min(25, durationSeconds * 0.22)
            }
            if durationSeconds >= 45 {
                return min(12, durationSeconds * 0.16)
            }
            return min(2.5, durationSeconds * 0.10)
        }()
        let effectiveDuration = max(0, durationSeconds - introSkipSeconds)

        for fraction in sampleFractions {
            let sampleSeconds: Double
            if durationSeconds.isFinite, durationSeconds > 0 {
                if effectiveDuration > 0 {
                    sampleSeconds = min(durationSeconds, introSkipSeconds + (effectiveDuration * fraction))
                } else {
                    sampleSeconds = max(0, min(durationSeconds, durationSeconds * fraction))
                }
            } else {
                sampleSeconds = 0
            }

            let time = CMTime(seconds: sampleSeconds, preferredTimescale: 600)

            guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else {
                continue
            }

            if fallbackImage == nil {
                fallbackImage = image
            }

            let luma = averageLuma(from: image)
            if selectedVisualImage == nil,
               luma > minimumLuma {
                selectedVisualImage = image
            }

            if faceProbeCount < faceProbeLimit,
               luma > minimumLuma {
                faceProbeCount += 1
                let detected = faceHashes(from: image, maxCount: 2)
                addUniqueFaceHashes(from: detected, into: &collectedFaceHashes, maxCount: maxVideoFaceHashes)
            }

            if selectedVisualImage != nil,
               !collectedFaceHashes.isEmpty {
                break
            }
        }

        let visualImage = selectedVisualImage ?? fallbackImage

        if let visualImage,
           let hash = perceptualHash64(from: visualImage) {
            if collectedFaceHashes.isEmpty,
               faceProbeCount < faceProbeLimit {
                let detected = faceHashes(from: visualImage, maxCount: 3)
                addUniqueFaceHashes(from: detected, into: &collectedFaceHashes, maxCount: maxVideoFaceHashes)
            }

            return DuplicateVisualSignature(hash: hash, faceHashes: collectedFaceHashes, width: visualImage.width, height: visualImage.height)
        }

        return nil
    }

    private nonisolated static func averageLuma(from image: CGImage) -> Double {
        let width = 24
        let height = 24
        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return 0
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let sum = pixels.reduce(0) { $0 + Int($1) }
        let maxSum = width * height * 255
        return Double(sum) / Double(maxSum)
    }

    private nonisolated static func faceHashes(from image: CGImage, maxCount: Int) -> [UInt64] {
        guard maxCount > 0 else { return [] }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let faces = request.results,
              !faces.isEmpty
        else {
            return []
        }

        let sortedFaces = faces.sorted { lhs, rhs in
            (lhs.boundingBox.width * lhs.boundingBox.height) > (rhs.boundingBox.width * rhs.boundingBox.height)
        }

        var hashes: [UInt64] = []
        hashes.reserveCapacity(min(maxCount, sortedFaces.count))

        for face in sortedFaces.prefix(maxCount) {
            let rect = VNImageRectForNormalizedRect(face.boundingBox, image.width, image.height)
            let clamped = CGRect(
                x: max(0, rect.origin.x),
                y: max(0, rect.origin.y),
                width: max(1, min(CGFloat(image.width) - max(0, rect.origin.x), rect.width)),
                height: max(1, min(CGFloat(image.height) - max(0, rect.origin.y), rect.height))
            ).integral

            guard let cropped = image.cropping(to: clamped),
                  let hash = perceptualHash64(from: cropped)
            else {
                continue
            }

            if !hashes.contains(hash) {
                hashes.append(hash)
            }
        }

        return hashes
    }

    private nonisolated static func addUniqueFaceHashes(from candidates: [UInt64], into target: inout [UInt64], maxCount: Int) {
        guard maxCount > 0 else { return }
        guard !candidates.isEmpty else { return }

        for hash in candidates {
            if target.count >= maxCount { break }

            let isNearExisting = target.contains { existing in
                hammingDistance(existing, hash) <= 2
            }
            if !isNearExisting {
                target.append(hash)
            }
        }
    }

    private nonisolated static func facePairKey(_ lhs: UInt64, _ rhs: UInt64) -> String {
        if lhs < rhs {
            return "\(lhs):\(rhs)"
        }
        return "\(rhs):\(lhs)"
    }

    private nonisolated static func bestFaceSimilarityWithPairKey(lhs: [UInt64], rhs: [UInt64]) -> (score: Double, pairKey: String)? {
        guard !lhs.isEmpty, !rhs.isEmpty else { return nil }

        var bestScore = 0.0
        var bestKey = ""
        var hasBest = false
        for lHash in lhs {
            for rHash in rhs {
                let distance = hammingDistance(lHash, rHash)
                let score = max(0, 1 - (Double(distance) / 64.0))
                if !hasBest || score > bestScore {
                    bestScore = score
                    bestKey = facePairKey(lHash, rHash)
                    hasBest = true
                    if bestScore >= 0.98 {
                        return (bestScore, bestKey)
                    }
                }
            }
        }

        guard hasBest else { return nil }
        return (bestScore, bestKey)
    }

    private nonisolated static func bestFaceSimilarity(lhs: [UInt64], rhs: [UInt64]) -> Double? {
        bestFaceSimilarityWithPairKey(lhs: lhs, rhs: rhs)?.score
    }

    private nonisolated static func perceptualHash64(from image: CGImage) -> UInt64? {
        let width = 9
        let height = 8
        let bitsPerComponent = 8
        let bytesPerRow = width

        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hash: UInt64 = 0
        var bitIndex = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                let left = pixels[(y * width) + x]
                let right = pixels[(y * width) + x + 1]
                if left > right {
                    hash |= (1 << bitIndex)
                }
                bitIndex += 1
            }
        }

        return hash
    }

    private nonisolated static func fileHashStatic(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func fileHash(at url: URL) -> String {
        Self.fileHashStatic(at: url)
    }

    private func shouldRemoveDuplicate(source: URL, duplicateAt existing: URL) -> Bool {
        if removeDuplicatesAutomatically {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move duplicate file to Trash?"
        alert.informativeText = "An identical file already exists at destination:\n\n\(existing.lastPathComponent)\n\nMove the current source copy to Trash so it can be recovered later?"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep Source File")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
