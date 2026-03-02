import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showClearRecentSourcesAlert = false
    @State private var showClearRecentDestinationsAlert = false
    @State private var browserChoices: [String] = []

    var body: some View {
        Form {
            Section("Session") {
                Toggle("Default recursive mode", isOn: Binding(
                    get: { model.recursive },
                    set: { model.setRecursive($0) }
                ))

                Toggle("Default: remove duplicates automatically", isOn: Binding(
                    get: { model.defaultRemoveDuplicatesAutomatically },
                    set: { model.setDefaultRemoveDuplicatesAutomatically($0) }
                ))

                Stepper(value: Binding(
                    get: { model.seekSeconds },
                    set: { model.setSeekSeconds($0) }
                ), in: 1...120, step: 1) {
                    Text("Seek step: \(Int(model.seekSeconds)) seconds")
                }
            }

            Section("Browser Context") {
                Picker("Browser", selection: Binding(
                    get: { model.browserApp },
                    set: { model.setBrowserApp($0) }
                )) {
                    Text("System Default").tag("")
                    ForEach(browserChoices, id: \.self) { appName in
                        Text(appName).tag(appName)
                    }
                }

                if model.browserApp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Resolved app: System Default")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let resolvedPath = model.resolvedBrowserAppPath {
                    Text("Resolved app: \(resolvedPath)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Resolved app: Not found")
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }

                Button("Refresh Browser List") {
                    reloadBrowserChoices()
                }

                Toggle("Private mode", isOn: Binding(
                    get: { model.browserPrivate },
                    set: { model.setBrowserPrivate($0) }
                ))
            }

            Section("Recent Sources") {
                if model.recentSourceDirectories.isEmpty {
                    Text("No recent sources")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.recentSourceDirectories, id: \.self) { path in
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Clear Recent Sources") {
                        showClearRecentSourcesAlert = true
                    }
                }
            }

            Section("Recent Destinations") {
                if model.recentDestinationDirectories.isEmpty {
                    Text("No recent destinations")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.recentDestinationDirectories, id: \.self) { path in
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Clear Recent Destinations") {
                        showClearRecentDestinationsAlert = true
                    }
                }
            }

        }
        .formStyle(.grouped)
        .font(.body)
        .padding(16)
        .frame(width: 560)
        .onAppear {
            reloadBrowserChoices()
        }
        .alert("Clear Recent Sources?", isPresented: $showClearRecentSourcesAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                model.clearRecentSources()
            }
        } message: {
            Text("This removes all recent source folder entries from menus.")
        }
        .alert("Clear Recent Destinations?", isPresented: $showClearRecentDestinationsAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                model.clearRecentDestinations()
            }
        } message: {
            Text("This removes all recent destination folder entries from menus.")
        }
    }

    private func reloadBrowserChoices() {
        browserChoices = model.availableBrowserApps()
    }
}
