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
    @State private var editingSmart: SmartCollection?
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

    private var selectedCustomSmart: SmartCollection? {
        guard filterID.hasPrefix("smartset:"),
              let id = UUID(uuidString: String(filterID.dropFirst(9))) else { return nil }
        return library.smartCollection(with: id)
    }

    private var currentTitle: String {
        selectedPlaylist?.name
            ?? selectedSmart?.title
            ?? selectedCustomSmart?.name
            ?? L10n.string("Все треки")
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
            columnHeader
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
        .frame(minHeight: 240)
        .background(Theme.Cyber.background)
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
        .sheet(item: $editingSmart) { collection in
            SmartCollectionEditor(collection: collection) { saved in
                library.upsertSmartCollection(saved)
                filterID = "smartset:\(saved.id.uuidString)"
            }
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
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                row(track, index: index)
                    .id(track.id)
            }
        }
    }

    // MARK: Table chrome

    private let indexWidth: CGFloat = 36
    private let ratingWidth: CGFloat = 70
    private let durationWidth: CGFloat = 80

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("#")
                .frame(width: indexWidth, alignment: .center)
            Text(L10n.string("Название"))
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
            Text(L10n.string("Исполнитель"))
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            Text(L10n.string("Рейтинг"))
                .frame(width: ratingWidth, alignment: .center)
            Text(L10n.string("Длительность"))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: durationWidth, alignment: .trailing)
                .minimumScaleFactor(0.75)
        }
        .textCase(.uppercase)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(Theme.Cyber.tertiaryText)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Theme.Cyber.background)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text("\(tracks.count) треков | \(totalTimeText)")
            Spacer(minLength: 0)
            Text("Размер: \(totalSizeText)")
        }
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(Theme.Cyber.tertiaryText)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Theme.Cyber.statusBackground)
    }

    private var totalTimeText: String {
        let total = Int(result.totalDuration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) ч. \(minutes) мин." }
        return "\(minutes) мин."
    }

    private var totalSizeText: String {
        let bytes = result.totalSize
        if bytes >= 1_000_000_000 { return String(format: "%.1f ГБ", bytes / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.1f МБ", bytes / 1_000_000) }
        return String(format: "%.0f КБ", bytes / 1_000)
    }

    // MARK: Pane header

    private var header: some View {
        HStack(spacing: 6) {
            if isSnapshot {
                HStack(spacing: 4) {
                    Text(currentTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Cyber.text)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Cyber.tertiaryText)
                }
                .frame(width: 96, alignment: .leading)
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
                        if !library.smartCollections.isEmpty {
                            Divider()
                            ForEach(library.smartCollections) { collection in
                                Button("\(collection.name) (\(collection.filter(library.tracks).count))") {
                                    filterID = "smartset:\(collection.id.uuidString)"
                                }
                            }
                        }
                        Divider()
                        Button(L10n.string("Новая умная подборка…")) {
                            editingSmart = SmartCollection(name: L10n.string("Новая подборка"))
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
                    Button(L10n.string("Сохранить плейлист…")) { savePlaylist() }
                        .disabled(tracks.isEmpty)
                    if let playlist = selectedPlaylist {
                        Divider()
                        Button(L10n.string("Переименовать…")) { renamePlaylist(playlist) }
                        Button(L10n.string("Очистить плейлист…"), role: .destructive) { clearPlaylist(playlist) }
                            .disabled(playlist.trackIDs.isEmpty)
                        Button(L10n.string("Удалить плейлист…"), role: .destructive) { deletePlaylist(playlist) }
                    }
                    if let collection = selectedCustomSmart {
                        Divider()
                        Button(L10n.string("Изменить умную подборку…")) { editingSmart = collection }
                        Button(L10n.string("Удалить умную подборку…"), role: .destructive) {
                            library.removeSmartCollection(collection.id)
                            filterID = "all"
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currentTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Cyber.text)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.Cyber.tertiaryText)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 96, alignment: .leading)
                .help(L10n.string("Выбрать плейлист или подборку"))
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Cyber.accent.opacity(0.85))
                    .frame(width: 14, height: 14)
                if isSnapshot {
                    Text(L10n.string("Поиск"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Cyber.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(L10n.string("Поиск"), text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 220)
            .frame(height: 28)
            .background(Theme.Cyber.inset.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.8)
            }

            Spacer(minLength: 0)

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
                    .foregroundStyle(Theme.Cyber.tertiaryText)
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
                        .foregroundStyle(Theme.Cyber.tertiaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(L10n.string("Сортировка"))
            }
        }
        .frame(height: 36)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(height: 44)
        .background(Theme.Cyber.background)
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
        let foreground = Theme.Cyber.text
        let secondary = Theme.Cyber.secondaryText
        let background: Color = isCurrent
            ? Theme.Cyber.accent.opacity(0.14)
            : isSelected
            ? Theme.Cyber.accent.opacity(0.16)
            : (isHovered ? Theme.Cyber.hover : .clear)

        return HStack(spacing: 0) {
            ZStack {
                if track.isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(isCurrent ? Color.black.opacity(0.7) : Theme.Cyber.warning)
                } else if isCurrent {
                    Image(systemName: engine.isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.Cyber.accent)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(secondary)
                        .monospacedDigit()
                }
            }
            .frame(width: indexWidth, alignment: .center)

            Text(track.displayTitle)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)

            Text(track.displayArtist)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(secondary)
                .lineLimit(1)
                .frame(minWidth: 96, maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        rate(track, value: value)
                    } label: {
                        Image(systemName: value <= track.rating ? "star.fill" : "star")
                            .font(.system(size: 10))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(value <= track.rating
                                             ? Theme.Cyber.accent
                                             : secondary.opacity(0.35))
                            .frame(width: 12, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(track.rating == value
                          ? L10n.string("Снять оценку")
                          : L10n.format("Оценка: %ld", value))
                }
            }
            .frame(width: ratingWidth, alignment: .center)

            Text(track.timeText)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(secondary)
                .monospacedDigit()
                .frame(width: durationWidth, alignment: .trailing)
                .padding(.trailing, 12)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(background, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(alignment: .leading) {
            if isCurrent {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Theme.Cyber.accent)
                    .frame(width: 2, height: 18)
                    .padding(.leading, 4)
            }
        }
        .overlay {
            if isSelected && !isCurrent {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Theme.Cyber.accent.opacity(0.55), lineWidth: 0.8)
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

    private func rate(_ track: Track, value: Int) {
        let rating = track.rating == value ? 0 : value
        let ids = selection.contains(track.id) ? selection : [track.id]
        library.setRating(rating, for: ids)
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
