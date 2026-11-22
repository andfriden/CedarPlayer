import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine
import AVFoundation

/// Библиотека: треки, плейлисты, поиск, сортировка, сохранение состояния.
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

    /// Растёт при любом изменении треков или плейлистов; ключ кэша запросов.
    private var revision = 0

    /// Результат выборки для списка: треки и признак смешанных обложек.
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

    /// Экземпляр для тестов: без чтения и записи рабочей библиотеки.
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
    }

    // MARK: Хранилище

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

    // MARK: Список

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

    /// Единая выборка для панели плейлиста и окна библиотеки.
    /// Кэш живёт до изменения библиотеки, поиска, сортировки или фильтра.
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

    /// Перепроверяет наличие файлов и показывает счётчик в статусе.
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
        statusMessage = missing == 0 ? "Все файлы на месте" : "Недоступно файлов: \(missing)"
    }

    /// Диалог выбора нового пути для пропавшего файла.
    func presentReplacePanel(for track: Track) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Укажите файл для «\(track.displayTitle)»"
        panel.prompt = "Привязать"
        let folder = track.url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path) {
            panel.directoryURL = folder
        }
        if panel.runModal() == .OK, let url = panel.url {
            replaceFile(for: track.id, with: url)
        }
    }

    /// Привязывает существующий файл к записи, сохраняя оценки и обложку.
    func replaceFile(for id: UUID, with url: URL) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let target = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        tracks[index].url = target
        tracks[index].isMissing = false
        statusMessage = "Файл привязан: \(target.lastPathComponent)"
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

    // MARK: Импорт

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
        panel.message = "Выберите аудиофайлы или папку с музыкой"
        panel.prompt = "Добавить"

        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls, into: playlistID)
    }

    func importURLs(_ urls: [URL], into playlistID: UUID? = nil) {
        importTask?.cancel()
        importTask = Task { await importFiles(urls, into: playlistID) }
    }

    /// Прерывает текущий импорт: уже прочитанные треки остаются в библиотеке.
    func cancelImport() {
        importTask?.cancel()
    }

    /// Добавляет файлы и папки, возвращает только что добавленные треки.
    /// Битые, пустые и дублирующиеся файлы пропускаются и попадают в отчёт.
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

        // Плейлисты M3U/PLS раскрываем до обхода папок.
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
        statusMessage = "Читаю метаданные…"

        var imported: [Track] = []
        var referencedAudio: Set<String> = []

        // CUE-листы: один аудиофайл превращается в несколько треков-сегментов.
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
                statusMessage = "Читаю метаданные: \(index + 1) из \(files.count)"
            }
        }

        tracks.append(contentsOf: imported)

        // Новые треки сразу попадают в выбранный плейлист, а не только в «Все треки».
        if let playlistID,
           !imported.isEmpty,
           let index = playlists.firstIndex(where: { $0.id == playlistID }) {
            let ids = imported.map(\.id).filter { !playlists[index].trackIDs.contains($0) }
            playlists[index].trackIDs.append(contentsOf: ids)
        }

        isImporting = false
        importTask = nil

        var parts: [String] = []
        if cancelled { parts.append("Импорт отменён") }
        if imported.isEmpty {
            parts.append("Новых треков не найдено")
        } else {
            parts.append(imported.count == 1 ? "Добавлен 1 трек" : "Добавлено: \(imported.count)")
        }
        if duplicates > 0 { parts.append("дубликатов: \(duplicates)") }
        if !unreadableNames.isEmpty {
            let preview = unreadableNames.prefix(3).joined(separator: ", ")
            parts.append("не читается: \(unreadableNames.count) (\(preview))")
        }
        if cueFailures > 0 { parts.append("CUE с ошибками: \(cueFailures)") }
        if playlistFailures > 0 { parts.append("плейлистов с ошибками: \(playlistFailures)") }
        if ignored > 0 { parts.append("пропущено: \(ignored)") }
        if unreadableDirectories > 0 { parts.append("папок с ошибкой чтения: \(unreadableDirectories)") }
        statusMessage = parts.joined(separator: " · ")
        autoFetchArtwork(for: imported)
        return imported
    }

    /// Фоновый поиск обложек для импортированных треков без картинки.
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
                if found == 1 { self?.statusMessage = "Нашёл обложку: \(first.album)" }
            }
            guard let self else { return }
            if found > 0 {
                self.statusMessage = "Обложки найдены для \(found) из \(checked) альбомов"
            } else if checked > 0 {
                self.statusMessage = "Обложки не найдены (\(checked) альбомов)"
            }
        }
    }

    /// Проверяет, что файл действительно открывается декодером Core Audio.
    private static func canDecode(url: URL) async -> Bool {
        if (try? AVAudioFile(forReading: url)) != nil { return true }
        let asset = AVURLAsset(url: url)
        return (try? await asset.load(.isPlayable)) ?? false
    }

    /// Ключ уникальности: файл + смещение внутри CUE.
    nonisolated static func key(for track: Track) -> String {
        "\(track.url.standardizedFileURL.path)#\(track.cueStart.map { String(format: "%.3f", $0) } ?? "file")"
    }

    /// Ставит обложку выбранным трекам (хранится в кэше, в JSON — только ключ).
    func setArtwork(_ data: Data?, for trackIDs: Set<UUID>) {
        let key = data.flatMap { ArtworkCache.shared.store($0) }
        for index in tracks.indices where trackIDs.contains(tracks[index].id) {
            tracks[index].artwork = data
            tracks[index].artworkID = key
        }
    }

    /// Треки того же альбома и исполнителя альбома.
    func albumTrackIDs(for track: Track) -> Set<UUID> {
        guard !track.album.isEmpty else { return [] }
        let albumArtist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
        return Set(tracks.filter {
            $0.album == track.album
            && ($0.albumArtist.isEmpty ? $0.artist : $0.albumArtist) == albumArtist
        }.map(\.id))
    }

    /// Записывает теги в файл и обновляет запись в библиотеке.
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

    /// Оценка трека 0…5.
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
        statusMessage = "Удалено треков: \(ids.count) · ⌥⌘Z вернёт"
    }

    /// Возвращает последнее удаление (одно действие, пока его не перезаписали).
    func undoRemove() {
        guard let snapshot = lastRemoval else { return }
        tracks = snapshot.tracks
        playlists = snapshot.playlists
        lastRemoval = nil
        canUndoRemove = false
        statusMessage = "Удаление отменено"
    }

    // MARK: Плейлисты

    // MARK: Папки наблюдения

    func presentWatchFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Выберите папки, за которыми следить"
        panel.prompt = "Следить"
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
        let station = RadioStation(name: name.isEmpty ? URL(string: urlString)?.host ?? "Радио" : name,
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

    /// Догружает логотип, если его ещё нет.
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

    func createPlaylist(named name: String, unique: Bool = false) -> Playlist {
        let finalName = unique ? uniquePlaylistName(name) : name
        let playlist = Playlist(name: finalName)
        playlists.append(playlist)
        return playlist
    }

    func delete(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
    }

    /// Имя, которое ставится плейлисту до того, как он получил содержимое.
    static func isPlaceholderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || ["Новый плейлист", "Без названия", "New Playlist"].contains(trimmed)
    }

    /// «Папка», «Папка 2», «Папка 3» — без совпадений с другими плейлистами.
    func uniquePlaylistName(_ base: String, excluding id: UUID? = nil) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.isEmpty ? "Плейлист" : trimmed
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

    /// Убирает треки из плейлиста; сами файлы и записи библиотеки остаются.
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

    /// Импортирует папку и создаёт плейлист с её именем. Возвращает nil, если аудио нет.
    @discardableResult
    func importFolderAsPlaylist(_ folder: URL) async -> Playlist? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let imported = await importFiles([folder])
        let ids = playlistIDs(imported: imported, folder: folder)
        guard !ids.isEmpty else {
            statusMessage = "В папке «\(folder.lastPathComponent)» нет аудиофайлов"
            return nil
        }
        let created = createPlaylist(named: uniquePlaylistName(folder.lastPathComponent))
        add(Set(ids), to: created.id)
        statusMessage = "Плейлист «\(created.name)»: \(ids.count) трек(ов)"
        return playlist(with: created.id)
    }

    /// Добавляет папку в существующий плейлист; пустой плейлист с именем-заглушкой
    /// переименовывается по папке. Возвращает false, если аудио не нашлось.
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
            statusMessage = "В папке «\(folder.lastPathComponent)» нет аудиофайлов"
            return false
        }
        add(Set(ids), to: playlistID)
        if shouldRename {
            renamePlaylist(playlistID, to: uniquePlaylistName(folder.lastPathComponent, excluding: playlistID))
        }
        let count = playlist(with: playlistID)?.trackIDs.count ?? ids.count
        let name = playlist(with: playlistID)?.name ?? existing.name
        statusMessage = "Добавлено в «\(name)»: \(ids.count) · всего \(count)"
        return true
    }

    func add(_ ids: Set<UUID>, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        // Порядок — как в библиотеке: поиск и сортировка не должны мешать добавлению.
        let ordered = tracks.map(\.id).filter { ids.contains($0) }
        playlists[index].trackIDs.append(contentsOf: ordered.filter { !playlists[index].trackIDs.contains($0) })
    }

    func playlist(with id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }
}
