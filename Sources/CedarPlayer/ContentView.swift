import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var engine: PlayerEngine

    @State private var selection: Set<UUID> = []
    @State private var sidebarSelection: SidebarItem? = .allTracks
    @State private var newPlaylistName = ""
    @State private var isNamingPlaylist = false
    @State private var isDropping = false
    @State private var openAlbum: AlbumGroup?
    @AppStorage("libraryLayout") private var layout = "list"

    enum SidebarItem: Hashable {
        case allTracks
        case smart(SmartRule)
        case playlist(UUID)
    }

    private var displayedTracks: [Track] {
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

    private var selectedPlaylistID: UUID? {
        if case .playlist(let id) = sidebarSelection { return id }
        return nil
    }

    private var detailTracks: [Track] { openAlbum?.tracks ?? displayedTracks }

    private var albums: [AlbumGroup] { AlbumGroup.group(displayedTracks) }

    private var currentTitle: String {
        switch sidebarSelection {
        case .playlist(let id): return library.playlist(with: id)?.name ?? "Плейлист"
        case .smart(let rule): return rule.title
        default: return "Все треки"
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

    // MARK: Сайдбар

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
                ForEach(library.playlists) { playlist in
                    Label(playlist.name, systemImage: "music.note")
                        .tag(SidebarItem.playlist(playlist.id))
                        .contextMenu {
                        Button("Удалить плейлист", role: .destructive) {
                            library.delete(playlist)
                            if sidebarSelection == .playlist(playlist.id) {
                                sidebarSelection = .allTracks
                            }
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
            } header: {
                Text("Плейлисты")
            }
        }
        .listStyle(.sidebar)
        .onChange(of: sidebarSelection) { _ in
            openAlbum = nil
        }
    }

    // MARK: Заголовок

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
        return "\(tracks.count) трек(ов) · \(minutes) мин"
    }

    // MARK: Список

    private var trackList: some View {
        Group {
            if detailTracks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(detailTracks.enumerated()), id: \.element.id) { index, track in
                            TrackRow(
                                index: index + 1,
                                track: track,
                                isCurrent: engine.currentTrack?.id == track.id,
                                isPlaying: engine.isPlaying && engine.currentTrack?.id == track.id,
                                isSelected: selection.contains(track.id)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = [track.id]
                            }
                            .onTapGesture(count: 2) {
                                startPlayback(from: index)
                            }
                            .contextMenu {
                                Button("Воспроизвести") { startPlayback(from: index) }
                                Divider()
                                Menu("Добавить в плейлист") {
                                    ForEach(library.playlists) { playlist in
                                        Button(playlist.name) {
                                            library.add([track.id], to: playlist.id)
                                        }
                                    }
                                    if library.playlists.isEmpty {
                                        Text("Нет плейлистов")
                                    }
                                }
                                Menu("Оценка") {
                                    ForEach(0...5, id: \.self) { value in
                                        Button(value == 0 ? "Без оценки" : String(repeating: "★", count: value)) {
                                            library.setRating(value, for: [track.id])
                                        }
                                    }
                                }
                                Button("Показать в Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([track.url])
                                }
                                Divider()
                                Button("Удалить из библиотеки", role: .destructive) {
                                    library.remove([track.id])
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

    // MARK: Сетка альбомов

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
                            AlbumCard(album: album,
                                      isCurrent: engine.currentTrack.map { current in
                                          album.tracks.contains { $0.id == current.id }
                                      } ?? false)
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
        engine.setQueue(album.tracks, startAt: 0)
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

    // MARK: Действия

    private func playAll() {
        guard !detailTracks.isEmpty else { return }
        startPlayback(from: 0)
    }

    private func startPlayback(from index: Int) {
        let tracks = detailTracks
        guard tracks.indices.contains(index) else { return }
        selection = [tracks[index].id]
        engine.setQueue(tracks, startAt: index)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    library.importURLs([url], into: selectedPlaylistID)
                }
            }
        }
        return true
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

            VStack(alignment: .leading, spacing: 1) {
                Text(track.displayTitle)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
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
                        .strokeBorder(isCurrent ? Color.accentColor : Color.white.opacity(0.07),
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
        return "\(count) трек(ов) · \(minutes) мин"
    }

    @ViewBuilder
    private var cover: some View {
        if let data = album.artwork, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.13)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                Image(systemName: "square.stack")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
