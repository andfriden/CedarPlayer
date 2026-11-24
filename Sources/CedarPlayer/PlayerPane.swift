import SwiftUI
import AppKit

/// Fixed-height now-playing panel with the amber Cyber-HiFi treatment.
struct PlayerPane: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library
    @AppStorage("showPlaylist") private var showPlaylist = true
    @AppStorage("meterStyle") private var meterStyleRaw = MeterStyle.spectrum.rawValue
    @State private var coverTrack: Track?

    var artworkSize: CGFloat = 132

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 10) {
                topRow
                visualizer
                progressRow
                transportRow
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Layout.playerHeight)
        .clipped()
        .sheet(item: $coverTrack) { track in
            CoverPickerSheet(track: track)
                .environmentObject(library)
                .environmentObject(engine)
        }
    }

    // MARK: Backdrop

    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x29292F), Color(hex: 0x19191D)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Theme.Cyber.accent.opacity(0.13), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 360)
            if let image = artworkImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 52)
                    .opacity(0.10)
                    .clipped()
            }
            Canvas { context, size in
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                                 with: .color(.white.opacity(0.018)))
                    y += 3
                }
            }
            .allowsHitTesting(false)
        }
        .clipped()
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

    // MARK: Artwork and metadata

    private var topRow: some View {
        HStack(alignment: .top, spacing: 14) {
            artwork

            VStack(alignment: .leading, spacing: 3) {
                Text(engine.currentTrack == nil && engine.currentStation == nil
                     ? "CEDAR PLAYER"
                     : L10n.string("Сейчас играет").uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(Theme.Cyber.accent)

                MarqueeText(text: titleText,
                            font: Theme.Fonts.nowPlaying,
                            color: Theme.Cyber.text)
                    .frame(height: 28)

                Text(artistText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Cyber.secondaryText)
                    .lineLimit(1)

                Text(albumText)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Cyber.secondaryText.opacity(0.8))
                    .lineLimit(1)

                Text(formatText)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Cyber.accentBright)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.Cyber.inset.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Theme.Cyber.accent.opacity(0.35), lineWidth: 0.7)
                    }
                    .padding(.top, 2)

                if let error = engine.errorMessage {
                    Text(error)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Cyber.danger)
                        .lineLimit(1)
                }
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)

            MoreMenuButton { coverTrack = engine.currentTrack }
        }
        .frame(height: artworkSize, alignment: .top)
    }

    private var artwork: some View {
        Group {
            if let image = artworkImage {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(hex: 0x34343B), Color(hex: 0x202024)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: engine.currentStation == nil ? "opticaldisc" : "dot.radiowaves.left.and.right")
                        .font(.system(size: artworkSize * 0.30, weight: .ultraLight))
                        .foregroundStyle(Theme.Cyber.secondaryText.opacity(0.55))
                }
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Theme.Cyber.separator],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if engine.currentTrack != nil, engine.currentTrack?.artwork == nil {
                Button {
                    coverTrack = engine.currentTrack
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Cyber.text)
                        .frame(width: 24, height: 24)
                        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Найти обложку в базе")
            }
        }
        .shadow(color: Theme.Cyber.accent.opacity(0.22), radius: 18, y: 0)
        .shadow(color: .black.opacity(0.55), radius: 10, y: 5)
        .contextMenu {
            Button("Найти обложку в базе…") { coverTrack = engine.currentTrack }
                .disabled(engine.currentTrack == nil)
        }
    }

    private var titleText: String {
        engine.currentStation.map { engine.radioTrack ?? $0.name }
            ?? engine.currentTrack?.displayTitle
            ?? L10n.string("Ничего не играет")
    }

    private var artistText: String {
        if engine.currentStation != nil { return engine.radioArtist ?? L10n.string("Онлайн-радио") }
        return engine.currentTrack?.displayArtist ?? L10n.string("Выберите трек в плейлисте")
    }

    private var albumText: String {
        if let station = engine.currentStation { return station.name }
        return engine.currentTrack?.displayAlbum ?? "—"
    }

    private var formatText: String {
        if engine.currentStation != nil { return "ONLINE | STREAM" }
        guard let track = engine.currentTrack else { return "STANDBY" }
        let ext = track.url.pathExtension.uppercased()
        let rate = track.sampleRate > 0 ? "\(Int(track.sampleRate / 1000)) kHz" : nil
        if track.bitDepth > 0, let rate {
            return "\(ext) | \(track.bitDepth)-bit / \(rate)"
        }
        if track.bitrate > 0 {
            return "\(ext) | \(Int(Double(track.bitrate) / 1000)) kbps"
        }
        return rate.map { "\(ext) | \($0)" } ?? (ext.isEmpty ? "AUDIO" : ext)
    }

    // MARK: Visualizer

    private var visualizer: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.Cyber.inset.opacity(0.7))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.8)
                }
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
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .frame(height: 38)
        .contentShape(Rectangle())
        .onTapGesture { cycleMeterStyle() }
        .help(L10n.format("Визуализатор: %@ — нажмите, чтобы сменить", currentStyle.title))
    }

    private var currentStyle: MeterStyle {
        MeterStyle(rawValue: meterStyleRaw) ?? .segments
    }

    private func cycleMeterStyle() {
        let all = MeterStyle.allCases
        guard let index = all.firstIndex(of: currentStyle) else { return }
        meterStyleRaw = all[(index + 1) % all.count].rawValue
    }

    // MARK: Progress

    private var progressRow: some View {
        HStack(spacing: 9) {
            Text(timeText(engine.position))
                .frame(width: 42, alignment: .leading)
            CyberProgressBar(value: progressFraction) { fraction in
                guard engine.duration > 0 else { return }
                engine.seek(to: fraction * engine.duration)
            }
            Text("-" + timeText(max(0, engine.duration - engine.position)))
                .frame(width: 46, alignment: .trailing)
        }
        .font(Theme.Fonts.timeMono)
        .foregroundStyle(Theme.Cyber.secondaryText)
        .frame(height: 20)
    }

    private var progressFraction: Double {
        guard engine.duration > 0, engine.position.isFinite else { return 0 }
        return min(1, max(0, engine.position / engine.duration))
    }

    // MARK: Transport

    private var transportRow: some View {
        HStack(spacing: Theme.Space.s) {
            volumeControl
                .frame(maxWidth: 128, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                transportButton("backward.fill", label: L10n.string("Предыдущий трек"), size: 14) {
                    engine.previous()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Button { engine.toggle() } label: {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Theme.Cyber.accentBright, Theme.Cyber.accent],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 46, height: 46)
                            .shadow(color: Theme.Cyber.accent.opacity(0.55), radius: 12)
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color(hex: 0x17171A))
                            .offset(x: engine.isPlaying ? 0 : 1)
                    }
                    .frame(width: 50, height: 48)
                    .contentShape(Rectangle())
                    .opacity(engine.currentTrack == nil && engine.currentStation == nil ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(engine.currentTrack == nil && engine.currentStation == nil)
                .help("Воспроизведение (пробел)")
                .accessibilityLabel(engine.isPlaying ? L10n.string("Пауза") : L10n.string("Воспроизвести"))

                transportButton("stop.fill", label: L10n.string("Стоп"), size: 11) {
                    engine.stop()
                }
                .disabled(engine.currentTrack == nil && engine.currentStation == nil)
                .opacity(engine.currentTrack == nil && engine.currentStation == nil ? 0.35 : 1)

                transportButton("forward.fill", label: L10n.string("Следующий трек"), size: 14) {
                    engine.next(manual: true)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                CyberIconButton(symbol: "shuffle",
                                help: L10n.string("Случайный порядок"),
                                active: engine.isShuffle) {
                    engine.isShuffle.toggle()
                }
                CyberIconButton(symbol: engine.repeatMode.symbol,
                                help: repeatHelp,
                                active: engine.repeatMode != .off) {
                    engine.repeatMode = engine.repeatMode.next
                }
                CyberIconButton(symbol: showPlaylist ? "list.bullet.rectangle.fill" : "list.bullet.rectangle",
                                help: L10n.string("Показать/скрыть плейлист"),
                                active: showPlaylist) {
                    showPlaylist.toggle()
                }
            }
            .frame(maxWidth: 128, alignment: .trailing)
        }
        .frame(height: 48)
    }

    private var volumeControl: some View {
        HStack(spacing: 7) {
            Button {
                engine.isMuted.toggle()
            } label: {
                Image(systemName: engine.isMuted || engine.volume == 0
                      ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(engine.isMuted ? Theme.Cyber.accent : Theme.Cyber.secondaryText)
                    .frame(width: 24, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Звук (⇧⌘M)")
            .accessibilityLabel(engine.isMuted ? L10n.string("Включить звук") : L10n.string("Заглушить"))

            CyberProgressBar(value: engine.volume, height: 16, showsThumb: true) { value in
                engine.volume = value
                if engine.isMuted { engine.isMuted = false }
            }
            .frame(width: 76)
        }
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
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Theme.Cyber.text.opacity(0.9))
                .frame(width: 32, height: 34)
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
