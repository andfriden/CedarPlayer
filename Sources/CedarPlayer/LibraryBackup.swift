import Foundation
import AppKit
import UniformTypeIdentifiers

struct LibraryBackup: Codable {
    static let currentVersion = 1

    var version = currentVersion
    var createdAt = Date()
    var tracks: [Track]
    var playlists: [Playlist]
    var smartCollections: [SmartCollection]
    var stations: [RadioStation]
    var watchFolders: [String]
    var settings: Data?
}

extension Library {
    private static let backedUpSettings = [
        "appearanceMode", "accentChoice", "appLanguage", "showFormatColumn",
        "resumeLastTrack", "checkForUpdates", "autoCoverSearch", "keepMiniOnTop",
        "meterStyle", "crossfadeSeconds", "transitionFadeSeconds",
        "replayGainEnabled", "outputDeviceUID", "sortKey", "playlistSortAscending"
    ]

    func presentBackupExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "zip") ?? .archive]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "CedarPlayer-Backup-\(formatter.string(from: Date())).zip"
        panel.message = L10n.string("Сохранить библиотеку, плейлисты, настройки и обложки")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.exportBackup(from: self, to: url)
            statusMessage = L10n.format("Резервная копия: %@", url.lastPathComponent)
        } catch {
            statusMessage = L10n.format("Ошибка резервной копии: %@", error.localizedDescription)
        }
    }

    func presentBackupRestorePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "zip") ?? .archive]
        panel.allowsMultipleSelection = false
        panel.message = L10n.string("Выберите резервную копию Cedar Player")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = L10n.string("Заменить текущую библиотеку?")
        alert.informativeText = L10n.string("Треки, плейлисты и настройки будут заменены данными из копии.")
        alert.addButton(withTitle: L10n.string("Восстановить"))
        alert.addButton(withTitle: L10n.string("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try Self.restoreBackup(into: self, from: url)
            statusMessage = L10n.string("Библиотека восстановлена")
        } catch {
            statusMessage = L10n.format("Ошибка восстановления: %@", error.localizedDescription)
        }
    }

    private static func exportBackup(from library: Library, to url: URL) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CedarBackup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let backup = LibraryBackup(tracks: library.tracks,
                                   playlists: library.playlists,
                                   smartCollections: library.smartCollections,
                                   stations: library.stations,
                                   watchFolders: library.watchFolders.map(\.path),
                                   settings: exportedSettings())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(backup).write(to: root.appendingPathComponent("backup.json"))

        let artwork = Library.dataDirectory.appendingPathComponent("Artwork", isDirectory: true)
        if fileManager.fileExists(atPath: artwork.path) {
            try fileManager.copyItem(at: artwork, to: root.appendingPathComponent("Artwork", isDirectory: true))
        }

        try? fileManager.removeItem(at: url)
        try runZip(arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, url.path])
    }

    private static func restoreBackup(into library: Library, from url: URL) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CedarRestore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try runZip(arguments: ["-x", "-k", url.path, root.path])
        guard let backupURL = findBackup(in: root) else {
            throw NSError(domain: "CedarBackup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L10n.string("В архиве нет backup.json")])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(LibraryBackup.self, from: Data(contentsOf: backupURL))
        guard backup.version <= LibraryBackup.currentVersion else {
            throw NSError(domain: "CedarBackup", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: L10n.string("Копия создана более новой версией")])
        }

        let sourceArtwork = backupURL.deletingLastPathComponent().appendingPathComponent("Artwork", isDirectory: true)
        try restoreArtwork(from: sourceArtwork)
        library.tracks = backup.tracks
        library.playlists = backup.playlists
        library.smartCollections = backup.smartCollections
        library.stations = backup.stations
        library.watchFolders = backup.watchFolders.map { URL(fileURLWithPath: $0) }
        restoreSettings(backup.settings)
    }

    private static func runZip(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CedarBackup", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: L10n.string("Не удалось распаковать архив")])
        }
    }

    private static func findBackup(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                              includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "backup.json" {
            return url
        }
        return nil
    }

    private static func restoreArtwork(from source: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return }
        let target = Library.dataDirectory.appendingPathComponent("Artwork", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let files = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for file in files {
            let destination = target.appendingPathComponent(file.lastPathComponent)
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.copyItem(at: file, to: destination)
            }
        }
    }

    private static func exportedSettings() -> Data? {
        let defaults = UserDefaults.standard
        var values: [String: Any] = [:]
        for key in backedUpSettings {
            if let value = defaults.object(forKey: key) { values[key] = value }
        }
        return try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }

    private static func restoreSettings(_ data: Data?) {
        guard let data,
              let values = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return }
        for (key, value) in values where backedUpSettings.contains(key) {
            UserDefaults.standard.set(value, forKey: key)
        }
    }
}
