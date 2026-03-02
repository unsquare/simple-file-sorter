import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

@main
struct FileSorterMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var playback = PlaybackCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(playback)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1500, height: 930)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(playback)
        }

        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { model.chooseFolderInteractive() }
                    .keyboardShortcut("o", modifiers: [.command])
            }

            CommandMenu("Recent Sources") {
                if model.recentSourceDirectories.isEmpty {
                    Text("No Recent Sources")
                } else {
                    ForEach(model.recentSourceDirectories, id: \.self) { path in
                        Button(path) { model.openRecentSource(path: path) }
                    }
                    Divider()
                    Button("Clear Sources") { model.clearRecentSources() }
                }
            }

            CommandMenu("Recent Destinations") {
                if model.recentDestinationDirectories.isEmpty {
                    Text("No Recent Destinations")
                } else {
                    ForEach(model.recentDestinationDirectories, id: \.self) { path in
                        Button(path) { model.openRecentDestination(path: path) }
                    }
                    Divider()
                    Button("Clear Destinations") { model.clearRecentDestinations() }
                }
            }

            CommandMenu("File Actions") {
                Button("Close Folder") { model.closeCurrentSession() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.currentDirectory == nil)
                Button("Reveal in Finder") { model.revealCurrentInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.hasActivePreviewFile)
            }

            CommandMenu("Session") {
                Button(model.recursive ? "Use Top-Level Mode" : "Use Recursive Mode") { model.toggleRecursiveMode() }
                    .keyboardShortcut("m", modifiers: [.command])
                Button("Open Context") { model.openBrowserContext() }
                    .keyboardShortcut("g", modifiers: [.command])
                    .disabled(!model.hasActivePreviewFile)
                Divider()
                Button("Next") { model.skipCurrent() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Undo") { model.goBack() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                    .disabled(!model.canUndo)
                Button("Move") {
                    let typed = model.folderQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let selected = model.selectedFolder,
                       !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        model.moveCurrent(targetFolderRaw: selected)
                    } else {
                        model.moveCurrent(targetFolderRaw: typed.isEmpty ? nil : typed)
                    }
                }
                    .keyboardShortcut(.return, modifiers: [])

                Button(playback.isPlaying ? "Pause" : "Play") {
                    switch playback.togglePlayPause() {
                    case .playing:
                        model.statusMessage = "Playing media."
                    case .paused:
                        model.statusMessage = "Paused media."
                    case .unavailable:
                        break
                    }
                }
                    .keyboardShortcut(" ", modifiers: [])
                    .disabled(playback.player == nil)
                Divider()
                Button("Seek Back") { playback.seek(by: -model.seekSeconds) }
                    .keyboardShortcut(.leftArrow, modifiers: [.option])
                Button("Seek Forward") { playback.seek(by: model.seekSeconds) }
                    .keyboardShortcut(.rightArrow, modifiers: [.option])
            }
        }
    }
}
