import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Bottom playlist pane: a compact list inside the player window.
struct PlaylistPane: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var engine: PlayerEngine

    @AppStorage("playlistFilter") private var filterID = "all"
    @AppStorage("sortKey") private var sortKeyRaw = SortKey.added.rawValue
    @AppStorage("playlistSortAscending") private var sortAscending = true
    @State private var search = ""
    @State private var appliedSearch = ""
    @State private var selection: Set<UUID> = []
    @State private var isDropping = false
    @State private var hoveredTrackID: UUID?
    @State private var coverTrack: Track?
    @State private var keyboardTrackID: UUID?
    @FocusState private var listFocused: Bool
    /// For offscreen rendering: ImageRenderer does not show ScrollView content.
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

    private var result: Library.TrackListResult {
        library.query(filterID: filterID,
                      search: appliedSearch,
                      sortKey: SortKey(rawValue: sortKeyRaw) ?? .added,
                      ascending: sortAscending)
    }

    private var tracks: [Track] { result.tracks }

    private var showsArtwork: Bool { result.mixedArtwork }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.separator)
            if tracks.isEmpty {
                emptyState
            } else if scrolling {
                ScrollViewReader { proxy in
                    ScrollView {
                        listContent
                    }
                    .focusable()
                    .focused($listFocused)
                    .modifier(PlaylistFocusRing())
                    .onMoveCommand { direction in
                        moveSelection(direction, proxy: proxy)
                    }
                    .modifier(EnterKeyModifier { playKeyboardSelection() })
                    .onTapGesture { listFocused = true }
                }
            } else {
                listContent
            }
        }
        .frame(width: 425)
        .background(Theme.panel)
        .onAppear { if isShot { search = "" } }
        .task(id: search) {
            if search.isEmpty {
                appliedSearch = ""
                return
            }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            appliedSearch = search
        }
        .sheet(item: $coverTrack) { track in
            CoverPickerSheet(track: track)
                .environmentObject(library)
                .environmentObject(engine)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropping) { providers in
            loadDroppedURLs(providers) { urls in
                guard !urls.isEmpty else { return }
                Task { @MainActor in await importDropped(urls) }
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
                    .id(track.id)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Pane header

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Button(L10n.format("Все треки (%ld)", library.tracks.count)) { filterID = "all" }
                if !library.playlists.isEmpty {
                    Divider()
                    ForEach(library.playlists) { playlist in
                        Button("\(playlist.name) (\(library.tracks(in: playlist).count))") {
                            filterID = playlist.id.uuidString
                        }
                    }
                }
                Divider()
                Menu("Умные подборки") {
                    ForEach(SmartRule.allCases) { rule in
                        Button("\(rule.title) (\(rule.filter(library.tracks).count))") {
                            filterID = "smart:\(rule.rawValue)"
                        }
                    }
                }
                if !library.stations.isEmpty {
                    Divider()
                    Menu("Радио") {
                        ForEach(library.stations) { station in
                            Button(station.name) {
                                library.ensureStationLogo(station)
                                engine.playRadio(station)
                            }
                        }
                    }
                }
                Divider()
                Button("Новый плейлист…") {
                    if let name = promptForName() {
                        let playlist = library.createPlaylist(named: name)
                        filterID = playlist.id.uuidString
                    }
                }
                Button("Импортировать папку как плейлист…") { chooseFolderAsPlaylist() }
                if let playlist = selectedPlaylist {
                    Divider()
                    Button("Переименовать…") { renamePlaylist(playlist) }
                    Button("Очистить плейлист…", role: .destructive) { clearPlaylist(playlist) }
                        .disabled(playlist.trackIDs.isEmpty)
                    Button("Удалить плейлист…", role: .destructive) { deletePlaylist(playlist) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedPlaylist?.name ?? selectedSmart?.title ?? L10n.string("Все треки"))
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
                    // For window snapshots the search field must not intercept input.
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
            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            .frame(height: 26)

            Spacer(minLength: 4)

            Menu {
                Picker("Сортировка", selection: $sortKeyRaw) {
                    ForEach(SortKey.allCases) { key in
                        Text(key.title).tag(key.rawValue)
                    }
                }
                Toggle("По возрастанию", isOn: $sortAscending)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

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
            Text(selectedSmart != nil ? "В подборке пока нет треков" : "Плейлист пуст")
                .font(Theme.Fonts.artist)
                .foregroundStyle(Theme.secondaryText)
            Text(selectedSmart != nil ? "Выберите «Все треки» в меню фильтра" : "Перетащите файлы сюда")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.secondaryText.opacity(0.8))

            if selectedSmart != nil || selectedPlaylist != nil {
                Button("Показать все треки") { filterID = "all" }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Row

    private func row(_ track: Track, index: Int) -> some View {
        let isCurrent = engine.currentTrack?.id == track.id
        let isSelected = selection.contains(track.id)
        let isHovered = hoveredTrackID == track.id

        let isKeyboard = keyboardTrackID == track.id
        let background: Color = isKeyboard
            ? Theme.accent.opacity(0.22)
            : isSelected
            ? Theme.accent.opacity(0.18)
            : (isCurrent ? Theme.accent.opacity(0.10) : (isHovered ? Theme.hover : .clear))

        return HStack(spacing: Theme.Space.s) {
            ZStack {
                if track.isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help("Файл не найден")
                } else if isCurrent {
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
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .strokeBorder(Theme.separator, lineWidth: 0.5)
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(Theme.Fonts.listTitle)
                    .foregroundStyle(track.isMissing ? Theme.secondaryText : (isCurrent ? Theme.accent : Theme.text))
                    .lineLimit(1)
                Text(track.displayArtist)
                    .font(Theme.Fonts.artist)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Space.s)

            if track.isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("Файл не найден")
            }

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(index + 1). \(track.displayTitle), \(track.displayArtist), \(track.timeText)")
        .onTapGesture {
            selection = [track.id]
            keyboardTrackID = track.id
            listFocused = true
        }
        .onTapGesture(count: 2) {
            guard !track.isMissing else {
                library.presentReplacePanel(for: track)
                return
            }
            let list = tracks
            guard let start = list.firstIndex(where: { $0.id == track.id }) else { return }
            engine.setQueue(list, startAt: start)
        }
        .contextMenu {
            if track.isMissing {
                Button("Найти файл…") { library.presentReplacePanel(for: track) }
                Divider()
            }
            Button("Воспроизвести") {
                let list = tracks
                if let start = list.firstIndex(where: { $0.id == track.id }) {
                    engine.setQueue(list, startAt: start)
                }
            }
            .disabled(track.isMissing)
            Button("Играть следующим") { engine.playNext(track) }
            Button("Добавить в очередь") { engine.addToQueue([track]) }
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
            .disabled(track.isMissing)
            Divider()
            Button("Удалить из библиотеки", role: .destructive) {
                library.remove([track.id])
            }
        }
    }

    @ViewBuilder
    private func artwork(_ track: Track) -> some View {
        if let image = track.artworkID.flatMap({ ArtworkCache.shared.image(for: $0) })
            ?? track.artwork.flatMap({ NSImage(data: $0) }) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Theme.subtle
                Image(systemName: "music.note")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText.opacity(0.8))
            }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        guard !tracks.isEmpty else { return }
        let currentID = keyboardTrackID ?? selection.first
        let current = currentID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? -1
        let next: Int
        switch direction {
        case .up:
            next = current <= 0 ? 0 : current - 1
        case .down:
            next = current < 0 ? 0 : min(tracks.count - 1, current + 1)
        default:
            return
        }
        let track = tracks[next]
        keyboardTrackID = track.id
        selection = [track.id]
        withAnimation(.easeInOut(duration: 0.12)) {
            proxy.scrollTo(track.id, anchor: .center)
        }
    }

    private func playKeyboardSelection() {
        guard let id = keyboardTrackID ?? selection.first,
              let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        engine.setQueue(tracks, startAt: index)
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

    private func importDropped(_ urls: [URL]) async {
        let folders = urls.filter(isDirectory)
        let files = urls.filter { !isDirectory($0) }

        if let playlist = selectedPlaylist {
            for folder in folders {
                _ = await library.importFolder(folder, into: playlist.id)
            }
            if !files.isEmpty {
                await library.importFiles(files, into: playlist.id)
            }
            return
        }

        var created: Playlist?
        for folder in folders {
            if let playlist = await library.importFolderAsPlaylist(folder) {
                created = playlist
            }
        }
        if !files.isEmpty {
            await library.importFiles(files)
        }
        if let created {
            filterID = created.id.uuidString
        }
    }

    private func chooseFolderAsPlaylist() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = L10n.string("Плейлист получит имя папки")
        panel.prompt = L10n.string("Импортировать")
        guard panel.runModal() == .OK else { return }
        let folders = panel.urls
        Task { @MainActor in
            var last: Playlist?
            for folder in folders {
                if let playlist = await library.importFolderAsPlaylist(folder) {
                    last = playlist
                }
            }
            if let last {
                filterID = last.id.uuidString
            }
        }
    }

    private func promptForName(title: String = L10n.string("Новый плейлист"),
                               message: String = L10n.string("Введите название"),
                               value: String = "",
                               button: String = L10n.string("Создать")) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: L10n.string("Отмена"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Название"
        field.stringValue = value
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private func renamePlaylist(_ playlist: Playlist) {
        guard let name = promptForName(title: L10n.string("Переименовать плейлист"),
                                       message: L10n.string("Новое название"),
                                       value: playlist.name,
                                       button: L10n.string("Переименовать")) else { return }
        library.renamePlaylist(playlist.id, to: name)
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
            filterID = "all"
        }
    }
}


/// Keeps keyboard focus on the list without the blue system focus ring.
private struct PlaylistFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content.background(FocusRingDisabler())
        }
    }
}

private struct FocusRingDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            var candidate = view.superview
            while let current = candidate {
                if let scroll = current as? NSScrollView {
                    scroll.focusRingType = .none
                    break
                }
                candidate = current.superview
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Enter in the list: intercept the key on macOS 14+, leave it alone on 13.
private struct EnterKeyModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 14.0, *) {
                content.onKeyPress(.return) {
                    action()
                    return .handled
                }
            } else {
                content
            }
        }
    }
}
