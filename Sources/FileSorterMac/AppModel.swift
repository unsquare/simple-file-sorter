import CryptoKit
import Foundation
import AppKit
import AVFoundation

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
    }

    private enum UndoActionKind {
        case skipped
        case moved(resultURL: URL)
        case duplicated(trashedURL: URL?)
    }

    private struct UndoAction {
        let sourceOriginalURL: URL
        let kind: UndoActionKind
        let previousSelection: String?
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
    private let usernameRegex = try? NSRegularExpression(pattern: "@([A-Za-z0-9]+)[_']")
    private var lastSeekByPath: [String: Double] = [:]
    private let videoExt: Set<String> = ["mp4", "mov", "avi", "mkv", "m4v", "webm", "flv"]
    private let audioExt: Set<String> = ["mp3", "wav", "aac", "flac", "m4a", "ogg", "opus"]
    private var rebuildTask: Task<Void, Never>?
    private var rebuildGeneration: Int = 0
    private var sessionOutcomeByPath: [String: SessionFileOutcome] = [:]
    private var sourceURLsByFilePath: [String: [URL]] = [:]
    private var statusToastTask: Task<Void, Never>?
    private var undoHistory: [UndoAction] = []

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
        self.removeDuplicatesAutomatically = self.settings.removeDuplicatesAutomatically
    }

    deinit {
        rebuildTask?.cancel()
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
        if let directory = currentDirectory {
            rebuildSession(directory: directory, recursive: value, preferredCurrent: current)
        }
    }

    func setSeekSeconds(_ value: Double) {
        let clamped = max(1, min(120, value.rounded()))
        mutateSettings { $0.seekSeconds = clamped }
    }

    func setRemoveDuplicatesAutomatically(_ value: Bool) {
        removeDuplicatesAutomatically = value
    }

    func setDefaultRemoveDuplicatesAutomatically(_ value: Bool) {
        mutateSettings { $0.removeDuplicatesAutomatically = value }
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
        mutateSettings { $0.browserApp = value.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func setBrowserPrivate(_ value: Bool) {
        mutateSettings { $0.browserPrivate = value }
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
        currentDirectory = resolved
        folderQuery = ""
        statusMessage = "Loading folder…"
        closedSessionSummary = nil
        resetSessionSummary()
        sourceURLsByFilePath = [:]
        lastMovedFolderContext = nil
        undoHistory = []

        mutateSettings {
            $0.recursive = recursive
            $0.pushRecentSourceDirectory(resolved)
        }

        rebuildSession(directory: resolved, recursive: recursive, preferredCurrent: nil)
    }

    func closeCurrentSession() {
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
        currentSuggestedFolder = nil
        lastMovedFolderContext = nil
        closedSessionSummary = shouldShowEarlyCloseSummary ? summarySnapshot : nil
        resetSessionSummary()
        sourceURLsByFilePath = [:]
        undoHistory = []
        statusMessage = "Closed folder."
    }

    func restartCurrentSession() {
        guard let currentDirectory else { return }
        folderQuery = ""
        selectedFolder = nil
        statusMessage = "Restarting folder…"
        closedSessionSummary = nil
        lastMovedFolderContext = nil
        resetSessionSummary()
        undoHistory = []
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
    }

    func clearRecentDestinations() {
        mutateSettings { $0.recentDestinationDirectories = [] }
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
            switch action.kind {
            case .skipped:
                index = max(0, index - 1)
                removeSessionOutcome(for: action.sourceOriginalURL.path)
                selectedFolder = action.previousSelection
                updateCurrentFilePresentation()
                statusMessage = "Undid skip."

            case .moved(let resultURL):
                try moveFileBackToSource(from: resultURL, to: action.sourceOriginalURL)
                index = max(0, index - 1)
                removeSessionOutcome(for: action.sourceOriginalURL.path)
                selectedFolder = action.previousSelection
                updateCurrentFilePresentation()
                statusMessage = "Undid move for \(action.sourceOriginalURL.lastPathComponent)."

            case .duplicated(let trashedURL):
                guard let trashedURL else {
                    statusMessage = "Unable to undo duplicate removal."
                    return
                }
                try restoreFromTrash(trashedURL: trashedURL, to: action.sourceOriginalURL)
                index = max(0, index - 1)
                removeSessionOutcome(for: action.sourceOriginalURL.path)
                selectedFolder = action.previousSelection
                updateCurrentFilePresentation()
                statusMessage = "Restored duplicate for \(action.sourceOriginalURL.lastPathComponent)."
            }
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
            return [suggested] + folders.filter { $0 != suggested }
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

        if let suggested, ranked.contains(suggested) {
            return [suggested] + ranked.filter { $0 != suggested }
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
        currentSuggestedFolder = nil

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

            if loadedFiles.isEmpty {
                self.statusMessage = "No files found in selected folder."
            } else if self.statusMessage == "Loading folder…" {
                self.statusMessage = ""
            }
        }
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
            selectedFolder = nil
            return
        }

        let previousSelection = selectedFolder
        folders = Self.collectFolders(in: destinationDirectory)
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

        if normalized.contains("moved") || normalized.contains("opened") || normalized.contains("revealed") || normalized.contains("loaded") || normalized.contains("complete") || normalized.contains("renamed") {
            return .success
        }

        return .info
    }

    private func toastSummary(for message: String) -> String? {
        let normalized = message.lowercased()

        if normalized.contains("duplicate") {
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
        if let suggestion = suggestedFolderMatch(for: file) {
            currentFolderSuggestionHint = suggestion.hint
            currentSuggestedFolder = suggestion.folder
        } else {
            currentFolderSuggestionHint = ""
            currentSuggestedFolder = nil
        }

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
            if let suggestion = self.suggestedFolderMatch(for: file) {
                self.currentFolderSuggestionHint = suggestion.hint
                self.currentSuggestedFolder = suggestion.folder
            } else {
                self.currentFolderSuggestionHint = ""
                self.currentSuggestedFolder = nil
            }
        }
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
        let fileName = file.lastPathComponent

        if let username = extractUsername(from: fileName),
           let match = folders.first(where: { $0.caseInsensitiveCompare(username) == .orderedSame }) {
            return FolderSuggestion(folder: match, hint: "Suggested from filename username: @\(username)")
        }

        if let match = metadataSuggestedFolder(for: file) {
            return match
        }

        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.lowercased()
        if let match = folders.first(where: { stem.contains($0.lowercased()) }) {
            return FolderSuggestion(folder: match, hint: "Suggested from filename text")
        }

        return nil
    }

    private func metadataSuggestedFolder(for file: URL) -> FolderSuggestion? {
        let sourceURLs = sourceURLsByFilePath[file.path] ?? {
            let urls = Self.metadataWhereFromURLs(for: file)
            sourceURLsByFilePath[file.path] = urls
            return urls
        }()

        for sourceURL in sourceURLs {
            if let match = metadataFolderMatch(from: sourceURL) {
                return match
            }
        }

        return nil
    }

    private func metadataFolderMatch(from sourceURL: URL) -> FolderSuggestion? {
        if let twitterLikeCandidate = socialUsernameCandidate(from: sourceURL),
           let match = folderMatch(forCandidate: twitterLikeCandidate) {
            return FolderSuggestion(folder: match, hint: "Suggested from metadata: @\(twitterLikeCandidate)")
        }

        if let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) {
            let usernameKeys = Set(["screen_name", "username", "user", "author", "creator"])
            for item in components.queryItems ?? [] {
                guard usernameKeys.contains(item.name.lowercased()) else { continue }
                if let value = item.value,
                   let match = folderMatch(forCandidate: value) {
                    return FolderSuggestion(folder: match, hint: "Suggested from metadata: @\(value)")
                }
            }
        }

        let raw = sourceURL.absoluteString
        if let regex = try? NSRegularExpression(pattern: "@([A-Za-z0-9_]{2,32})") {
            let range = NSRange(location: 0, length: raw.utf16.count)
            for hit in regex.matches(in: raw, range: range) {
                guard hit.numberOfRanges > 1,
                      let matchRange = Range(hit.range(at: 1), in: raw)
                else { continue }
                let candidate = String(raw[matchRange])
                if let match = folderMatch(forCandidate: candidate) {
                    return FolderSuggestion(folder: match, hint: "Suggested from metadata: @\(candidate)")
                }
            }
        }

        return nil
    }

    private func socialUsernameCandidate(from sourceURL: URL) -> String? {
        guard let host = sourceURL.host?.lowercased() else { return nil }
        let supportedHosts = Set(["twitter.com", "www.twitter.com", "x.com", "www.x.com"])
        guard supportedHosts.contains(host) else { return nil }

        let parts = sourceURL.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard let first = parts.first else { return nil }
        let lower = first.lowercased()
        let blocked = Set(["i", "intent", "home", "explore", "search", "share", "hashtag", "messages", "settings"])
        guard !blocked.contains(lower) else { return nil }

        let isValidUsername = first.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        guard isValidUsername else { return nil }
        return first
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

    private func fileHash(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
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
