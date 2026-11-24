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

    /// Offscreen rendering cannot host AppKit-backed menus and text fields.
    private var isSnapshot: Bool { isShot || !scrolling }

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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.Cyber.separator)
            columnHeader
            Divider().overlay(Theme.Cyber.separator.opacity(0.7))
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
                    .frame(maxHeight: .infinity)
                }
            } else {
                listContent
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Cyber.panel)
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
                    .strokeBorder(Theme.Cyber.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    private var listContent: some View {
        LazyVStack(spacing: 1) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                row(track, index: index)
                    .id(track.id)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: Table chrome

    private let indexWidth: CGFloat = 26
    private let artistWidth: CGFloat = 90
    private let albumWidth: CGFloat = 78
    private let durationWidth: CGFloat = 80
    private let ratingWidth: CGFloat = 52
    private let columnGap: CGFloat = 6

    private var columnHeader: some View {
        HStack(spacing: columnGap) {
            Text("#")
                .frame(width: indexWidth, alignment: .trailing)
            Text(L10n.string("Название"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.string("Исполнитель"))
                .frame(width: artistWidth, alignment: .leading)
            Text(L10n.string("Альбом"))
                .frame(width: albumWidth, alignment: .leading)
            Text(L10n.string("Длительность"))
                .frame(width: durationWidth, alignment: .trailing)
            Text(L10n.string("Рейтинг"))
                .frame(width: ratingWidth, alignment: .trailing)
        }
        .font(Theme.Fonts.captionMono)
        .foregroundStyle(Theme.Cyber.secondaryText)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Theme.Cyber.titleBar.opacity(0.55))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(L10n.format("%ld треков", tracks.count))
            Spacer(minLength: 0)
            Text(totalTimeText)
        }
        .font(Theme.Fonts.captionMono)
        .foregroundStyle(Theme.Cyber.secondaryText)
        .padding(.horizontal, 12)
        .frame(height: 25)
        .background(Theme.Cyber.titleBar.opacity(0.65))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Cyber.separator.opacity(0.7)).frame(height: 1)
        }
    }

    private var totalTimeText: String {
        let total = Int(tracks.reduce(0) { $0 + max(0, $1.duration) }.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Pane header

    private var header: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                if isSnapshot {
                    HStack(spacing: 5) {
                        Text(selectedPlaylist?.name ?? selectedSmart?.title ?? L10n.string("Все треки"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.Cyber.text)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.Cyber.secondaryText)
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                } else {
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
                        Menu(L10n.string("Умные подборки")) {
                            ForEach(SmartRule.allCases) { rule in
                                Button("\(rule.title) (\(rule.filter(library.tracks).count))") {
                                    filterID = "smart:\(rule.rawValue)"
                                }
                            }
                        }
                        if !library.stations.isEmpty {
                            Divider()
                            Menu(L10n.string("Радио")) {
                                ForEach(library.stations) { station in
                                    Button(station.name) {
                                        library.ensureStationLogo(station)
                                        engine.playRadio(station)
                                    }
                                }
                            }
                        }
                        Divider()
                        Button(L10n.string("Новый плейлист…")) {
                            if let name = promptForName() {
                                let playlist = library.createPlaylist(named: name)
                                filterID = playlist.id.uuidString
                            }
                        }
                        Button(L10n.string("Импортировать папку как плейлист…")) { chooseFolderAsPlaylist() }
                        if let playlist = selectedPlaylist {
                            Divider()
                            Button(L10n.string("Переименовать…")) { renamePlaylist(playlist) }
                            Button(L10n.string("Очистить плейлист…"), role: .destructive) { clearPlaylist(playlist) }
                                .disabled(playlist.trackIDs.isEmpty)
                            Button(L10n.string("Удалить плейлист…"), role: .destructive) { deletePlaylist(playlist) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(selectedPlaylist?.name ?? selectedSmart?.title ?? L10n.string("Все треки"))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.Cyber.text)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Theme.Cyber.secondaryText)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(maxWidth: 220, alignment: .leading)
                    .help(L10n.string("Выбрать плейлист или подборку"))
                }

                Spacer(minLength: Theme.Space.s)

                Text("\(tracks.count)")
                    .font(Theme.Fonts.captionMono)
                    .foregroundStyle(Theme.Cyber.accent)

                CyberIconButton(symbol: "plus", help: L10n.string("Добавить файлы (⌘O)")) {
                    library.presentImportPanel(into: selectedPlaylist?.id)
                }
                CyberIconButton(symbol: "trash", help: L10n.string("Удалить выбранные")) {
                    deleteSelection()
                }
                .opacity(selection.isEmpty ? 0.4 : 1)
                .disabled(selection.isEmpty)

                if isSnapshot {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Cyber.secondaryText)
                        .frame(width: 28, height: 28)
                } else {
                    Menu {
                        Picker(L10n.string("Сортировка"), selection: $sortKeyRaw) {
                            ForEach(SortKey.allCases) { key in
                                Text(key.title).tag(key.rawValue)
                            }
                        }
                        Toggle(L10n.string("По возрастанию"), isOn: $sortAscending)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.Cyber.secondaryText)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help(L10n.string("Сортировка"))
                }

                CyberIconButton(symbol: "square.and.arrow.down", help: L10n.string("Сохранить плейлист…")) {
                    savePlaylist()
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Cyber.accent.opacity(0.85))
                if isSnapshot {
                    Text(L10n.string("Поиск"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Cyber.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 26)
                } else {
                    TextField(L10n.string("Поиск"), text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 26)
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(maxWidth: .infinity)
            .background(Theme.Cyber.inset.opacity(0.85), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small)
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.8)
            }
            .frame(height: 28)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.Cyber.panel)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text(selectedSmart != nil ? "В подборке пока нет треков" : "Плейлист пуст")
                .font(Theme.Fonts.artist)
                .foregroundStyle(Theme.Cyber.secondaryText)
            Text(selectedSmart != nil ? "Выберите «Все треки» в меню фильтра" : "Перетащите файлы сюда")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Cyber.secondaryText.opacity(0.8))

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
        let foreground = isCurrent ? Color(hex: 0x17171A) : Theme.Cyber.text
        let secondary = isCurrent ? Color.black.opacity(0.62) : Theme.Cyber.secondaryText
        let background: Color = isCurrent
            ? Theme.Cyber.accent
            : isSelected
            ? Theme.Cyber.accent.opacity(0.16)
            : (isHovered ? Theme.Cyber.hover : .clear)

        return HStack(spacing: columnGap) {
            HStack(spacing: 3) {
                if track.isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(isCurrent ? Color.black.opacity(0.7) : Theme.Cyber.warning)
                } else if isCurrent {
                    Image(systemName: engine.isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(foreground)
                }
                Text("\(index + 1)")
                    .font(Theme.Fonts.captionMono)
                    .foregroundStyle(secondary)
                    .monospacedDigit()
            }
            .frame(width: indexWidth, alignment: .trailing)

            Text(track.displayTitle)
                .font(Theme.Fonts.listTitle)
                .foregroundStyle(foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.displayArtist)
                .font(Theme.Fonts.artist)
                .foregroundStyle(secondary)
                .lineLimit(1)
                .frame(width: artistWidth, alignment: .leading)

            Text(track.displayAlbum)
                .font(Theme.Fonts.artist)
                .foregroundStyle(secondary)
                .lineLimit(1)
                .frame(width: albumWidth, alignment: .leading)

            Text(track.timeText)
                .font(Theme.Fonts.timeMono)
                .foregroundStyle(secondary)
                .monospacedDigit()
                .frame(width: durationWidth, alignment: .trailing)

            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { value in
                    Image(systemName: value <= track.rating ? "star.fill" : "star")
                        .font(.system(size: 9))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(value <= track.rating
                                         ? (isCurrent ? Color.black : Theme.Cyber.accent)
                                         : (isCurrent ? Color.black.opacity(0.75) : secondary.opacity(0.35)))
                }
            }
            .frame(width: ratingWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            if isSelected && !isCurrent {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Theme.Cyber.accent.opacity(0.55), lineWidth: 0.8)
            }
        }
        .padding(.horizontal, 4)
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
        .modifier(TrackReorderDrop(
            enabled: !isSnapshot,
            trackID: track.id,
            targetID: track.id,
            playlist: selectedPlaylist,
            onDrop: { movedID in
                guard let playlist = selectedPlaylist else { return }
                library.moveTrack(in: playlist.id, movedID, before: track.id)
                sortKeyRaw = SortKey.manual.rawValue
                sortAscending = true
            }
        ))
        .contextMenu {
            if track.isMissing {
                Button(L10n.string("Найти файл…")) { library.presentReplacePanel(for: track) }
                Divider()
            }
            Button(L10n.string("Воспроизвести")) {
                let list = tracks
                if let start = list.firstIndex(where: { $0.id == track.id }) {
                    engine.setQueue(list, startAt: start)
                }
            }
            .disabled(track.isMissing)
            Button(L10n.string("Играть следующим")) { engine.playNext(track) }
            Button(L10n.string("Добавить в очередь")) { engine.addToQueue([track]) }
            Menu(L10n.string("Добавить в плейлист")) {
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) { library.add([track.id], to: playlist.id) }
                }
                if library.playlists.isEmpty { Text(L10n.string("Нет плейлистов")) }
            }
            Menu(L10n.string("Оценка")) {
                ForEach(0...5, id: \.self) { value in
                    Button(value == 0 ? L10n.string("Без оценки") : String(repeating: "★", count: value)) {
                        library.setRating(value, for: [track.id])
                    }
                }
            }
            Button(L10n.string("Найти обложку в базе…")) { coverTrack = track }
            Button(L10n.string("Показать в Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([track.url])
            }
            .disabled(track.isMissing)
            Divider()
            Button(L10n.string("Удалить из библиотеки"), role: .destructive) {
                library.remove([track.id])
            }
        }
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        if let playlist = selectedPlaylist {
            library.remove(selection, from: playlist.id)
        } else {
            library.remove(selection)
        }
        selection.removeAll()
        listFocused = true
    }

    private func savePlaylist() {
        guard !tracks.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u") ?? .plainText]
        panel.nameFieldStringValue = "\(selectedPlaylist?.name ?? L10n.string("Плейлист")).m3u"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = PlaylistFile.m3u(tracks: tracks)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            library.statusMessage = L10n.format("Экспортировано: %@", url.lastPathComponent)
        } catch {
            library.statusMessage = L10n.format("Ошибка сохранения: %@", error.localizedDescription)
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


/// Drag reorder for playlist rows; disabled for offscreen snapshots.
private struct TrackReorderDrop: ViewModifier {
    let enabled: Bool
    let trackID: UUID
    let targetID: UUID
    let playlist: Playlist?
    let onDrop: (UUID) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled, playlist != nil {
            content
                .onDrag { NSItemProvider(object: trackID.uuidString as NSString) }
                .onDrop(of: [.text], isTargeted: nil) { providers in
                    guard let provider = providers.first else { return false }
                    provider.loadObject(ofClass: NSString.self) { object, _ in
                        guard let raw = object as? String, let movedID = UUID(uuidString: raw) else { return }
                        DispatchQueue.main.async { onDrop(movedID) }
                    }
                    return true
                }
        } else {
            content
        }
    }
}
