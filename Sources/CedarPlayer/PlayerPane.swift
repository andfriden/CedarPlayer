import SwiftUI
import AppKit

/// Панель плеера 425×300: обложка и метаданные в одной строке, компактный
/// индикатор, громкость, прогресс и основные кнопки. Редкие действия — в меню «Ещё».
struct PlayerPane: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library
    @AppStorage("showPlaylist") private var showPlaylist = true
    @AppStorage("meterStyle") private var meterStyleRaw = MeterStyle.segments.rawValue
    @State private var coverTrack: Track?

    var artworkSize: CGFloat = 92

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            topRow
            meter
            volumeRow
            seekBlock
            transportRow
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(width: 425, height: 300, alignment: .top)
        .background(Theme.background)
        .sheet(item: $coverTrack) { track in
            CoverPickerSheet(track: track)
                .environmentObject(library)
                .environmentObject(engine)
        }
    }

    // MARK: Обложка и метаданные

    private var topRow: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            artwork

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(engine.currentTrack?.displayTitle ?? "Ничего не играет")
                    .font(Theme.Fonts.nowPlaying)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.85)

                Text(engine.currentTrack?.displayArtist ?? "—")
                    .font(Theme.Fonts.artist)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)

                if let album = engine.currentTrack?.album, !album.isEmpty {
                    Text(album)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.secondaryText.opacity(0.85))
                        .lineLimit(1)
                }

                if let quality = engine.currentTrack?.qualityText, !quality.isEmpty {
                    Text(quality)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.secondaryText.opacity(0.8))
                        .lineLimit(1)
                        .padding(.top, 2)
                }

                if let error = engine.errorMessage {
                    Text(error)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Color(hex: 0xE06C75))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(height: artworkSize, alignment: .top)
    }

    private var artwork: some View {
        Group {
            if let data = engine.currentTrack?.artwork, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(hex: 0x2B2F36)
                    Image(systemName: "music.note")
                        .font(.system(size: artworkSize * 0.3, weight: .light))
                        .foregroundStyle(Theme.secondaryText.opacity(0.7))
                }
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if engine.currentTrack != nil, engine.currentTrack?.artwork == nil {
                Button {
                    coverTrack = engine.currentTrack
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 26, height: 26)
                        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Найти обложку в базе")
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
        .contextMenu {
            Button("Найти обложку в базе…") {
                coverTrack = engine.currentTrack
            }
            .disabled(engine.currentTrack == nil)
        }
    }

    // MARK: Индикатор

    /// Визуализатор: уровень L/R или спектр. Клик по нему меняет стиль.
    private var meter: some View {
        LevelMeterStrip(style: currentStyle,
                        levelLeft: engine.levelL,
                        levelRight: engine.levelR,
                        peakLeft: engine.peakL,
                        peakRight: engine.peakR,
                        bands: engine.spectrum,
                        spectrumPeaks: engine.spectrumPeaks,
                        isPlaying: engine.isPlaying,
                        showsScale: false,
                        monochrome: false)
            .frame(height: 40)
            .contentShape(Rectangle())
            .onTapGesture { cycleMeterStyle() }
            .help("Визуализатор: \(currentStyle.title) — нажмите, чтобы сменить")
    }

    private var currentStyle: MeterStyle {
        MeterStyle(rawValue: meterStyleRaw) ?? .segments
    }

    private func cycleMeterStyle() {
        let all = MeterStyle.allCases
        guard let index = all.firstIndex(of: currentStyle) else { return }
        meterStyleRaw = all[(index + 1) % all.count].rawValue
    }

    // MARK: Громкость

    private var volumeRow: some View {
        HStack(spacing: Theme.Space.s) {
            Button {
                engine.isMuted.toggle()
            } label: {
                Image(systemName: engine.isMuted || engine.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(engine.isMuted ? Theme.accent : Theme.secondaryText)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Звук (⇧⌘M)")

            Slider(value: $engine.volume, in: 0...1)
                .controlSize(.mini)
                .tint(Theme.accent)
        }
        .frame(height: 32)
    }

    // MARK: Позиция

    private var seekBlock: some View {
        VStack(spacing: Theme.Space.xs) {
            Slider(value: Binding(
                get: { engine.duration > 0 ? engine.position / engine.duration : 0 },
                set: { engine.seek(to: $0 * engine.duration) }
            ))
            .controlSize(.mini)
            .tint(Theme.accent)
            .help(progressTooltip)

            HStack {
                Text(timeText(engine.position))
                    .frame(width: 60, alignment: .leading)
                Spacer(minLength: 0)
                Text(timeText(engine.duration))
                    .frame(width: 60, alignment: .trailing)
            }
            .font(Theme.Fonts.timeMono)
            .foregroundStyle(Theme.secondaryText)
        }
    }

    private var progressTooltip: String {
        let left = timeText(engine.position)
        let total = timeText(engine.duration)
        let quality = engine.currentTrack?.qualityText ?? ""
        return quality.isEmpty ? "\(left) из \(total)" : "\(left) из \(total) · \(quality)"
    }

    // MARK: Транспорт

    private var transportRow: some View {
        ZStack {
            HStack(spacing: Theme.Space.s) {
                transportButton("backward.fill", size: 15) { engine.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)

                Button { engine.toggle() } label: {
                    ZStack {
                        Circle()
                            .fill(Theme.text.opacity(0.10))
                            .frame(width: 46, height: 46)
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .offset(x: engine.isPlaying ? 0 : 1)
                    }
                    .frame(width: 52, height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(engine.currentTrack == nil)
                .help("Воспроизведение (пробел)")

                transportButton("forward.fill", size: 15) { engine.next(manual: true) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
            }

            HStack(spacing: Theme.Space.xs) {
                Spacer()
                MoreMenuButton { coverTrack = engine.currentTrack }
                playlistButton
            }
        }
        .frame(height: 48)
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(Theme.text.opacity(0.9))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var playlistButton: some View {
        Button {
            showPlaylist.toggle()
        } label: {
            Image(systemName: showPlaylist ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(showPlaylist ? Theme.accent : Theme.secondaryText)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Показать/скрыть плейлист (⌥⌘P)")
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
