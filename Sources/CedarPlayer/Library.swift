import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine
import AVFoundation
import ImageIO

/// Library: tracks, playlists, search, sorting and state persistence.
@MainActor
final class Library: ObservableObject {

    @Published var tracks: [Track] = [] {
        didSet {
            revision &+= 1
            scheduleSave()
        }
    }
    @Published var playlists: [Playlist] = [] {
        didSet {
            revision &+= 1
            scheduleSave()
        }
    }
    @Published var stations: [RadioStation] = [] {
        didSet { scheduleSave() }
    }
    @Published var watchFolders: [URL] = [] {
        didSet {
            scheduleSave()
            watcher.watch(watchFolders)
        }
    }
    @Published var searchText: String = ""
    @Published var sortKey: SortKey = .added {
        didSet { UserDefaults.standard.set(sortKey.rawValue, forKey: "sortKey") }
    }
    @Published var sortAscending: Bool = true
    @Published var isImporting = false
    @Published var statusMessage: String?
    @Published private(set) var canUndoRemove = false
    private var lastRemoval: (tracks: [Track], playlists: [Playlist])?

    /// Grows on any track or playlist change; key for the query cache.
    private var revision = 0

    /// List query result: tracks and a mixed-artwork flag.
    struct TrackListResult {
        let tracks: [Track]
        let mixedArtwork: Bool
    }

    private struct QueryKey: Hashable {
        var filterID: String
        var search: String
        var sortKey: SortKey
        var ascending: Bool
        var revision: Int
    }

    private var queryCache: [QueryKey: TrackListResult] = [:]
    private var queryOrder: [QueryKey] = []
    private var indexRevision = -1
    private var tracksByID: [UUID: Track] = [:]
    private var searchIndex: [UUID: String] = [:]

    private var saveWorkItem: DispatchWorkItem?
    private let watcher = FolderWatcher()
    private var importTask: Task<Void, Never>?
    private var isRepairingArtwork = false

    private static let supportDirectory: URL = {
        if let custom = ProcessInfo.processInfo.environment["CEDAR_LIBRARY_DIR"], !custom.isEmpty {
            let base = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CedarPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static var storeURL: URL { supportDirectory.appendingPathComponent("library.json") }

    private struct Store: Codable {
        var tracks: [Track]
        var playlists: [Playlist]
        var stations: [RadioStation]?
        var watchFolders: [String]?
    }

    private var isTestInstance = false

    /// Test instance: does not read or write the working library.
    init(testTracks: [Track] = []) {
        isTestInstance = true
        tracks = testTracks
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: "sortKey"), let key = SortKey(rawValue: raw) {
            sortKey = key
        }
        load()
        watcher.onChange = { [weak self] folder in
            guard let self else { return }
            Task { @MainActor in
                let previous = self.statusMessage
                let imported = await self.importFiles([folder])
                if imported.isEmpty { self.statusMessage = previous }
            }
        }
        watcher.watch(watchFolders)
        repairArtwork()
    }

    // MARK: Storage

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        guard let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        var loaded = store.tracks
        for index in loaded.indices where !FileManager.default.fileExists(atPath: loaded[index].url.path) {
            loaded[index].isMissing = true
        }
        tracks = loaded
        playlists = store.playlists
        stations = store.stations ?? []
        watchFolders = (store.watchFolders ?? []).map { URL(fileURLWithPath: $0) }
    }

