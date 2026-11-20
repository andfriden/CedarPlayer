import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Нижняя панель плейлиста: компактный список внутри окна плеера.
struct PlaylistPane: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var engine: PlayerEngine

    @AppStorage("playlistFilter") private var filterID = "all"
    @AppStorage("sortKey") private var sortKeyRaw = SortKey.added.rawValue
    @State private var search = ""
    @State private var selection: Set<UUID> = []
    @State private var isDropping = false

    private var selectedPlaylist: Playlist? {
        filterID == "all" ? nil : library.playlists.first { $0.id.uuidString == filterID }
    }

    private var tracks: [Track] {
        var list: [Track]
        if let playlist = selectedPlaylist {
            list = library.tracks(in: playlist)
        } else {
            list = library.tracks
        }
        let sortKey = SortKey(rawValue: sortKeyRaw) ?? .added
        switch sortKey {
        case .added: list.sort { $0.addedAt < $1.addedAt }
        case .title: list.sort { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        case .artist: list.sort { $0.displayArtist.localizedStandardCompare($1.displayArtist) == .orderedAscending }
        case .album: list.sort { $0.displayAlbum.localizedStandardCompare($1.displayAlbum) == .orderedAscending }
        case .duration: list.sort { $0.duration < $1.duration }
        }
        guard !search.isEmpty else { return list }
        let needle = search.lowercased()
        return list.filter {
            $0.displayTitle.lowercased().contains(needle)
            || $0.artist.lowercased().contains(needle)
            || $0.album.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.08))
            if tracks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            row(track, index: index)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 425)
        .background(Color(white: 0.075))
        .onDrop(of: [.fileURL], isTargeted: $isDropping) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in library.importURLs([url]) }
                }
            }
            return true
        }
        .overlay {
            if isDropping {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Заголовок панели

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Все треки") { filterID = "all" }
                Divider()
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) { filterID = playlist.id.uuidString }
                }
                Divider()
                Button("Новый плейлист…") {
                    if let name = promptForName() {
                        let playlist = library.createPlaylist(named: name)
                        filterID = playlist.id.uuidString
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedPlaylist?.name ?? "Все треки")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 120)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                TextField("Поиск", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(height: 24)
            }
            .padding(.horizontal, 6)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            .frame(height: 24)

            Spacer(minLength: 4)

            Text("\(tracks.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            Button {
                library.presentImportPanel()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Добавить файлы (⌘O)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("Плейлист пуст")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Перетащите файлы сюда")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Строка

    private func row(_ track: Track, index: Int) -> some View {
        let isCurrent = engine.currentTrack?.id == track.id
        return HStack(spacing: 8) {
            ZStack {
                if isCurrent && engine.isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)

            artwork(track)
                .frame(width: 35, height: 35)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text(track.displayTitle)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : .white.opacity(0.92))
                    .lineLimit(1)
                Text(track.displayArtist)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(track.timeText)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(height: 38)
        .padding(.horizontal, 10)
        .background(selection.contains(track.id) ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .help(track.qualityText)
        .onTapGesture { selection = [track.id] }
        .onTapGesture(count: 2) {
            let list = tracks
            guard let start = list.firstIndex(where: { $0.id == track.id }) else { return }
            engine.setQueue(list, startAt: start)
        }
        .contextMenu {
            Button("Воспроизвести") {
                let list = tracks
                if let start = list.firstIndex(where: { $0.id == track.id }) {
                    engine.setQueue(list, startAt: start)
                }
            }
            Menu("Добавить в плейлист") {
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) { library.add([track.id], to: playlist.id) }
                }
                if library.playlists.isEmpty { Text("Нет плейлистов") }
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

    @ViewBuilder
    private func artwork(_ track: Track) -> some View {
        if let data = track.artwork, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.white.opacity(0.07)
                Image(systemName: "music.note")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    private func promptForName() -> String? {
        let alert = NSAlert()
        alert.messageText = "Новый плейлист"
        alert.informativeText = "Введите название"
        alert.addButton(withTitle: "Создать")
        alert.addButton(withTitle: "Отмена")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Название"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
