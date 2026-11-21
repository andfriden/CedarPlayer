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
    @State private var hoveredTrackID: UUID?
    @State private var coverTrack: Track?
    /// Для офскрин-отрисовки: ImageRenderer не показывает содержимое ScrollView.
    var scrolling = true

    private var isShot: Bool {
        ProcessInfo.processInfo.environment["CEDAR_WINDOW_SHOT"] != nil
    }

    private var selectedPlaylist: Playlist? {
        filterID == "all" ? nil : library.playlists.first { $0.id.uuidString == filterID }
    }

    private var selectedSmart: SmartRule? {
        guard filterID.hasPrefix("smart:") else { return nil }
        return SmartRule(rawValue: String(filterID.dropFirst(6)))
    }

    private var tracks: [Track] {
        var list: [Track]
        if let playlist = selectedPlaylist {
            list = library.tracks(in: playlist)
        } else {
            list = library.tracks
        }
        if let selectedSmart {
            list = selectedSmart.filter(list)
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
            Divider().overlay(Theme.separator)
            if tracks.isEmpty {
                emptyState
            } else if scrolling {
                ScrollView {
                    listContent
                }
            } else {
                listContent
            }
        }
        .frame(width: 425)
        .background(Theme.panel)
        .onAppear { if isShot { search = "" } }
        .sheet(item: $coverTrack) { track in
            CoverPickerSheet(track: track)
                .environmentObject(library)
                .environmentObject(engine)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropping) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in library.importURLs([url], into: selectedPlaylist?.id) }
                }
            }
            return true
        }
        .overlay {
            if isDropping {
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    private var listContent: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                row(track, index: index)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Заголовок панели

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Все треки") { filterID = "all" }
                Divider()
                ForEach(SmartRule.allCases) { rule in
                    Button(rule.title) { filterID = "smart:\(rule.rawValue)" }
                }
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
                    Text(selectedPlaylist?.name ?? selectedSmart?.title ?? "Все треки")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: 120)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                if isShot {
                    // Для снимка окна поле поиска не должно перехватывать ввод.
                    Text("Поиск")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(height: 26, alignment: .leading)
                } else {
                    TextField("Поиск", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(height: 26)
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .background(Color(hex: 0x2B2F36), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            .frame(height: 26)

            Spacer(minLength: 4)

            Text("\(tracks.count)")
                .font(Theme.Fonts.captionMono)
                .foregroundStyle(Theme.secondaryText)

            Button {
                library.presentImportPanel(into: selectedPlaylist?.id)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Добавить файлы (⌘O)")
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("Плейлист пуст")
                .font(Theme.Fonts.artist)
                .foregroundStyle(Theme.secondaryText)
            Text("Перетащите файлы сюда")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.secondaryText.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Строка

    /// Обложки в строках нужны, только когда список смешивает разные альбомы.
    private var showsArtwork: Bool {
        let withArtwork = tracks.filter { $0.artwork != nil }
        guard withArtwork.count > 1 else { return false }
        return Set(withArtwork.map(coverSignature)).count > 1
    }

    private func coverSignature(_ track: Track) -> String {
        if let id = track.artworkID { return id }
        return "\(track.album)|\(track.albumArtist)|\(track.artist)"
    }

    private func row(_ track: Track, index: Int) -> some View {
        let isCurrent = engine.currentTrack?.id == track.id
        let isSelected = selection.contains(track.id)
        let isHovered = hoveredTrackID == track.id

        let background: Color = isSelected
            ? Theme.accent.opacity(0.18)
            : (isCurrent ? Theme.accent.opacity(0.10) : (isHovered ? Theme.hover : .clear))

        return HStack(spacing: Theme.Space.s) {
            ZStack {
                if isCurrent {
                    Image(systemName: engine.isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("\(index + 1)")
                        .font(Theme.Fonts.captionMono)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(width: 20)

            if showsArtwork {
                artwork(track)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(Theme.Fonts.listTitle)
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.text)
                    .lineLimit(1)
                Text(track.displayArtist)
                    .font(Theme.Fonts.artist)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Space.s)

            if track.rating > 0, !showsArtwork {
                Text(String(repeating: "★", count: track.rating))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.accent.opacity(0.9))
            }

            Text(track.timeText)
                .font(Theme.Fonts.timeMono)
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 42)
        .background(background)
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 2)
                    .padding(.vertical, 10)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredTrackID = track.id
            } else if hoveredTrackID == track.id {
                hoveredTrackID = nil
            }
        }
        .help(track.extendedInfoText)
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
            Menu("Оценка") {
                ForEach(0...5, id: \.self) { value in
                    Button(value == 0 ? "Без оценки" : String(repeating: "★", count: value)) {
                        library.setRating(value, for: [track.id])
                    }
                }
            }
            Button("Найти обложку в базе…") { coverTrack = track }
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
                Color(hex: 0x2B2F36)
                Image(systemName: "music.note")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText.opacity(0.8))
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
