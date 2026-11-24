import SwiftUI
import AppKit

/// Fixed 240 px now-playing panel: 100 px artwork, metadata and spectrum
/// in the right column, then a 4 px seek track and a 40 px transport row.
struct PlayerPane: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library
    @AppStorage("meterStyle") private var meterStyleRaw = MeterStyle.spectrum.rawValue
    @AppStorage("showPlaylist") private var showPlaylist = true
    @State private var coverTrack: Track?

    private let artworkSize: CGFloat = 100

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                topRow
                    .frame(height: 132)
                seekBlock
                    .padding(.top, 10)
                transportRow
                    .frame(height: 40)
                    .padding(.top, 12)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Layout.playerHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.Cyber.border, lineWidth: 1)
        }
        .sheet(item: $coverTrack) { track in
            CoverPickerSheet(track: track)
                .environmentObject(library)
                .environmentObject(engine)
        }
    }

    // MARK: Backdrop

    private var backdrop: some View {
        ZStack {
            Theme.Cyber.playerBackground
            RadialGradient(colors: [Theme.Cyber.accent.opacity(0.09), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 300)
            Canvas { context, size in
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                                 with: .color(Theme.Cyber.separator.opacity(0.18)))
                    y += 3
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Artwork and metadata

    private var topRow: some View {
        HStack(alignment: .top, spacing: 16) {
            artwork

            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(text: titleText,
                            font: .system(size: 16, weight: .bold),
                            color: Theme.Cyber.titleText,
                            height: 24)
                    .frame(height: 24)

                Text(secondaryText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.Cyber.artistText)
                    .lineLimit(1)
                    .frame(height: 18, alignment: .top)
                    .padding(.top, 4)

                HStack(spacing: 6) {
                    Text(formatBadge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.Cyber.playerBackground)
                        .frame(width: 42, height: 18)
                        .background(Theme.Cyber.accent, in: RoundedRectangle(cornerRadius: 3))
                    Text(technicalText)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Theme.Cyber.tertiaryText)
                        .lineLimit(1)
                }
                .frame(height: 18)
                .padding(.top, 6)

                visualizer
                    .frame(height: 24)
                    .background(Theme.Cyber.inset.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.8)
                    }
                    .padding(.top, 6)
                    .onTapGesture { cycleMeterStyle() }
                    .help(L10n.format("Визуализатор: %@", currentStyle.title))

                rating
                    .frame(height: 14)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 132, alignment: .top)
        }
        .frame(height: 132, alignment: .top)
    }

    private var artwork: some View {
        Group {
            if let image = artworkImage {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Theme.Cyber.subtle, Theme.Cyber.panel],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: engine.currentStation == nil ? "opticaldisc" : "dot.radiowaves.left.and.right")
                        .font(.system(size: 30, weight: .ultraLight))
                        .foregroundStyle(Theme.Cyber.secondaryText.opacity(0.55))
                }
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.Cyber.border, lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if engine.currentTrack != nil, engine.currentTrack?.artwork == nil {
                Button { coverTrack = engine.currentTrack } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Cyber.text)
                        .frame(width: 22, height: 22)
                        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Найти обложку в базе")
            }
        }
        .contextMenu {
            Button("Найти обложку в базе…") { coverTrack = engine.currentTrack }
                .disabled(engine.currentTrack == nil)
        }
    }

    private var artworkImage: NSImage? {
        if let station = engine.currentStation,
           let data = library.stationLogo(station),
           let image = NSImage(data: data) {
            return image
        }
        if let data = engine.currentTrack?.artwork {
            return NSImage(data: data)
        }
        return nil
    }

    private var titleText: String {
        engine.currentStation.map { engine.radioTrack ?? $0.name }
            ?? engine.currentTrack?.displayTitle
            ?? L10n.string("Ничего не играет")
    }

    private var secondaryText: String {
        if engine.currentStation != nil {
            return engine.radioArtist ?? L10n.string("Онлайн-радио")
        }
        let artist = engine.currentTrack?.displayArtist ?? L10n.string("Выберите трек")
        let album = engine.currentTrack?.displayAlbum ?? ""
        return album.isEmpty ? artist : "\(artist) · \(album)"
    }

    private var formatBadge: String {
        if engine.currentStation != nil { return "LIVE" }
        guard let track = engine.currentTrack else { return "AUDIO" }
        let ext = track.url.pathExtension.uppercased()
        return ext.isEmpty ? "AUDIO" : ext
    }

    private var technicalText: String {
        guard let track = engine.currentTrack else { return "STANDBY" }
        let rate = track.sampleRate > 0 ? "\(Int(track.sampleRate / 1000)) kHz" : nil
        if track.bitDepth > 0, let rate {
            return "\(track.bitDepth)-bit / \(rate)"
        }
        if track.bitrate > 0 {
            return "\(Int(Double(track.bitrate) / 1000)) kbps"
        }
        return rate ?? "—"
    }

    private var rating: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { value in
                Image(systemName: value <= (engine.currentTrack?.rating ?? 0) ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(value <= (engine.currentTrack?.rating ?? 0)
                                     ? Theme.Cyber.accent : Theme.Cyber.tertiaryText.opacity(0.45))
                    .frame(width: 14, height: 14)
            }
        }
    }

    @ViewBuilder
    private var visualizer: some View {
        if currentStyle == .spectrum {
            CyberSpectrum(bands: engine.spectrum,
                          peaks: engine.spectrumPeaks,
                          isPlaying: engine.isPlaying)
        } else {
            LevelMeterStrip(style: currentStyle,
                            levelLeft: engine.levelL,
                            levelRight: engine.levelR,
                            peakLeft: engine.peakL,
                            peakRight: engine.peakR,
                            bands: engine.spectrum,
                            spectrumPeaks: engine.spectrumPeaks,
                            isPlaying: engine.isPlaying,
                            showsScale: false,
                            monochrome: true)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
        }
    }

    private var currentStyle: MeterStyle {
        MeterStyle(rawValue: meterStyleRaw) ?? .spectrum
    }

    private func cycleMeterStyle() {
        let all = MeterStyle.allCases
        guard let index = all.firstIndex(of: currentStyle) else { return }
        meterStyleRaw = all[(index + 1) % all.count].rawValue
    }

    // MARK: Seek

    private var seekBlock: some View {
        VStack(spacing: 4) {
            CyberProgressBar(value: progressFraction, height: 4, thumbSize: 10) { fraction in
                guard engine.duration > 0 else { return }
                engine.seek(to: fraction * engine.duration)
            }
            HStack {
                Text(timeText(engine.position))
                Spacer(minLength: 0)
                Text("-" + timeText(max(0, engine.duration - engine.position)))
            }
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(Theme.Cyber.tertiaryText)
            .frame(height: 14)
        }
        .frame(height: 22)
    }

    private var progressFraction: Double {
        guard engine.duration > 0, engine.position.isFinite else { return 0 }
        return min(1, max(0, engine.position / engine.duration))
    }

    // MARK: Transport

    private var transportRow: some View {
        ZStack {
            HStack(spacing: 6) {
                CyberIconButton(symbol: "shuffle",
                                help: L10n.string("Случайный порядок"),
                                active: engine.isShuffle,
                                size: 28) {
                    engine.isShuffle.toggle()
                }
                CyberIconButton(symbol: engine.repeatMode.symbol,
                                help: repeatHelp,
                                active: engine.repeatMode != .off,
                                size: 28) {
                    engine.repeatMode = engine.repeatMode.next
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                transportButton("backward.fill", label: L10n.string("Предыдущий трек"), size: 32) {
                    engine.previous()
                }
                .padding(.trailing, 12)

                Button { engine.toggle() } label: {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Theme.Cyber.accentBright, Theme.Cyber.accent],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 40, height: 40)
                            .shadow(color: Theme.Cyber.accent.opacity(0.5), radius: 8)
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.Cyber.playerBackground)
                            .offset(x: engine.isPlaying ? 0 : 1)
                    }
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                    .opacity(engine.currentTrack == nil && engine.currentStation == nil ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(engine.currentTrack == nil && engine.currentStation == nil)
                .help("Воспроизведение (пробел)")
                .accessibilityLabel(engine.isPlaying ? L10n.string("Пауза") : L10n.string("Воспроизвести"))

                transportButton("forward.fill", label: L10n.string("Следующий трек"), size: 32) {
                    engine.next(manual: true)
                }
                .padding(.leading, 12)

                transportButton("stop.fill", label: L10n.string("Стоп"), size: 28) {
                    engine.stop()
                }
                .padding(.leading, 8)
                .disabled(engine.currentTrack == nil && engine.currentStation == nil)
                .opacity(engine.currentTrack == nil && engine.currentStation == nil ? 0.35 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 6) {
                Button {
                    engine.isMuted.toggle()
                } label: {
                    Image(systemName: engine.isMuted || engine.volume == 0
                          ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(engine.isMuted ? Theme.Cyber.accent : Theme.Cyber.secondaryText)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Звук (⇧⌘M)")
                .accessibilityLabel(engine.isMuted ? L10n.string("Включить звук") : L10n.string("Заглушить"))

                CyberProgressBar(value: engine.volume, height: 4, thumbSize: 8) { value in
                    engine.volume = value
                    if engine.isMuted { engine.isMuted = false }
                }
                .frame(width: 80)

                CyberIconButton(symbol: showPlaylist ? "list.bullet.rectangle.fill" : "list.bullet.rectangle",
                                help: showPlaylist ? L10n.string("Скрыть плейлист") : L10n.string("Показать плейлист"),
                                active: showPlaylist,
                                size: 28) {
                    showPlaylist.toggle()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 40)
    }

    private var repeatHelp: String {
        switch engine.repeatMode {
        case .off: return L10n.string("Повтор выключен")
        case .all: return L10n.string("Повтор списка")
        case .one: return L10n.string("Повтор трека")
        }
    }

    private func transportButton(_ symbol: String, label: String, size: CGFloat,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Cyber.text.opacity(0.9))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
