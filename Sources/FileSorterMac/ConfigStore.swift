import Foundation

final class ConfigStore {
    private static let appSupportFolder = "File Sorter Swift"

    let configURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent(Self.appSupportFolder, isDirectory: true)
        self.configURL = dir.appendingPathComponent("config.json", isDirectory: false)
    }

    func load() -> AppSettings {
        do {
            let data = try Data(contentsOf: configURL)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            return decoded
        } catch {
            return AppSettings()
        }
    }

    func save(_ settings: AppSettings) {
        do {
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.pretty.encode(settings)
            try data.write(to: configURL, options: .atomic)
        } catch {
            NSLog("Failed to save config: \(error.localizedDescription)")
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
