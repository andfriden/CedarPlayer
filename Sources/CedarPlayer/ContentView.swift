import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.player) private var player

    @State private var selection: Set<UUID> = []
    @State private var filter = LibraryFilter()
    @State private var lastSelectedIndex: Int?
    @State private var sidebarSelection: SidebarItem? = .allTracks
    @State private var newPlaylistName = ""
    @State private var isNamingPlaylist = false
    @State private var isDropping = false
    @State private var isAddingStation = false
    @State private var stationName = ""
    @State private var stationURL = ""
    @State private var stationLogoURL = ""
    @State private var dropTargetPlaylist: UUID?
    @State private var isCreatingPlaylistFromDrop = false
    @State private var openAlbum: AlbumGroup?
    @AppStorage("libraryLayout") private var layout = "list"

    enum SidebarItem: Hashable {
        case allTracks
        case smart(SmartRule)
        case playlist(UUID)
    }

    @ViewBuilder
    private func stationIcon(_ station: RadioStation) -> some View {
        if let data = library.stationLogo(station), let image = NSImage(data: data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var baseTracks: [Track] {
        switch sidebarSelection {
        case .smart(let rule):
            return rule.filter(library.visibleTracks)
        case .playlist(let id):
            guard let playlist = library.playlist(with: id) else { return [] }
            let all = library.tracks(in: playlist)
            guard !library.searchText.isEmpty else { return all }
            let needle = library.searchText.lowercased()
            return all.filter {
                $0.displayTitle.lowercased().contains(needle)
                || $0.artist.lowercased().contains(needle)
                || $0.album.lowercased().contains(needle)
            }
        default:
            return library.visibleTracks
        }
    }

    private var displayedTracks: [Track] { filter.apply(to: baseTracks) }

    private var filterGenres: [String] {
        Array(Set(library.tracks.map(\.genre).filter { !$0.isEmpty })).sorted()
    }
    private var filterYears: [String] {
        Array(Set(library.tracks.map(\.year).filter { !$0.isEmpty })).sorted().reversed().map { $0 }
    }
    private var filterFormats: [String] {
        Array(Set(library.tracks.map { $0.url.pathExtension.uppercased() }.filter { !$0.isEmpty })).sorted()
    }

    private var selectedPlaylistID: UUID? {
        if case .playlist(let id) = sidebarSelection { return id }
        return nil
    }

    private var detailTracks: [Track] { openAlbum?.tracks ?? displayedTracks }

    private var albums: [AlbumGroup] { AlbumGroup.group(displayedTracks) }

    private var currentTitle: String {
        switch sidebarSelection {
        case .playlist(let id): return library.playlist(with: id)?.name ?? L10n.string("Плейлист")
        case .smart(let rule): return rule.title
        default: return L10n.string("Все треки")
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                if layout == "grid", openAlbum == nil {
                    albumGrid
                } else {
                    trackList
                }
            }
            .frame(minWidth: 480, minHeight: 480)
            .background(Color(nsColor: .windowBackgroundColor))
            .onDrop(of: [.fileURL], isTargeted: $isDropping) { providers in
                handleDrop(providers)
            }
            .overlay {
                if isDropping {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "Поиск по названию, исполнителю, альбому")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    library.presentImportPanel(into: selectedPlaylistID)
                } label: {
                    Label("Добавить файлы", systemImage: "plus")
                }
                .help("Добавить файлы или папку (⌘O)")

                Picker("Вид", selection: $layout) {
                    Image(systemName: "list.bullet").tag("list")
                    Image(systemName: "square.grid.2x2").tag("grid")
                }
                .pickerStyle(.segmented)
                .help("Список или сетка альбомов")
                .onChange(of: layout) { newValue in
                    if newValue == "list" { openAlbum = nil }
                }

                Menu {
                    Button("M3U…") { exportTracks(.m3u) }
                    Button("PLS…") { exportTracks(.pls) }
                } label: {
                    Label("Экспорт", systemImage: "square.and.arrow.up")
                }
                .help("Экспорт видимого списка в плейлист-файл")
                .disabled(detailTracks.isEmpty)

                Menu {
                    Picker("Жанр", selection: $filter.genre) {
                        Text("Все").tag(String?.none)
                        ForEach(filterGenres, id: \.self) { genre in
                            Text(genre).tag(Optional(genre))
                        }
                    }
                    Picker("Год", selection: $filter.year) {
                        Text("Все").tag(String?.none)
                        ForEach(filterYears, id: \.self) { year in
                            Text(year).tag(Optional(year))
                        }
                    }
                    Picker("Формат", selection: $filter.format) {
                        Text("Все").tag(String?.none)
                        ForEach(filterFormats, id: \.self) { format in
                            Text(format).tag(Optional(format))
                        }
                    }
                    Picker("Качество", selection: $filter.quality) {
                        Text("Все").tag(LibraryQuality?.none)
                        ForEach(LibraryQuality.allCases) { quality in
                            Text(quality.title).tag(Optional(quality))
                        }
                    }
                    Toggle("Только с обложкой", isOn: $filter.onlyWithArtwork)
                    Toggle("Только пропавшие файлы", isOn: $filter.onlyMissing)
                    Divider()
                    Button("Сбросить фильтры") { filter = LibraryFilter() }
                        .disabled(!filter.isActive)
                } label: {
                    Label("Фильтр", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }

                if !selection.isEmpty {
                    Menu(L10n.format("Действия (%ld)", selection.count)) {
                        Menu("Оценка") {
                            ForEach(0...5, id: \.self) { value in
                                Button(value == 0 ? L10n.string("Без оценки") : String(repeating: "★", count: value)) {
                                    library.setRating(value, for: selection)
                                }
                            }
                        }
                        Menu("Добавить в плейлист") {
                            ForEach(library.playlists) { playlist in
                                Button(playlist.name) { library.add(selection, to: playlist.id) }
                            }
                            if library.playlists.isEmpty { Text("Нет плейлистов") }
                        }
                        Divider()
                        Button("Удалить из библиотеки", role: .destructive) {
                            library.remove(selection)
                            selection.removeAll()
                        }
                    }
                }

                Menu {
                    Picker("Сортировка", selection: $library.sortKey) {
                        ForEach(SortKey.allCases) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    Toggle("По возрастанию", isOn: $library.sortAscending)
                } label: {
                    Label("Сортировка", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .alert("Новая станция", isPresented: $isAddingStation) {
            TextField("Название", text: $stationName)
            TextField("https://адрес/потока", text: $stationURL)
            TextField("Логотип (URL, необязательно)", text: $stationLogoURL)
            Button("Добавить") {
                _ = library.addStation(name: stationName,
                                       urlString: stationURL,
                                       logoURLString: stationLogoURL)
            }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Новый плейлист", isPresented: $isNamingPlaylist) {
            TextField("Название", text: $newPlaylistName)
            Button("Создать") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    let playlist = library.createPlaylist(named: name)
                    sidebarSelection = .playlist(playlist.id)
                }
                newPlaylistName = ""
            }
            Button("Отмена", role: .cancel) { newPlaylistName = "" }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section("Библиотека") {
                Label {
                    HStack {
                        Text("Все треки")
                        Spacer()
                        Text("\(library.tracks.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "music.note.list")
                }
                .tag(SidebarItem.allTracks)
            }

            Section("Умные подборки") {
                ForEach(SmartRule.allCases) { rule in
                    Label(rule.title, systemImage: rule.symbol)
                        .tag(SidebarItem.smart(rule))
                }
            }

            Section {
                ForEach(library.stations) { station in
                    Button {
                        library.ensureStationLogo(station)
                        player?.playRadio(station)
                    } label: {
                        HStack(spacing: Theme.Space.s) {
                            stationIcon(station)
                                .frame(width: 20, height: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(station.name)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Удалить станцию", role: .destructive) {
                            library.removeStation(station.id)
                        }
                    }
                }
                Button {
                    stationName = ""
                    stationURL = ""
                    stationLogoURL = ""
                    isAddingStation = true
                } label: {
                    Label("Добавить станцию…", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } header: {
                Text("Радио")
            }

            Section {
                ForEach(library.playlists) { playlist in
                    Label(playlist.name, systemImage: "music.note")
                        .tag(SidebarItem.playlist(playlist.id))
                        .listRowBackground(
                            dropTargetPlaylist == playlist.id
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear
                        )
                        .onDrop(of: [UTType.text, UTType.fileURL],
                                isTargeted: Binding(
                                    get: { dropTargetPlaylist == playlist.id },
                                    set: { targeted in
                                        if targeted {
                                            dropTargetPlaylist = playlist.id
                                        } else if dropTargetPlaylist == playlist.id {
                                            dropTargetPlaylist = nil
                                        }
                                    })) { providers in
                            handlePlaylistDrop(providers, into: playlist.id)
                        }
                        .contextMenu {
                            Button("Переименовать…") { renamePlaylist(playlist) }
                            Button("Очистить плейлист", role: .destructive) {
                                clearPlaylist(playlist)
                            }
                            .disabled(playlist.trackIDs.isEmpty)
                            Divider()
                            Button("Удалить плейлист…", role: .destructive) {
                                deletePlaylist(playlist)
                            }
                        }
                }
                Button {
                    isNamingPlaylist = true
                } label: {
                    Label("Новый плейлист", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .listRowBackground(
                    isCreatingPlaylistFromDrop ? Color.accentColor.opacity(0.18) : Color.clear
                )
                .help("Можно перетащить папку — плейлист получит её имя")
                .onDrop(of: [UTType.fileURL], isTargeted: $isCreatingPlaylistFromDrop) { providers in
                    loadDroppedURLs(providers) { urls in
                        let folders = urls.filter(isDirectory)
                        guard !folders.isEmpty else {
                            Task { @MainActor in library.statusMessage = L10n.string("Перетащите папку с музыкой") }
                            return
                        }
                        Task { @MainActor in
                            for folder in folders {
                                if let created = await library.importFolderAsPlaylist(folder) {
                                    sidebarSelection = .playlist(created.id)
                                }
                            }
                        }
                    }
                    return true
                }
            } header: {
                Text("Плейлисты")
            }
        }
        .listStyle(.sidebar)
        .onChange(of: sidebarSelection) { _ in
            openAlbum = nil
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if openAlbum != nil {
                Button {
                    openAlbum = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Назад к альбомам")
                .padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(openAlbum?.title ?? currentTitle)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(openAlbum.map { "\($0.artist) · \(summary(for: $0.tracks))" } ?? summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if library.isImporting || library.statusMessage != nil {
                Text(library.statusMessage ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button {
                playAll()
            } label: {
                Label("Играть всё", systemImage: "play.fill")
            }
            .disabled(detailTracks.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var summary: String { summary(for: detailTracks) }

    private func summary(for tracks: [Track]) -> String {
        let duration = tracks.reduce(0) { $0 + ($1.duration.isFinite ? $1.duration : 0) }
        let minutes = Int(duration / 60)
        return L10n.format("%ld трек(ов) · %ld мин", tracks.count, minutes)
    }

    // MARK: List

    private var trackList: some View {
        Group {
            if detailTracks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(detailTracks.enumerated()), id: \.element.id) { index, track in
                            LiveTrackRow(
                                index: index + 1,
                                track: track,
                                isSelected: selection.contains(track.id)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                select(track, index: index)
                            }
                            .onTapGesture(count: 2) {
                                startPlayback(from: index)
                            }
                            .onDrag {
                                NSItemProvider(object: track.id.uuidString as NSString)
                            }
                            .contextMenu {
                                if track.isMissing {
                                    Button("Найти файл…") { locate(track) }
                                    Divider()
                                }
                                Button("Воспроизвести") { startPlayback(from: index) }
                                    .disabled(track.isMissing)
                                Button("Играть следующим") { player?.playNext(track) }
                                Button("Добавить в очередь") { player?.addToQueue([track]) }
                                Divider()
                                Menu("Добавить в плейлист") {
                                    ForEach(library.playlists) { playlist in
                                        Button(playlist.name) {
                                            library.add(actionIDs(containing: track), to: playlist.id)
                                        }
                                    }
                                    if library.playlists.isEmpty {
                                        Text("Нет плейлистов")
                                    }
                                }
                                Menu("Оценка") {
                                    ForEach(0...5, id: \.self) { value in
                                        Button(value == 0 ? L10n.string("Без оценки") : String(repeating: "★", count: value)) {
                                            library.setRating(value, for: actionIDs(containing: track))
                                        }
                                    }
                                }
                                Button("Показать в Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([track.url])
                                }
                                .disabled(track.isMissing)
                                Divider()
                                Button("Удалить из библиотеки", role: .destructive) {
                                    library.remove(actionIDs(containing: track))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Album grid

    private var albumGrid: some View {
        Group {
            if albums.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 200), spacing: 18)],
                              alignment: .leading,
                              spacing: 18) {
                        ForEach(albums) { album in
                            LiveAlbumCard(album: album)
                            .onTapGesture(count: 2) { play(album: album) }
                            .onTapGesture { openAlbum = album }
                            .contextMenu {
                                Button("Воспроизвести") { play(album: album) }
                                Menu("Добавить в плейлист") {
                                    ForEach(library.playlists) { playlist in
                                        Button(playlist.name) {
                                            library.add(Set(album.tracks.map(\.id)), to: playlist.id)
                                        }
                                    }
                                    if library.playlists.isEmpty {
                                        Text("Нет плейлистов")
                                    }
                                }
                                Button("Показать в Finder") {
                                    if let url = album.tracks.first?.url {
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func play(album: AlbumGroup) {
        guard !album.tracks.isEmpty else { return }
        selection = [album.tracks[0].id]
        player?.setQueue(album.tracks, startAt: 0)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Библиотека пуста")
                .font(.headline)
            Text("Перетащите аудиофайлы в окно или нажмите «+», чтобы добавить папку с музыкой.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Добавить файлы…") { library.presentImportPanel(into: selectedPlaylistID) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func playAll() {
        guard !detailTracks.isEmpty else { return }
        startPlayback(from: 0)
    }

    private func select(_ track: Track, index: Int) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(track.id) { selection.remove(track.id) } else { selection.insert(track.id) }
        } else if flags.contains(.shift), let start = lastSelectedIndex {
            let lower = min(start, index)
            let upper = max(start, index)
            if detailTracks.indices.contains(lower), detailTracks.indices.contains(upper) {
                selection = Set(detailTracks[lower...upper].map(\.id))
            }
        } else {
            selection = [track.id]
        }
        lastSelectedIndex = index
    }

    private func actionIDs(containing track: Track) -> Set<UUID> {
        selection.contains(track.id) ? selection : [track.id]
    }

    private func startPlayback(from index: Int) {
        let tracks = detailTracks
        guard tracks.indices.contains(index) else { return }
        selection = [tracks[index].id]
        guard !tracks[index].isMissing else {
            locate(tracks[index])
            return
        }
        player?.setQueue(tracks, startAt: index)
    }

    private func locate(_ track: Track) {
        library.presentReplacePanel(for: track)
    }

    private func loadDroppedURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
    }

    private func importDropped(_ urls: [URL], into playlistID: UUID?) async {
        let folders = urls.filter(isDirectory)
        let files = urls.filter { !isDirectory($0) }

        if let playlistID, library.playlist(with: playlistID) != nil {
            for folder in folders {
                _ = await library.importFolder(folder, into: playlistID)
            }
            if !files.isEmpty {
                await library.importFiles(files, into: playlistID)
            }
            return
        }

        for folder in folders {
            if let created = await library.importFolderAsPlaylist(folder) {
                sidebarSelection = .playlist(created.id)
            }
        }
        if !files.isEmpty {
            await library.importFiles(files)
        }
    }

    private func handlePlaylistDrop(_ providers: [NSItemProvider], into playlistID: UUID) -> Bool {
        dropTargetPlaylist = nil
        let group = DispatchGroup()
        var urls: [URL] = []
        var ids: Set<UUID> = []
        let lock = NSLock()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        lock.lock()
                        urls.append(url)
                        lock.unlock()
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                    if let string = value as? String, let id = UUID(uuidString: string) {
                        lock.lock()
                        ids.insert(id)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            if !ids.isEmpty {
                library.add(ids, to: playlistID)
                if let playlist = library.playlist(with: playlistID) {
                    library.statusMessage = L10n.format("Добавлено в «%@»: %ld", playlist.name, ids.count)
                }
            }
            guard !urls.isEmpty else { return }
            Task { @MainActor in await importDropped(urls, into: playlistID) }
        }
        return true
    }

    private func renamePlaylist(_ playlist: Playlist) {
        let alert = NSAlert()
        alert.messageText = L10n.string("Переименовать плейлист")
        alert.informativeText = L10n.string("Новое название")
        alert.addButton(withTitle: L10n.string("Переименовать"))
        alert.addButton(withTitle: L10n.string("Отмена"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = playlist.name
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.renamePlaylist(playlist.id, to: field.stringValue)
    }

    private func clearPlaylist(_ playlist: Playlist) {
        let alert = NSAlert()
        alert.messageText = L10n.format("Очистить плейлист «%@»?", playlist.name)
        alert.informativeText = L10n.string("Треки останутся в библиотеке.")
        alert.addButton(withTitle: L10n.string("Очистить"))
        alert.addButton(withTitle: L10n.string("Отмена"))
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            library.clearPlaylist(playlist.id)
        }
    }

    private func deletePlaylist(_ playlist: Playlist) {
        let alert = NSAlert()
        alert.messageText = L10n.format("Удалить плейлист «%@»?", playlist.name)
        alert.informativeText = L10n.string("Треки останутся в библиотеке.")
        alert.addButton(withTitle: L10n.string("Удалить"))
        alert.addButton(withTitle: L10n.string("Отмена"))
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            library.delete(playlist)
            if sidebarSelection == .playlist(playlist.id) {
                sidebarSelection = .allTracks
            }
        }
    }

    private func exportTracks(_ format: PlaylistFile.Format) {
        let tracks = detailTracks
        guard !tracks.isEmpty else { return }
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "playlist.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = format == .m3u ? PlaylistFile.m3u(tracks: tracks) : PlaylistFile.pls(tracks: tracks)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            library.statusMessage = L10n.format("Экспортировано: %@", url.lastPathComponent)
        } catch {
            library.statusMessage = L10n.format("Ошибка экспорта: %@", error.localizedDescription)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        loadDroppedURLs(providers) { urls in
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                await importDropped(urls, into: selectedPlaylistID)
            }
        }
        return true
    }
}

/// The row observes the current track itself so the whole list does not redraw.
private struct LiveTrackRow: View {
    @EnvironmentObject private var engine: PlayerEngine
    let index: Int
    let track: Track
    let isSelected: Bool

    var body: some View {
        TrackRow(index: index,
                 track: track,
                 isCurrent: engine.currentTrack?.id == track.id,
                 isPlaying: engine.isPlaying && engine.currentTrack?.id == track.id,
                 isSelected: isSelected)
    }
}

private struct LiveAlbumCard: View {
    @EnvironmentObject private var engine: PlayerEngine
    let album: AlbumGroup

    var body: some View {
        AlbumCard(album: album,
                  isCurrent: engine.currentTrack.map { current in
                      album.tracks.contains { $0.id == current.id }
                  } ?? false)
    }
}

private struct TrackRow: View {
    let index: Int
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("\(index)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24)

            artwork
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Theme.separator, lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(track.displayTitle)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : (track.isMissing ? .secondary : .primary))
                    .lineLimit(1)
                Text(track.displayArtist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.displayAlbum)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            if track.isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Файл не найден")
            }

            Text(track.formatText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .leading)

            Text(track.timeText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
    }

    private var artwork: some View {
        Group {
            if let data = track.artwork, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(nsColor: .quaternaryLabelColor).opacity(0.35)
                    Image(systemName: "music.note")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AlbumCard: View {
    let album: AlbumGroup
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { cover }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isCurrent ? Color.accentColor : Theme.separator,
                                      lineWidth: isCurrent ? 2 : 1)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(album.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(album.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(trackCountText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private var trackCountText: String {
        let count = album.tracks.count
        let minutes = Int((album.duration / 60).rounded())
        return L10n.format("%ld трек(ов) · %ld мин", count, minutes)
    }

    @ViewBuilder
    private var cover: some View {
        if let data = album.artwork, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [Theme.subtle, Theme.background],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                Image(systemName: "square.stack")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
