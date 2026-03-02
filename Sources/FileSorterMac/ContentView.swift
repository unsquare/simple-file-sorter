import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlaybackCoordinator

    @State private var keyMonitor: Any?
    @State private var pendingCreateFolder: String?
    @State private var folderListResetToken = UUID()
    @FocusState private var destinationFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            HSplitView {
                PreviewPane(fileURL: model.currentFile)
                    .environmentObject(model)
                    .environmentObject(playback)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Button {
                                model.chooseFolderInteractive()
                            } label: {
                                Label("Open Folder", systemImage: "folder")
                            }
                            .help("Choose a folder to sort")

                            Menu {
                                if model.recentSourceDirectories.isEmpty {
                                    Text("No Recent Sources")
                                } else {
                                    ForEach(model.recentSourceDirectories, id: \.self) { path in
                                        Button {
                                            model.openRecentSource(path: path)
                                        } label: {
                                            if path == model.currentDirectory?.path {
                                                Label(path, systemImage: "checkmark")
                                            } else {
                                                Text(path)
                                            }
                                        }
                                        .disabled(path == model.currentDirectory?.path)
                                    }
                                }
                            } label: {
                                Label("Recent Sources", systemImage: "clock.arrow.circlepath")
                            }
                            .help("Reopen a recently used source folder")

                            Menu {
                                if model.recentDestinationDirectories.isEmpty {
                                    Text("No Recent Destinations")
                                } else {
                                    ForEach(model.recentDestinationDirectories, id: \.self) { path in
                                        Button {
                                            model.openRecentDestination(path: path)
                                        } label: {
                                            if path == model.destinationDirectoryOverride?.path {
                                                Label(path, systemImage: "checkmark")
                                            } else {
                                                Text(path)
                                            }
                                        }
                                        .disabled(path == model.destinationDirectoryOverride?.path)
                                    }
                                }
                            } label: {
                                Label("Recent Destinations", systemImage: "tray.full")
                            }
                            .help("Reuse a recently used destination folder")

                            Spacer(minLength: 0)
                        }

                        HStack(spacing: 8) {
                            Button("Set Destination…") {
                                model.chooseDestinationInteractive()
                            }
                            .help("Choose a destination folder different from the source")

                            Button("Use Source") {
                                model.clearDestinationOverride()
                            }
                            .disabled(!model.hasDestinationOverride)
                            .help("Reset destination to the current source folder")

                            Text(model.hasDestinationOverride ? "Destination: \(model.destinationSummary)" : "Destination: Source folder")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Divider()

                        Text(model.progressLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            if let icon = model.currentFileIcon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "doc")
                                    .frame(width: 18, height: 18)
                                    .foregroundStyle(.secondary)
                            }

                            Text(model.currentFile?.lastPathComponent ?? "No active file")
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }

                        if !model.currentFileMetadataLine.isEmpty {
                            Text(model.currentFileMetadataLine)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sources")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            if model.isLoadingCurrentFileSources {
                                VStack(alignment: .leading, spacing: 8) {
                                    sourceSkeletonRow(width: 210)
                                    sourceSkeletonRow(width: 170)
                                }
                                .accessibilityLabel("Loading source links")
                            } else if !model.currentFileSourceURLs.isEmpty {
                                ForEach(model.currentFileSourceURLs, id: \.self) { source in
                                    Button {
                                        model.openExternalURL(source)
                                    } label: {
                                        Label(sourceLabel(for: source), systemImage: "arrow.up.right.square")
                                            .font(.callout)
                                            .underline()
                                            .foregroundStyle(.blue)
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open source link in your browser")
                                }
                            } else {
                                Text("No source links available")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(height: 78, alignment: .topLeading)

                        HStack(spacing: 12) {
                            Toggle("Recursive", isOn: Binding(
                                get: { model.recursive },
                                set: { model.setRecursive($0) }
                            ))
                            .toggleStyle(.switch)

                            Toggle("Remove Duplicates", isOn: Binding(
                                get: { model.removeDuplicatesAutomatically },
                                set: { model.setRemoveDuplicatesAutomatically($0) }
                            ))
                            .toggleStyle(.switch)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Destination folder (type to filter or create)", text: $model.folderQuery)
                                .textFieldStyle(.roundedBorder)
                                .focused($destinationFieldFocused)
                                .onSubmit {
                                    performMoveAction()
                                }

                            VStack(alignment: .leading, spacing: 4) {
                                if !model.currentFolderSuggestionHint.isEmpty,
                                   let suggestedFolder = model.currentSuggestedFolder {
                                    Button {
                                        model.folderQuery = suggestedFolder
                                        model.selectedFolder = suggestedFolder
                                        pendingCreateFolder = nil
                                    } label: {
                                        Label(model.currentFolderSuggestionHint, systemImage: "sparkles")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Apply suggested folder: \(suggestedFolder)")
                                }

                                if let pendingCreateFolder {
                                    Text("Creating: \"\(pendingCreateFolder)\" (Enter to move)")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                } else if let newFolderName = newFolderCandidate() {
                                    Text("Press Tab to queue creating \"\(newFolderName)\"")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(minHeight: 44, alignment: .topLeading)
                        }

                        List {
                            if let newFolderName = newFolderCandidate() {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus.circle")
                                        .frame(width: 16, height: 16)
                                        .foregroundStyle(.tint)
                                    Text("Create \"\(newFolderName)\"")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    DispatchQueue.main.async {
                                        model.folderQuery = newFolderName
                                        pendingCreateFolder = newFolderName
                                        model.selectedFolder = newFolderName
                                    }
                                }
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowSeparator(.hidden)
                            }

                            if let pinned = pinnedFolder,
                               displayedFolders.contains(where: { $0.caseInsensitiveCompare(pinned) == .orderedSame }) {
                                folderRow(for: pinned)

                                if !remainingFolders.isEmpty {
                                    Divider()
                                        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                                        .listRowSeparator(.hidden)
                                }
                            }

                            ForEach(remainingFolders, id: \.self) { folder in
                                folderRow(for: folder)
                            }
                        }
                        .id(folderListResetToken)
                        .listStyle(.plain)
                        .padding(.top, 2)
                        .frame(minHeight: 260)

                        HStack {
                            Button {
                                performMoveAction()
                            } label: {
                                Label("Move", systemImage: "folder.badge.plus")
                            }
                            .keyboardShortcut(.defaultAction)

                            Button {
                                model.skipCurrent()
                            } label: {
                                Label("Next", systemImage: "arrow.right")
                            }

                            Button {
                                model.goBack()
                            } label: {
                                Label("Undo", systemImage: "arrow.uturn.backward")
                            }
                            .disabled(!model.canUndo)
                        }

                        Divider()

                        statusPanel
                    }
                    .padding(14)
                    .frame(minWidth: 420, idealWidth: 460, maxWidth: 520)
                }
            }

        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.closeCurrentSession()
                } label: {
                    Label("Close Folder", systemImage: "xmark.circle")
                }
                .disabled(model.currentDirectory == nil)
                .help("Close current folder and clear preview")

                Button {
                    model.chooseFolderInteractive()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .help("Choose a folder to sort")

                Button {
                    model.revealCurrentInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder.fill.badge.person.crop")
                }
                .disabled(!model.hasActivePreviewFile)
                .help("Reveal current file in Finder")

                Button {
                    model.openBrowserContext()
                } label: {
                    Label("Open Context", systemImage: "globe")
                }
                .disabled(!model.hasActivePreviewFile)
                .help("Open intelligent web search for current file")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.goBack()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)

                Button {
                    model.skipCurrent()
                } label: {
                    Label("Next", systemImage: "arrow.right")
                }

                Button {
                    applyPlaybackToggleStatus()
                } label: {
                    Label(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(playback.player == nil)

                Button {
                    performMoveAction()
                } label: {
                    Label("Move", systemImage: "folder.badge.plus")
                }
            }
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            installKeyMonitorIfNeeded()
        }
        .onChange(of: model.folderQuery) { _, _ in
            syncSelectionFromTypedQuery()
        }
        .onChange(of: model.currentFile?.path ?? "") { _, _ in
            folderListResetToken = UUID()
        }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 48 {
                let modifiers = normalizedModifiers(for: event)
                if modifiers.isEmpty,
                   destinationFieldFocused,
                   let create = newFolderCandidate() {
                    pendingCreateFolder = create
                    model.selectedFolder = create
                    model.statusMessage = "Create queued: \(create)"
                    return nil
                }
            }

            if event.keyCode == 125 || event.keyCode == 126 {
                let modifiers = normalizedModifiers(for: event)
                if modifiers.isEmpty {
                    if moveFolderSelection(direction: event.keyCode == 125 ? 1 : -1) {
                        return nil
                    }
                    return event
                }

                if modifiers == .command {
                    if moveFolderSelectionToBoundary(atStart: event.keyCode == 126) {
                        return nil
                    }
                    return event
                }
            }

            if event.keyCode == 115 || event.keyCode == 119 {
                let modifiers = normalizedModifiers(for: event)
                if modifiers.isEmpty {
                    if moveFolderSelectionToBoundary(atStart: event.keyCode == 115) {
                        return nil
                    }
                    return event
                }
            }

            if event.keyCode == 116 || event.keyCode == 121 {
                let modifiers = normalizedModifiers(for: event)
                if modifiers.isEmpty {
                    if moveFolderSelectionByPage(direction: event.keyCode == 121 ? 1 : -1) {
                        return nil
                    }
                    return event
                }
            }

            if event.keyCode != 49 { return event }

            let modifiers = normalizedModifiers(for: event)
            if !modifiers.isEmpty { return event }

            if let firstResponder = NSApp.keyWindow?.firstResponder,
               firstResponder is NSTextView {
                return event
            }

            applyPlaybackToggleStatus()
            return nil
        }
    }

    private func syncSelectionFromTypedQuery() {
        let typed = model.folderQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        if let pendingCreateFolder,
           pendingCreateFolder.caseInsensitiveCompare(typed) != .orderedSame {
            self.pendingCreateFolder = nil
        }

        if typed.isEmpty {
            return
        }

        if pendingCreateFolder != nil {
            model.selectedFolder = typed
            return
        }

        model.selectedFolder = model.rankedFolders().first
    }

    private func performMoveAction() {
        guard let target = preferredMoveTarget() else { return }
        let previousPath = model.currentFile?.path
        model.moveCurrent(targetFolderRaw: target)

        if model.currentFile?.path != previousPath {
            model.folderQuery = ""
        }

        if pendingCreateFolder?.caseInsensitiveCompare(target) == .orderedSame {
            pendingCreateFolder = nil
        }
    }

    private func applyPlaybackToggleStatus() {
        switch playback.togglePlayPause() {
        case .playing:
            model.statusMessage = "Playing media."
        case .paused:
            model.statusMessage = "Paused media."
        case .unavailable:
            break
        }
    }

    private func folderIcon(for folder: String) -> NSImage? {
        guard let directory = model.currentDirectory else { return nil }
        let folderURL = directory.appendingPathComponent(folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folderURL.path) else { return nil }
        return NSWorkspace.shared.icon(forFile: folderURL.path)
    }

    private func sourceLabel(for url: URL) -> String {
        if let host = url.host, !host.isEmpty {
            return host + url.path
        }
        return url.absoluteString
    }

    private func sourceSkeletonRow(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.secondary.opacity(0.16))
            .frame(width: width, height: 12)
    }

    private func preferredMoveTarget() -> String? {
        if let pendingCreateFolder,
           !pendingCreateFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return pendingCreateFolder
        }

        if let selected = model.selectedFolder,
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return selected
        }

        let typed = model.folderQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }

        if let best = model.rankedFolders().first {
            return best
        }

        return typed
    }

    private func newFolderCandidate() -> String? {
        let typed = model.folderQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }

        let exists = model.folders.contains { existing in
            existing.caseInsensitiveCompare(typed) == .orderedSame
        }
        return exists ? nil : typed
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private var displayedFolders: [String] {
        model.rankedFolders()
    }

    private var pinnedFolder: String? {
        if let contextual = model.contextualPinnedFolder,
           let match = displayedFolders.first(where: { $0.caseInsensitiveCompare(contextual) == .orderedSame }) {
            return match
        }

        return nil
    }

    private var remainingFolders: [String] {
        let remaining: [String]
        if let pinned = pinnedFolder {
            remaining = displayedFolders.filter { $0.caseInsensitiveCompare(pinned) != .orderedSame }
        } else {
            remaining = displayedFolders
        }

        return remaining.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func folderRow(for folder: String) -> some View {
        HStack(spacing: 8) {
            if let icon = folderIcon(for: folder) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "folder")
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
            }

            Text(folder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(folder == model.selectedFolder ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
        )
        .foregroundStyle(folder == model.selectedFolder ? Color(nsColor: .selectedTextColor) : Color.primary)
        .contentShape(Rectangle())
        .onTapGesture {
            DispatchQueue.main.async {
                model.selectedFolder = folder
                pendingCreateFolder = nil
            }
        }
        .onTapGesture(count: 2) {
            DispatchQueue.main.async {
                model.selectedFolder = folder
                pendingCreateFolder = nil
                performMoveAction()
            }
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
        .listRowSeparator(.hidden)
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(.secondary)
                Text("Recent Activity")
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
            }

            if !model.activityLog.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.activityLog.suffix(8).reversed())) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(model.activityTimestamp(for: entry.timestamp))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 76, alignment: .leading)
                                Image(systemName: severityIcon(for: entry.severity))
                                    .foregroundStyle(severityColor(for: entry.severity))
                                Text(entry.message)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 84, maxHeight: 120)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
    }

    private func severityIcon(for severity: AppModel.ActivitySeverity) -> String {
        switch severity {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    private func severityColor(for severity: AppModel.ActivitySeverity) -> Color {
        switch severity {
        case .info:
            return .accentColor
        case .success:
            return Color(nsColor: .systemGreen)
        case .warning:
            return Color(nsColor: .systemOrange)
        case .error:
            return Color(nsColor: .systemRed)
        }
    }

    private func moveFolderSelection(direction: Int) -> Bool {
        let ranked = model.rankedFolders()
        guard !ranked.isEmpty else { return false }

        if let selected = model.selectedFolder,
           let currentIndex = ranked.firstIndex(where: { $0.caseInsensitiveCompare(selected) == .orderedSame }) {
            let nextIndex = max(0, min(ranked.count - 1, currentIndex + direction))
            model.selectedFolder = ranked[nextIndex]
        } else {
            model.selectedFolder = direction >= 0 ? ranked.first : ranked.last
        }

        pendingCreateFolder = nil
        return true
    }

    private func moveFolderSelectionToBoundary(atStart: Bool) -> Bool {
        let ranked = model.rankedFolders()
        guard !ranked.isEmpty else { return false }
        model.selectedFolder = atStart ? ranked.first : ranked.last
        pendingCreateFolder = nil
        return true
    }

    private func moveFolderSelectionByPage(direction: Int) -> Bool {
        let ranked = model.rankedFolders()
        guard !ranked.isEmpty else { return false }

        let pageStep = 8
        let currentIndex: Int

        if let selected = model.selectedFolder,
           let found = ranked.firstIndex(where: { $0.caseInsensitiveCompare(selected) == .orderedSame }) {
            currentIndex = found
        } else {
            currentIndex = direction >= 0 ? 0 : ranked.count - 1
        }

        let nextIndex = max(0, min(ranked.count - 1, currentIndex + (pageStep * direction)))
        model.selectedFolder = ranked[nextIndex]
        pendingCreateFolder = nil
        return true
    }

    private func normalizedModifiers(for event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
    }
}
