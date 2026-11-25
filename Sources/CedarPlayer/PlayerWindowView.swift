import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Lyrics window: loads sidecar .lrc files, downloads them from LRCLIB and
/// highlights the line matching the current playback position.
struct LyricsView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @AppStorage("autoDownloadLyrics") private var autoDownloadLyrics = true
    @State private var text = ""
    @State private var loadedTrackID: UUID?
    @State private var status = ""
    @State private var isEditing = false
    @State private var isDownloading = false
    @State private var isSearchingVariants = false
    @State private var variants: [LyricsCandidate] = []
    @State private var showVariants = false
    @State private var parsedLines: [LRCLine] = []
    @State private var currentLineIndex: Int?
    @State private var offset: TimeInterval = 0
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(engine.currentTrack?.displayTitle ?? L10n.string("Нет трека"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                Button(L10n.string("Скачать .lrc")) { downloadLyrics() }
                    .disabled(engine.currentTrack == nil || isDownloading)
                Button(L10n.string("Варианты…")) { searchVariants() }
                    .disabled(engine.currentTrack == nil || isSearchingVariants)
                Button(L10n.string("Загрузить .lrc")) { openLyrics() }
                Button(isEditing ? L10n.string("Готово") : L10n.string("Редактировать")) {
                    toggleEditing()
                }
                Spacer()
                if isDownloading || isSearchingVariants { ProgressView().controlSize(.small) }
            }

            Group {
                if isEditing {
                    editor
                } else {
                    lyricsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                if isEditing {
                    Button(L10n.string("Сохранить")) { saveLyrics() }
                }
                Stepper(value: $offset, in: -5...5, step: 0.5) {
                    Text(offsetText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Text(L10n.string("Формат: [мм:сс.xx] строка"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.Space.l)
        .frame(minWidth: 460, minHeight: 420)
        .background(Theme.background)
        .onAppear { syncTrack() }
        .onChange(of: engine.currentTrack?.id) { _ in syncTrack() }
        .onReceive(tick) { _ in
            if !isEditing { syncCurrentLine() }
        }
        .onChange(of: offset) { newValue in
            guard let id = engine.currentTrack?.id else { return }
            UserDefaults.standard.set(newValue, forKey: "lrcOffset.\(id.uuidString)")
            syncCurrentLine()
        }
        .sheet(isPresented: $showVariants) {
            LyricsVariantPicker(candidates: variants) { candidate in
                apply(candidate)
            }
        }
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(Theme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small)
                    .stroke(Theme.separator, lineWidth: 1)
            )
    }

    private var lyricsView: some View {
        Group {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyState
            } else if parsedLines.isEmpty {
                plainText
            } else {
                syncedText
            }
        }
        .background(Theme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small)
                .stroke(Theme.separator, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.quote")
                .font(.system(size: 28))
                .foregroundStyle(Theme.secondaryText.opacity(0.65))
            Text(L10n.string("Текст не найден"))
                .font(Theme.Fonts.artist)
                .foregroundStyle(Theme.secondaryText)
            Button(L10n.string("Скачать .lrc")) { downloadLyrics() }
                .disabled(engine.currentTrack == nil || isDownloading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var plainText: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
    }

    private var syncedText: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(parsedLines) { line in
                        lineView(line)
                            .id(line.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: currentLineIndex) { index in
                guard let index, parsedLines.indices.contains(index) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(parsedLines[index].id, anchor: .center)
                }
            }
        }
    }

    private func lineView(_ line: LRCLine) -> some View {
        let current = currentLineIndex == line.id
        let past = currentLineIndex.map { line.id < $0 } ?? false
        return Text(line.text)
            .font(.system(size: current ? 17 : 15,
                          weight: current ? .semibold : .regular))
            .foregroundStyle(current
                             ? Theme.accent
                             : (past ? Theme.secondaryText : Theme.text.opacity(0.65)))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(current ? Theme.accent.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
    }

    private func syncTrack() {
        guard let track = engine.currentTrack, track.id != loadedTrackID else { return }
        loadedTrackID = track.id
        status = ""
        isEditing = false
        offset = UserDefaults.standard.double(forKey: "lrcOffset.\(track.id.uuidString)")
        text = readLyrics(sidecarURL(for: track)) ?? ""
        reparse()
        syncCurrentLine()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, autoDownloadLyrics {
            downloadLyrics()
        }
    }

    private func reparse() {
        parsedLines = LRCParser.parse(text)
        currentLineIndex = nil
    }

    private func toggleEditing() {
        isEditing.toggle()
        if !isEditing {
            reparse()
            syncCurrentLine()
        }
    }

    private func syncCurrentLine() {
        guard !parsedLines.isEmpty else {
            currentLineIndex = nil
            return
        }
        let position = engine.position + offset
        var index: Int?
        for (lineIndex, line) in parsedLines.enumerated() {
            if line.time <= position + 0.02 {
                index = lineIndex
            } else {
                break
            }
        }
        if currentLineIndex != index { currentLineIndex = index }
    }

    private func openLyrics() {
        guard engine.currentTrack != nil else { return }
        let panel = NSOpenPanel()
        let lrc = UTType(filenameExtension: "lrc")
        panel.allowedContentTypes = [lrc, .plainText].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        text = readLyrics(url) ?? ""
        isEditing = false
        reparse()
        syncCurrentLine()
        status = L10n.format("Загружено: %@", url.lastPathComponent)
    }

    private func saveLyrics() {
        guard let track = engine.currentTrack else { return }
        do {
            let url = try writeLyrics(text, for: track)
            reparse()
            syncCurrentLine()
            status = L10n.format("Сохранено: %@", url.lastPathComponent)
        } catch {
            status = L10n.format("Ошибка сохранения: %@", error.localizedDescription)
        }
    }

    private func downloadLyrics() {
        guard let track = engine.currentTrack, !isDownloading else { return }
        let trackID = track.id
        let title = track.title
        let artist = track.artist.isEmpty ? track.albumArtist : track.artist
        let album = track.album
        let duration = track.duration
        isDownloading = true
        status = L10n.string("Поиск текста…")

        Task { @MainActor in
            do {
                let lyrics = try await LyricsService.shared.download(
                    title: title, artist: artist, album: album, duration: duration)
                guard engine.currentTrack?.id == trackID else {
                    isDownloading = false
                    return
                }
                text = lyrics
                isEditing = false
                reparse()
                syncCurrentLine()
                do {
                    let url = try writeLyrics(lyrics, for: track)
                    status = parsedLines.isEmpty
                        ? L10n.format("Скачано без синхронизации: %@", url.lastPathComponent)
                        : L10n.format("Скачано: %@", url.lastPathComponent)
                } catch {
                    status = L10n.format("Ошибка сохранения: %@", error.localizedDescription)
                }
            } catch {
                status = error.localizedDescription
            }
            isDownloading = false
        }
    }

    private var offsetText: String {
        String(format: "%+.1f с", offset)
    }

    private func searchVariants() {
        guard let track = engine.currentTrack, !isSearchingVariants else { return }
        let title = track.title
        let artist = track.artist.isEmpty ? track.albumArtist : track.artist
        let album = track.album
        isSearchingVariants = true
        status = L10n.string("Ищу варианты текста…")
        Task { @MainActor in
            do {
                let result = try await LyricsService.shared.search(title: title,
                                                                   artist: artist,
                                                                   album: album)
                variants = result
                status = L10n.format("Найдено вариантов: %ld", result.count)
                showVariants = true
            } catch {
                status = error.localizedDescription
            }
            isSearchingVariants = false
        }
    }

    private func apply(_ candidate: LyricsCandidate) {
        guard let track = engine.currentTrack,
              let lyrics = candidate.lyrics,
              !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = lyrics
        isEditing = false
        reparse()
        syncCurrentLine()
        do {
            let url = try writeLyrics(lyrics, for: track)
            status = L10n.format("Скачано: %@", url.lastPathComponent)
        } catch {
            status = L10n.format("Ошибка сохранения: %@", error.localizedDescription)
        }
    }

    private func sidecarURL(for track: Track) -> URL {
        track.url.deletingPathExtension().appendingPathExtension("lrc")
    }

    private func readLyrics(_ url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .windowsCP1251)
            ?? String(decoding: data, as: UTF8.self)
    }

    private func writeLyrics(_ text: String, for track: Track) throws -> URL {
        let url = sidecarURL(for: track)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

struct LyricsVariantPicker: View {
    let candidates: [LyricsCandidate]
    let onSelect: (LyricsCandidate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.string("Варианты текста"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(L10n.string("Отмена")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            List(candidates) { candidate in
                Button {
                    onSelect(candidate)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.text)
                            Text([candidate.artist, candidate.album]
                                .filter { !$0.isEmpty }
                                .joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(candidate.durationText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 460, height: 420)
    }
}

/// Vinyl rotation speed: 33 rpm, as on a record.
/// The mini player uses the same speed.
enum MiniRotation {
    static let degreesPerSecond: Double = 198

    static func advance(_ angle: Double, by seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else { return angle }
        return (angle + degreesPerSecond * seconds).truncatingRemainder(dividingBy: 360)
    }
}

/// Compact mini player: a spinning vinyl with artwork, two lines
/// of text, a thin progress bar and buttons. The window resizes from the corner.
struct MiniPlayerView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library

    @State private var rotationStart: Date?
    @State private var rotationAngle: Double = 0
    @State private var miniWindow: NSWindow?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            vinyl
                .frame(width: 62, height: 62)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(engine.currentTrack?.displayTitle ?? L10n.string("Ничего не играет"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)

                Text(engine.currentTrack?.displayArtist ?? "—")
                    .font(Theme.Fonts.artist)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)

                progress
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Theme.Space.xs) {
                Button { engine.previous() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.string("Предыдущий трек"))
                Button { engine.toggle() } label: {
                    ZStack {
                        Circle().fill(Theme.text.opacity(0.10))
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .offset(x: engine.isPlaying ? 0 : 1)
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(engine.isPlaying ? L10n.string("Пауза") : L10n.string("Воспроизвести"))
                Button { engine.next(manual: true) } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.string("Следующий трек"))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text.opacity(0.9))
        }
        .padding(Theme.Space.m)
        .frame(minWidth: 286, minHeight: 92)
        .background(Theme.background)
        .tint(Theme.accent)
        .background(WindowAccessor { candidate in
            if let candidate { miniWindow = candidate }
        })
        .overlay(alignment: .topTrailing) {
            Button(action: returnToMain) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(Theme.Space.xs)
            .help("Вернуться в обычный режим")
        }
        .onAppear {
            setMainWindowHidden(true)
            if engine.isPlaying { rotationStart = Date() }
        }
        .onDisappear { setMainWindowHidden(false) }
        .onChange(of: engine.isPlaying) { playing in
            if playing {
                rotationStart = Date()
            } else {
                rotationAngle = angle(at: Date())
                rotationStart = nil
            }
        }
    }

    /// Closes the mini player; the main window is restored in onDisappear.
    private func returnToMain() {
        if let miniWindow {
            miniWindow.close()
            return
        }
        guard NSApp != nil else { return }
        for window in NSApp.windows where window.title == L10n.string("Мини-плеер") {
            window.close()
        }
    }

    /// While the mini player is open the main window is hidden; it returns after closing.
    private func setMainWindowHidden(_ hidden: Bool) {
        // AppKit is not running yet in CLI rendering: leave windows alone.
        guard ProcessInfo.processInfo.environment["CEDAR_RENDER_MINI"] == nil,
              NSApp != nil else { return }
        for window in NSApp.windows where window.identifier?.rawValue.contains("main-AppWindow") == true {
            if hidden {
                window.orderOut(nil)
            } else if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: Vinyl

    private var vinyl: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                paused: !engine.isPlaying)) { timeline in
            vinylContent
                .rotationEffect(.degrees(angle(at: timeline.date)))
        }
    }

    private var vinylContent: some View {
        ZStack {
            Circle()
                .fill(Color(hex: 0x0D0F13))
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for step in stride(from: 0.22, through: 0.5, by: 0.035) {
                    let radius = size.width * step
                    let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                      width: radius * 2, height: radius * 2)
                    context.stroke(Path(ellipseIn: rect),
                                   with: .color(.white.opacity(0.05)),
                                   lineWidth: 0.8)
                }
            }
            coverCircle
                .frame(width: 40, height: 40)
                .overlay {
                    Circle().strokeBorder(Theme.separator, lineWidth: 0.5)
                }
            Circle()
                .fill(Theme.panel)
                .frame(width: 6, height: 6)
        }
        .overlay {
            Circle().strokeBorder(.white.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }

    private func angle(at date: Date) -> Double {
        guard let rotationStart else { return rotationAngle }
        return MiniRotation.advance(rotationAngle, by: date.timeIntervalSince(rotationStart))
    }

    private var currentCover: NSImage? {
        guard let track = engine.currentTrack else { return nil }
        if let id = track.artworkID, let image = ArtworkCache.shared.image(for: id) {
            return image
        }
        return track.artwork.flatMap { NSImage(data: $0) }
    }

    @ViewBuilder
    private var coverCircle: some View {
        if let station = engine.currentStation,
           let data = library.stationLogo(station),
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(Circle())
        } else if let image = currentCover {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(Theme.subtle)
                Image(systemName: engine.currentStation == nil ? "music.note" : "dot.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(Theme.secondaryText.opacity(0.8))
            }
        }
    }

    // MARK: Progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.separator)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(0, geometry.size.width * fraction))
                }
            }
            .frame(height: 3)

            HStack(spacing: 4) {
                Text(timeText(engine.position))
                Text("/").foregroundStyle(Theme.secondaryText.opacity(0.6))
                Text(timeText(engine.duration))
                Spacer(minLength: 0)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.secondaryText)
        }
    }

    private var fraction: CGFloat {
        guard engine.duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, engine.position / engine.duration)))
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
