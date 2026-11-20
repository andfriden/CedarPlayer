import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine

/// Библиотека: треки, плейлисты, поиск, сортировка, сохранение состояния.
@MainActor
final class Library: ObservableObject {

    @Published var tracks: [Track] = [] {
        didSet { scheduleSave() }
    }
    @Published var playlists: [Playlist] = [] {
        didSet { scheduleSave() }
    }
    @Published var searchText: String = ""
    @Published var sortKey: SortKey = .added {
        didSet { UserDefaults.standard.set(sortKey.rawValue, forKey: "sortKey") }
    }
    @Published var sortAscending: Bool = true
    @Published var isImporting = false
    @Published var statusMessage: String?

    private var saveWorkItem: DispatchWorkItem?

    private static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CedarPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static var storeURL: URL { supportDirectory.appendingPathComponent("library.json") }

    private struct Store: Codable {
        var tracks: [Track]
        var playlists: [Playlist]
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: "sortKey"), let key = SortKey(rawValue: raw) {
            sortKey = key
        }
        load()
    }

    // MARK: Хранилище

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        guard let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        tracks = store.tracks.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        playlists = store.playlists
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let store = Store(tracks: self.tracks, playlists: self.playlists)
            guard let data = try? JSONEncoder().encode(store) else { return }
            try? data.write(to: Self.storeURL, options: .atomic)

            var keys = Set(self.tracks.compactMap { $0.artworkID })
            for track in self.tracks where track.artworkID == nil {
                if let key = ArtworkCache.shared.store(track.artwork) { keys.insert(key) }
            }
            ArtworkCache.shared.prune(keeping: keys)
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: Список

    var visibleTracks: [Track] {
        let filtered: [Track]
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            filtered = tracks
        } else {
            let needle = searchText.lowercased()
            filtered = tracks.filter {
                $0.displayTitle.lowercased().contains(needle)
                || $0.artist.lowercased().contains(needle)
                || $0.album.lowercased().contains(needle)
                || $0.url.lastPathComponent.lowercased().contains(needle)
            }
        }

        let sorted: [Track]
        switch sortKey {
        case .added: sorted = filtered.sorted { $0.addedAt < $1.addedAt }
        case .title: sorted = filtered.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        case .artist: sorted = filtered.sorted { $0.displayArtist.localizedStandardCompare($1.displayArtist) == .orderedAscending }
        case .album: sorted = filtered.sorted { $0.displayAlbum.localizedStandardCompare($1.displayAlbum) == .orderedAscending }
        case .duration: sorted = filtered.sorted { $0.duration < $1.duration }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    func track(with id: UUID) -> Track? {
        tracks.first { $0.id == id }
    }

    func tracks(in playlist: Playlist) -> [Track] {
        playlist.trackIDs.compactMap { track(with: $0) }
    }

    // MARK: Импорт

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        panel.message = "Выберите аудиофайлы или папку с музыкой"
        panel.prompt = "Добавить"

        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    func importURLs(_ urls: [URL]) {
        Task { await importFiles(urls) }
    }

    /// Добавляет файлы и папки, возвращает только что добавленные треки.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> [Track] {
        var files: [URL] = []
        var cueFiles: [URL] = []
        let fm = FileManager.default

        for url in urls {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let child as URL in enumerator where Track.isSupported(child) {
                        if child.pathExtension.lowercased() == "cue" {
                            cueFiles.append(child)
                        } else {
                            files.append(child)
                        }
                    }
                }
            } else if Track.isSupported(url) {
                if url.pathExtension.lowercased() == "cue" {
                    cueFiles.append(url)
                } else {
                    files.append(url)
                }
            }
        }

        isImporting = true
        statusMessage = "Читаю метаданные…"

        var imported: [Track] = []
        var referencedAudio: Set<String> = []

        // CUE-листы: один аудиофайл превращается в несколько треков-сегментов.
        for cueURL in cueFiles {
            guard let sheet = CueParser.parse(url: cueURL) else {
                statusMessage = "CUE не разобран: \(cueURL.lastPathComponent)"
                continue
            }
            guard fm.fileExists(atPath: sheet.fileURL.path) else {
                statusMessage = "Нет аудиофайла для \(cueURL.lastPathComponent)"
                continue
            }
            referencedAudio.insert(sheet.fileURL.standardizedFileURL.path)
            let metadata = await MetadataReader.read(url: sheet.fileURL)

            for entry in sheet.tracks {
                var track = Track(url: sheet.fileURL)
                track.title = entry.title.isEmpty ? "Трек \(entry.number)" : entry.title
                track.artist = entry.performer.isEmpty ? sheet.performer : entry.performer
                track.album = sheet.title
                track.albumArtist = sheet.performer
                track.trackNumber = entry.number
                track.cueStart = entry.start
                let end = entry.end ?? metadata.duration
                track.cueEnd = end > entry.start ? end : metadata.duration
                track.duration = max(0, (track.cueEnd ?? metadata.duration) - entry.start)
                track.artwork = metadata.artwork
                track.sampleRate = metadata.sampleRate
                track.bitDepth = metadata.bitDepth
                track.channels = metadata.channels
                imported.append(track)
            }
        }

        // Обычные файлы: пропускаем те, что уже описаны CUE-листом.
        files = files.filter { !referencedAudio.contains($0.standardizedFileURL.path) }

        let existingKeys = Set(tracks.map { Self.key(for: $0) })
        var knownKeys = existingKeys
        imported = imported.filter { track in
            let key = Self.key(for: track)
            if knownKeys.contains(key) { return false }
            knownKeys.insert(key)
            return true
        }
        files = files.filter { !existingKeys.contains(Self.key(for: Track(url: $0))) }

        guard !files.isEmpty || !imported.isEmpty else {
            isImporting = false
            statusMessage = "Новых треков не найдено"
            return []
        }

        for (index, url) in files.enumerated() {
            let track = await MetadataReader.read(url: url)
            imported.append(track)
            if index % 8 == 0 {
                statusMessage = "Читаю метаданные: \(index + 1) из \(files.count)"
            }
        }

        tracks.append(contentsOf: imported)
        isImporting = false
        statusMessage = imported.count == 1 ? "Добавлен 1 трек" : "Добавлено треков: \(imported.count)"
        return imported
    }

    /// Ключ уникальности: файл + смещение внутри CUE.
    nonisolated static func key(for track: Track) -> String {
        "\(track.url.standardizedFileURL.path)#\(track.cueStart.map { String(format: "%.3f", $0) } ?? "file")"
    }

    func remove(_ ids: Set<UUID>) {
        tracks.removeAll { ids.contains($0.id) }
        for index in playlists.indices {
            playlists[index].trackIDs.removeAll { ids.contains($0) }
        }
    }

    // MARK: Плейлисты

    @discardableResult
    func createPlaylist(named name: String) -> Playlist {
        let playlist = Playlist(name: name)
        playlists.append(playlist)
        return playlist
    }

    func delete(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
    }

    func add(_ ids: Set<UUID>, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let ordered = visibleTracks.map(\.id).filter { ids.contains($0) }
        playlists[index].trackIDs.append(contentsOf: ordered.filter { !playlists[index].trackIDs.contains($0) })
    }

    func playlist(with id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }
}
