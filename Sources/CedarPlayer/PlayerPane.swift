import SwiftUI
import AppKit

/// Панель плеера 425×300: логотип, обложка 122×122, индикатор 250×44,
/// громкость, метаданные, прогресс-бар и транспорт. Отрисовка собственная.
struct PlayerPane: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showPlaylist") private var showPlaylist = true
    @AppStorage("meterStyle") private var meterStyleRaw = MeterStyle.segments.rawValue

    var artworkSize: CGFloat = 122

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            header
                .frame(width: 163, height: 23)
                .position(x: 212.5, y: 19.5)

            artwork
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                )
                .position(x: 19 + artworkSize / 2, y: 28 + artworkSize / 2)

            LevelMeterStrip(style: MeterStyle(rawValue: meterStyleRaw) ?? .segments,
                            levelLeft: engine.levelL,
                            levelRight: engine.levelR,
                            peakLeft: engine.peakL,
                            peakRight: engine.peakR,
                            bands: engine.spectrum,
                            isPlaying: engine.isPlaying)
                .frame(width: 250, height: 44)
                .position(x: 291, y: 62)

            volumeRow
                .frame(width: 220, height: 22)
                .position(x: 272, y: 112)

            infoBlock
                .frame(width: 403, height: 44)
                .position(x: 211.5, y: 172)

            seekRow
                .frame(width: 393, height: 22)
                .position(x: 212.5, y: 206)

            timeRow
                .frame(width: 393, height: 17)
                .position(x: 212.5, y: 226.5)

            transportRow
                .position(x: 212.5, y: 258)

            toolRow
                .position(x: 212.5, y: 290)
        }
        .frame(width: 425, height: 300)
        .background(background)
    }

    // MARK: Фон

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.17), Color(white: 0.07)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.accentColor.opacity(0.12), .clear],
                           center: .top, startRadius: 10, endRadius: 300)
        }
    }

    // MARK: Логотип

    private var header: some View {
        Text("CEDAR PLAYER")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .tracking(2.4)
            .foregroundStyle(.white.opacity(0.72))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Обложка

    private var artwork: some View {
        Group {
            if let data = engine.currentTrack?.artwork, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.32), Color(white: 0.19)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: artworkSize * 0.32, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
    }

    // MARK: Громкость

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Button {
                engine.isMuted.toggle()
            } label: {
                Image(systemName: engine.isMuted || engine.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)

            Slider(value: $engine.volume, in: 0...1)
                .controlSize(.mini)
                .tint(.white.opacity(0.85))
                .frame(width: 166)
        }
        .frame(width: 220, alignment: .leading)
    }

    // MARK: Позиция и тайминги

    private var seekRow: some View {
        Slider(value: Binding(
            get: { engine.duration > 0 ? engine.position / engine.duration : 0 },
            set: { engine.seek(to: $0 * engine.duration) }
        ))
        .controlSize(.mini)
        .tint(.white)
        .frame(maxWidth: .infinity)
        .help(progressTooltip)
    }

    private var progressTooltip: String {
        let track = engine.currentTrack
        let left = timeText(engine.position)
        let total = timeText(engine.duration)
        let quality = track?.qualityText ?? ""
        return quality.isEmpty ? "\(left) из \(total)" : "\(left) из \(total) · \(quality)"
    }

    private var timeRow: some View {
        HStack {
            Text(timeText(engine.position))
                .frame(width: 60, alignment: .leading)
            Spacer(minLength: 0)
            Text(timeText(engine.duration))
                .frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white.opacity(0.55))
        .frame(width: 393)
    }

    // MARK: Информация о треке

    private var infoBlock: some View {
        VStack(spacing: 1) {
            Text(engine.currentTrack?.displayTitle ?? "Ничего не играет")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .frame(height: 17)

            Text((engine.currentTrack?.displayArtist ?? "—") + " · " + (engine.currentTrack?.displayAlbum ?? ""))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 12)

            Text(engine.currentTrack?.qualityText ?? "")
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.34))
                .lineLimit(1)
                .frame(height: 12)

            if let error = engine.errorMessage {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(1)
                    .frame(height: 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: Транспорт

    private var transportRow: some View {
        HStack(spacing: 0) {
            sideButton("shuffle") {
                engine.isShuffle.toggle()
            }
            .foregroundStyle(engine.isShuffle ? Color.accentColor : .white.opacity(0.55))
            .frame(width: 52, height: 30)

            Spacer().frame(width: 0)

            Button { engine.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 68, height: 32)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.leftArrow, modifiers: .command)

            Button { engine.toggle() } label: {
                ZStack {
                    Circle().fill(.white.opacity(0.14)).frame(width: 44, height: 44)
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .offset(x: engine.isPlaying ? 0 : 1)
                }
                .frame(width: 92, height: 34)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(engine.currentTrack == nil)

            Button { engine.next(manual: true) } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 68, height: 32)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.rightArrow, modifiers: .command)

            sideButton("repeat") {
                engine.repeatMode = engine.repeatMode.next
            }
            .foregroundStyle(engine.repeatMode == .off ? .white.opacity(0.55) : Color.accentColor)
            .frame(width: 52, height: 30)

            Button {
                engine.isEQEnabled.toggle()
            } label: {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 12))
                    .foregroundStyle(engine.isEQEnabled ? Color.accentColor : .white.opacity(0.55))
                    .frame(width: 46, height: 34)
            }
            .buttonStyle(.plain)
            .help("Эквалайзер (⌘E)")
        }
        .frame(width: 425)
    }

    private func sideButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: Нижние инструменты

    private var toolRow: some View {
        HStack(spacing: 14) {
            Button { openWindow(id: "lyrics") } label: {
                Image(systemName: "text.quote").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Текст песни (⌘L)")

            Button { openWindow(id: "albumart") } label: {
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Окно обложки")

            Button { openWindow(id: "library") } label: {
                Image(systemName: "books.vertical").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Библиотека (⌘B)")

            Button {
                cycleMeterStyle()
            } label: {
                Image(systemName: meterIcon)
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Стиль индикатора: \(currentStyle.title) — нажмите, чтобы сменить")

            Button { showPlaylist.toggle() } label: {
                Image(systemName: showPlaylist ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                    .font(.system(size: 11))
                    .foregroundStyle(showPlaylist ? Color.accentColor : .white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Показать/скрыть плейлист (⌥⌘P)")

            Menu {
                Picker("Скорость", selection: $engine.playbackRate) {
                    Text("0.5×").tag(0.5)
                    Text("0.75×").tag(0.75)
                    Text("1×").tag(1.0)
                    Text("1.25×").tag(1.25)
                    Text("1.5×").tag(1.5)
                    Text("2×").tag(2.0)
                }
            } label: {
                Text(String(format: "%.2g×", engine.playbackRate))
                    .font(.system(size: 10, design: .monospaced))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 42)
        }
        .foregroundStyle(.white.opacity(0.55))
        .frame(height: 18)
    }

    private var currentStyle: MeterStyle {
        MeterStyle(rawValue: meterStyleRaw) ?? .segments
    }

    private var meterIcon: String {
        switch currentStyle {
        case .segments: return "chart.bar.fill"
        case .bar: return "chart.bar.xaxis"
        case .dots: return "smallcircle.filled.circle"
        case .spectrum: return "waveform.path.ecg"
        }
    }

    private func cycleMeterStyle() {
        let all = MeterStyle.allCases
        guard let index = all.firstIndex(of: currentStyle) else { return }
        let next = all[(index + 1) % all.count]
        meterStyleRaw = next.rawValue
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