    private func scheduleSave() {
        guard !isTestInstance else { return }
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let store = Store(tracks: self.tracks,
                              playlists: self.playlists,
                              stations: self.stations,
                              watchFolders: self.watchFolders.map(\.path))
            guard let data = try? JSONEncoder().encode(store) else { return }
            try? data.write(to: Self.storeURL, options: .atomic)

            var keys = Set(self.tracks.compactMap { $0.artworkID })
            keys.formUnion(self.stations.compactMap { $0.logoID })
            for track in self.tracks where track.artworkID == nil {
                if let key = ArtworkCache.shared.store(track.artwork) { keys.insert(key) }
            }
            ArtworkCache.shared.prune(keeping: keys)
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: List

    var visibleTracks: [Track] {
        query(filterID: "all", search: searchText, sortKey: sortKey, ascending: sortAscending).tracks
    }

    private func ensureIndex() {
        guard indexRevision != revision else { return }
        tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        searchIndex = Dictionary(uniqueKeysWithValues: tracks.map { track in
            (track.id, "\(track.displayTitle)\n\(track.artist)\n\(track.album)\n\(track.url.lastPathComponent)".lowercased())
        })
        indexRevision = revision
    }

    private func trackMap() -> [UUID: Track] {
        ensureIndex()
        return tracksByID
    }

    /// Shared query for the playlist pane and library window.
    /// The cache is valid until the library, search, sorting or filter changes.
    func query(filterID: String, search: String, sortKey: SortKey, ascending: Bool) -> TrackListResult {
        let key = QueryKey(filterID: filterID,
                           search: search,
                           sortKey: sortKey,
                           ascending: ascending,
                           revision: revision)
        if let cached = queryCache[key] {
            return cached
        }

        var list: [Track]
        if filterID == "all" {
            list = tracks
        } else if filterID.hasPrefix("smart:"),
                  let rule = SmartRule(rawValue: String(filterID.dropFirst(6))) {
            list = rule.filter(tracks)
        } else if let playlist = playlists.first(where: { $0.id.uuidString == filterID }) {
            let byID = trackMap()
            list = playlist.trackIDs.compactMap { byID[$0] }
        } else {
            list = tracks
        }

        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            ensureIndex()
            list = list.filter { (searchIndex[$0.id] ?? "").contains(needle) }
        }

        switch sortKey {
        case .added: list.sort { $0.addedAt < $1.addedAt }
        case .title: list.sort { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        case .artist: list.sort { $0.displayArtist.localizedStandardCompare($1.displayArtist) == .orderedAscending }
        case .album: list.sort { $0.displayAlbum.localizedStandardCompare($1.displayAlbum) == .orderedAscending }
        case .duration: list.sort { $0.duration < $1.duration }
        }
        if !ascending { list.reverse() }

        var signatures = Set<String>()
        var withArtwork = 0
        for track in list where track.artwork != nil {
            withArtwork += 1
            signatures.insert(track.artworkID ?? "\(track.album)|\(track.albumArtist)|\(track.artist)")
            if signatures.count > 1 { break }
        }
        let result = TrackListResult(tracks: list, mixedArtwork: withArtwork > 1 && signatures.count > 1)

        queryCache[key] = result
        queryOrder.append(key)
        if queryOrder.count > 4, let oldest = queryOrder.first {
            queryOrder.removeFirst()
            queryCache.removeValue(forKey: oldest)
        }
        return result
    }

    /// Rechecks file availability and shows the count in the status line.
    func refreshAvailability() {
        var updated = tracks
        var changed = false
        var missing = 0
        for index in updated.indices {
            let isMissing = !FileManager.default.fileExists(atPath: updated[index].url.path)
            if isMissing { missing += 1 }
            if updated[index].isMissing != isMissing {
                updated[index].isMissing = isMissing
                changed = true
            }
        }
        if changed { tracks = updated }
        statusMessage = missing == 0 ? L10n.string("Все файлы на месте") : L10n.format("Недоступно файлов: %ld", missing)
    }

    /// Dialog for choosing a new path for a missing file.
    func presentReplacePanel(for track: Track) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.format("Укажите файл для «%@»", track.displayTitle)
        panel.prompt = L10n.string("Привязать")
        let folder = track.url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path) {
            panel.directoryURL = folder
        }
        if panel.runModal() == .OK, let url = panel.url {
            replaceFile(for: track.id, with: url)
        }
    }

    /// Links an existing file to the entry while keeping ratings and artwork.
    func replaceFile(for id: UUID, with url: URL) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let target = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        tracks[index].url = target
        tracks[index].isMissing = false
        statusMessage = L10n.format("Файл привязан: %@", target.lastPathComponent)
    }

    var missingCount: Int {
        tracks.reduce(0) { $0 + ($1.isMissing ? 1 : 0) }
    }

    func track(with id: UUID) -> Track? {
        trackMap()[id]
    }

    func tracks(in playlist: Playlist) -> [Track] {
        let byID = trackMap()
        return playlist.trackIDs.compactMap { byID[$0] }
    }

    // MARK: Import

    /// Repairs artwork cached by older versions (for example, a stray null byte
    /// before the JPEG/PNG payload) by reading the picture again from the file.
    func repairArtwork() {
        guard !isTestInstance, !isRepairingArtwork else { return }
        let candidates = tracks.filter { track in
            guard track.artworkID != nil else { return false }
            guard let data = track.artwork else { return true }
            return !Self.isValidImage(data)
        }
        guard !candidates.isEmpty else { return }

        isRepairingArtwork = true
        Task { @MainActor in
            var updated = tracks
            var repaired = 0
            for candidate in candidates {
                guard let index = updated.firstIndex(where: { $0.id == candidate.id }) else { continue }
                let url = updated[index].url
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let tags = await Task.detached(priority: .utility) { TagReader.read(url: url) }.value
                guard let art = tags.artwork,
                      Self.isValidImage(art),
                      let key = ArtworkCache.shared.store(art) else { continue }
                updated[index].artwork = art
                updated[index].artworkID = key
                repaired += 1
            }
            if repaired > 0 {
                tracks = updated
                statusMessage = L10n.format("Исправлено обложек: %ld", repaired)
            }
            isRepairingArtwork = false
        }
    }

    private static func isValidImage(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetType(source) != nil
    }

    func presentImportPanel(into playlistID: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        for ext in PlaylistFile.extensions {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        panel.allowedContentTypes = types
        panel.message = L10n.string("Выберите аудиофайлы или папку с музыкой")
        panel.prompt = L10n.string("Добавить")

        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls, into: playlistID)
    }

    func importURLs(_ urls: [URL], into playlistID: UUID? = nil) {
        importTask?.cancel()
        importTask = Task { await importFiles(urls, into: playlistID) }
    }

    /// Cancels the current import: tracks already read stay in the library.
    func cancelImport() {
        importTask?.cancel()
    }

    /// Adds files and folders and returns only the newly added tracks.
    /// Broken, empty and duplicate files are skipped and reported.
    @discardableResult
    func importFiles(_ urls: [URL], into playlistID: UUID? = nil) async -> [Track] {
        let fm = FileManager.default
        var files: [URL] = []
        var cueFiles: [URL] = []
        var playlistFailures = 0
        var duplicates = 0
        var ignored = 0
        var unreadableDirectories = 0
        var unreadableNames: [String] = []
        var cueFailures = 0
        var cancelled = false

        var seenPaths = Set<String>()
        func register(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else {
                duplicates += 1
                return
            }
            if url.lastPathComponent.hasPrefix(".") {
                ignored += 1
                return
            }
            if url.pathExtension.lowercased() == "cue" {
                cueFiles.append(url)
            } else {
                files.append(url)
            }
        }

        // Expand M3U/PLS playlists before walking folders.
        var inputs: [URL] = []
        for url in urls {
            if PlaylistFile.isPlaylist(url) {
                let entries = PlaylistFile.parse(url)
                if entries.isEmpty { playlistFailures += 1 }
                inputs.append(contentsOf: entries)
            } else {
                inputs.append(url)
            }
        }

        for url in inputs {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                ignored += 1
                continue
            }
            if isDirectory.boolValue {
                var failed = false
                let enumerator = fm.enumerator(at: url,
                                               includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                               errorHandler: { _, _ in
                                                   failed = true
                                                   return true
                                               })
                if enumerator == nil { unreadableDirectories += 1 }
                while let child = enumerator?.nextObject() as? URL {
                    if PlaylistFile.isPlaylist(child) {
                        let entries = PlaylistFile.parse(child)
                        if entries.isEmpty { playlistFailures += 1 }
                        entries.forEach(register)
                        continue
                    }
                    guard Track.isSupported(child) else { continue }
                    register(child)
                }
                if failed { unreadableDirectories += 1 }
            } else if PlaylistFile.isPlaylist(url) {
                let entries = PlaylistFile.parse(url)
                if entries.isEmpty { playlistFailures += 1 }
                entries.forEach(register)
            } else if Track.isSupported(url) {
                register(url)
            } else {
                ignored += 1
            }
        }

        isImporting = true
        statusMessage = L10n.string("Читаю метаданные…")

        var imported: [Track] = []
        var referencedAudio: Set<String> = []

        // CUE sheets: one audio file becomes several segment tracks.
        for cueURL in cueFiles {
            if Task.isCancelled { cancelled = true; break }
            guard let sheet = CueParser.parse(url: cueURL) else {
                cueFailures += 1
                continue
            }
            guard fm.fileExists(atPath: sheet.fileURL.path) else {
                cueFailures += 1
                continue
            }
            referencedAudio.insert(sheet.fileURL.standardizedFileURL.path)
            let metadata = await MetadataReader.read(url: sheet.fileURL)

            for entry in sheet.tracks {
                var track = Track(url: sheet.fileURL)
                track.title = entry.title.isEmpty ? L10n.format("Трек %ld", entry.number) : entry.title
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

        // Regular files: skip those already covered by a CUE sheet.
        files = files.filter { !referencedAudio.contains($0.standardizedFileURL.path) }

        let existingKeys = Set(tracks.map { Self.key(for: $0) })
        var knownKeys = existingKeys
        imported = imported.filter { track in
            let key = Self.key(for: track)
            if knownKeys.contains(key) {
                duplicates += 1
                return false
            }
            knownKeys.insert(key)
            return true
        }
        files = files.filter { url in
            if existingKeys.contains(Self.key(for: Track(url: url))) {
                duplicates += 1
                return false
            }
            return true
        }

        for (index, url) in files.enumerated() {
            if Task.isCancelled { cancelled = true; break }

            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size == 0 {
                unreadableNames.append(url.lastPathComponent)
                continue
            }

            guard await Self.canDecode(url: url) else {
                unreadableNames.append(url.lastPathComponent)
                continue
            }
            imported.append(await MetadataReader.read(url: url))
            if index % 8 == 0 || index == files.count - 1 {
                statusMessage = L10n.format("Читаю метаданные: %ld из %ld", index + 1, files.count)
            }
        }

        tracks.append(contentsOf: imported)

        // New tracks go straight into the selected playlist, not only into "All Tracks".
        if let playlistID,
           !imported.isEmpty,
           let index = playlists.firstIndex(where: { $0.id == playlistID }) {
            let ids = imported.map(\.id).filter { !playlists[index].trackIDs.contains($0) }
            playlists[index].trackIDs.append(contentsOf: ids)
        }

        isImporting = false
        importTask = nil

        var parts: [String] = []
        if cancelled { parts.append(L10n.string("Импорт отменён")) }
        if imported.isEmpty {
            parts.append(L10n.string("Новых треков не найдено"))
        } else {
            parts.append(imported.count == 1 ? L10n.string("Добавлен 1 трек") : L10n.format("Добавлено: %ld", imported.count))
        }
        if duplicates > 0 { parts.append(L10n.format("дубликатов: %ld", duplicates)) }
        if !unreadableNames.isEmpty {
            let preview = unreadableNames.prefix(3).joined(separator: ", ")
            parts.append(L10n.format("не читается: %ld (%@)", unreadableNames.count, preview))
        }
        if cueFailures > 0 { parts.append(L10n.format("CUE с ошибками: %ld", cueFailures)) }
        if playlistFailures > 0 { parts.append(L10n.format("плейлистов с ошибками: %ld", playlistFailures)) }
        if ignored > 0 { parts.append(L10n.format("пропущено: %ld", ignored)) }
        if unreadableDirectories > 0 { parts.append(L10n.format("папок с ошибкой чтения: %ld", unreadableDirectories)) }
        statusMessage = parts.joined(separator: " · ")
        autoFetchArtwork(for: imported)
        return imported
    }

    /// Background artwork search for imported tracks without an image.
    private func autoFetchArtwork(for imported: [Track]) {
        guard !imported.isEmpty else { return }
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "autoCoverSearch") == nil
            ? true
            : defaults.bool(forKey: "autoCoverSearch")
        guard enabled else { return }

        let missing = imported.filter { $0.artwork == nil && !$0.album.isEmpty }
        guard !missing.isEmpty else { return }
        let groups = Dictionary(grouping: missing) { track in
            "\(track.album)|\(track.albumArtist.isEmpty ? track.artist : track.albumArtist)"
        }
        guard !groups.isEmpty else { return }

        Task { @MainActor [weak self] in
            var found = 0
            var checked = 0
            for group in groups.values.prefix(20) {
                guard let first = group.first else { continue }
                checked += 1
                let artist = first.albumArtist.isEmpty ? first.artist : first.albumArtist
                guard let candidate = try? await CoverArtService.shared
                    .search(artist: artist, album: first.album).first else { continue }
                self?.setArtwork(candidate.imageData, for: Set(group.map(\.id)))
                found += 1
                if found == 1 { self?.statusMessage = L10n.format("Нашёл обложку: %@", first.album) }
            }
            guard let self else { return }
            if found > 0 {
                self.statusMessage = L10n.format("Обложки найдены для %ld из %ld альбомов", found, checked)
            } else if checked > 0 {
                self.statusMessage = L10n.format("Обложки не найдены (%ld альбомов)", checked)
            }
        }
    }

    /// Checks that the file really opens with the Core Audio decoder.
    private static func canDecode(url: URL) async -> Bool {
        if (try? AVAudioFile(forReading: url)) != nil { return true }
        let asset = AVURLAsset(url: url)
        return (try? await asset.load(.isPlayable)) ?? false
    }

    /// Identity key: file + offset inside the CUE.
    nonisolated static func key(for track: Track) -> String {
        "\(track.url.standardizedFileURL.path)#\(track.cueStart.map { String(format: "%.3f", $0) } ?? "file")"
    }

    /// Sets artwork on the selected tracks (stored in the cache; JSON holds only the key).
    func setArtwork(_ data: Data?, for trackIDs: Set<UUID>) {
        let key = data.flatMap { ArtworkCache.shared.store($0) }
        for index in tracks.indices where trackIDs.contains(tracks[index].id) {
            tracks[index].artwork = data
            tracks[index].artworkID = key
        }
    }

    /// Tracks with the same album and album artist.
    func albumTrackIDs(for track: Track) -> Set<UUID> {
        guard !track.album.isEmpty else { return [] }
        let albumArtist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
        return Set(tracks.filter {
            $0.album == track.album
            && ($0.albumArtist.isEmpty ? $0.artist : $0.albumArtist) == albumArtist
        }.map(\.id))
    }

    /// Writes tags to the file and updates the library entry.
    @discardableResult
    func applyTags(_ edit: TagEdit, to trackID: UUID) throws -> Track? {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return nil }
        try TagWriter.write(edit, to: tracks[index].url)
        tracks[index].title = edit.title
        tracks[index].artist = edit.artist
        tracks[index].album = edit.album
        tracks[index].albumArtist = edit.albumArtist
        tracks[index].trackNumber = edit.trackNumber
        tracks[index].genre = edit.genre
        tracks[index].year = edit.year
        tracks[index].composer = edit.composer
        return tracks[index]
    }

    /// Track rating 0…5.
    func setRating(_ rating: Int, for ids: Set<UUID>) {
        let clamped = min(max(rating, 0), 5)
        for index in tracks.indices where ids.contains(tracks[index].id) {
            tracks[index].rating = clamped
        }
    }

    func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty, tracks.contains(where: { ids.contains($0.id) }) else { return }
        lastRemoval = (tracks, playlists)
        canUndoRemove = true
        tracks.removeAll { ids.contains($0.id) }
        for index in playlists.indices {
            playlists[index].trackIDs.removeAll { ids.contains($0) }
        }
        statusMessage = L10n.format("Удалено треков: %ld · ⌥⌘Z вернёт", ids.count)
    }

    /// Returns the last removal (one action until overwritten).
    func undoRemove() {
        guard let snapshot = lastRemoval else { return }
        tracks = snapshot.tracks
        playlists = snapshot.playlists
        lastRemoval = nil
        canUndoRemove = false
        statusMessage = L10n.string("Удаление отменено")
    }

    // MARK: Watched folders

    func presentWatchFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = L10n.string("Выберите папки, за которыми следить")
        panel.prompt = L10n.string("Следить")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addWatchFolder(url)
        }
    }

    func addWatchFolder(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard !watchFolders.contains(where: { $0.standardizedFileURL == standardized }) else { return }
        watchFolders.append(standardized)
    }

    func removeWatchFolder(_ url: URL) {
        watchFolders.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
    }

    @discardableResult
    func addStation(name: String, urlString: String, logoURLString: String? = nil) -> RadioStation? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty, URL(string: urlString) != nil else { return nil }
        let logo = logoURLString?.trimmingCharacters(in: .whitespacesAndNewlines)
        let station = RadioStation(name: name.isEmpty ? URL(string: urlString)?.host ?? L10n.string("Радио") : name,
                                   urlString: urlString,
                                   logoURLString: (logo?.isEmpty ?? true) ? nil : logo)
        stations.append(station)
        fetchStationLogo(station)
        return station
    }

    func stationLogo(_ station: RadioStation) -> Data? {
        guard let id = station.logoID else { return nil }
        return ArtworkCache.shared.data(for: id)
    }

    /// Loads the logo if it is not available yet.
    func ensureStationLogo(_ station: RadioStation) {
        guard station.logoID == nil else { return }
        fetchStationLogo(station)
    }

    private func fetchStationLogo(_ station: RadioStation) {
        Task { @MainActor in
            guard let data = await RadioLogoLoader.load(station),
                  let key = ArtworkCache.shared.store(data),
                  let index = stations.firstIndex(where: { $0.id == station.id }) else { return }
            stations[index].logoID = key
        }
    }

    func removeStation(_ id: UUID) {
        stations.removeAll { $0.id == id }
    }

    // MARK: Playlists

    func createPlaylist(named name: String, unique: Bool = false) -> Playlist {
        let finalName = unique ? uniquePlaylistName(name) : name
        let playlist = Playlist(name: finalName)
        playlists.append(playlist)
        return playlist
    }

    func delete(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
    }

    /// Name assigned to a playlist before it has content.
    static func isPlaceholderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || [L10n.string("Новый плейлист"), L10n.string("Без названия"), "New Playlist"].contains(trimmed)
    }

    /// "Folder", "Folder 2", "Folder 3" — without collisions with other playlists.
    func uniquePlaylistName(_ base: String, excluding id: UUID? = nil) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.isEmpty ? L10n.string("Плейлист") : trimmed
        var name = candidate
        var index = 2
        while playlists.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(candidate) \(index)"
            index += 1
        }
        return name
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = trimmed
    }

    /// Removes tracks from a playlist; files and library entries remain.
    func clearPlaylist(_ id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].trackIDs.removeAll()
    }

    private func tracksUnder(_ folder: URL) -> [Track] {
        let base = folder.standardizedFileURL.path
        return tracks.filter { track in
            let path = track.url.standardizedFileURL.path
            return path == base || path.hasPrefix(base + "/")
        }
    }

    private func playlistIDs(imported: [Track], folder: URL) -> [UUID] {
        var seen = Set<UUID>()
        return (imported + tracksUnder(folder)).map(\.id).filter { seen.insert($0).inserted }
    }

    /// Imports a folder and creates a playlist named after it. Returns nil if there is no audio.
    @discardableResult
    func importFolderAsPlaylist(_ folder: URL) async -> Playlist? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let imported = await importFiles([folder])
        let ids = playlistIDs(imported: imported, folder: folder)
        guard !ids.isEmpty else {
            statusMessage = L10n.format("В папке «%@» нет аудиофайлов", folder.lastPathComponent)
            return nil
        }
        let created = createPlaylist(named: uniquePlaylistName(folder.lastPathComponent))
        add(Set(ids), to: created.id)
        statusMessage = L10n.format("Плейлист «%@»: %ld трек(ов)", created.name, ids.count)
        return playlist(with: created.id)
    }

    /// Adds a folder to an existing playlist; an empty playlist with a placeholder name
    /// is renamed after the folder. Returns false if no audio was found.
    @discardableResult
    func importFolder(_ folder: URL, into playlistID: UUID, renamePlaceholder: Bool = true) async -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let existing = playlist(with: playlistID) else { return false }
        let shouldRename = renamePlaceholder
            && existing.trackIDs.isEmpty
            && Self.isPlaceholderName(existing.name)

        let imported = await importFiles([folder])
        let ids = playlistIDs(imported: imported, folder: folder)
        guard !ids.isEmpty else {
            statusMessage = L10n.format("В папке «%@» нет аудиофайлов", folder.lastPathComponent)
            return false
        }
        add(Set(ids), to: playlistID)
        if shouldRename {
            renamePlaylist(playlistID, to: uniquePlaylistName(folder.lastPathComponent, excluding: playlistID))
        }
        let count = playlist(with: playlistID)?.trackIDs.count ?? ids.count
        let name = playlist(with: playlistID)?.name ?? existing.name
        statusMessage = L10n.format("Добавлено в «%@»: %ld · всего %ld", name, ids.count, count)
        return true
    }

    func add(_ ids: Set<UUID>, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        // Order follows the library: search and sorting must not affect adding.
        let ordered = tracks.map(\.id).filter { ids.contains($0) }
        playlists[index].trackIDs.append(contentsOf: ordered.filter { !playlists[index].trackIDs.contains($0) })
    }

    func playlist(with id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }
}
