import SwiftUI
import AppKit

/// Окно текста песни с чтением и сохранением .lrc рядом с файлом.
struct LyricsView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @State private var text = ""
    @State private var loadedTrackID: UUID?
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(engine.currentTrack?.displayTitle ?? "Нет трека")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.small)
                        .stroke(Theme.separator, lineWidth: 1)
                )

            HStack {
                Button("Загрузить .lrc") { openLyrics() }
                Button("Сохранить") { saveLyrics() }
                Spacer()
                Text("Формат: [мм:сс.xx] строка")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.Space.l)
        .frame(minWidth: 460, minHeight: 420)
        .background(Theme.background)
        .onAppear { syncTrack() }
        .onChange(of: engine.currentTrack?.id) { _ in syncTrack() }
    }

    private func syncTrack() {
        guard let track = engine.currentTrack, track.id != loadedTrackID else { return }
        loadedTrackID = track.id
        status = ""
        let sidecar = track.url.deletingPathExtension().appendingPathExtension("lrc")
        text = (try? String(contentsOf: sidecar, encoding: .utf8)) ?? ""
    }

    private func openLyrics() {
        guard engine.currentTrack != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        status = "Загружено: \(url.lastPathComponent)"
    }

    private func saveLyrics() {
        guard let track = engine.currentTrack else { return }
        let sidecar = track.url.deletingPathExtension().appendingPathExtension("lrc")
        do {
            try text.write(to: sidecar, atomically: true, encoding: .utf8)
            status = "Сохранено: \(sidecar.lastPathComponent)"
        } catch {
            status = "Ошибка сохранения: \(error.localizedDescription)"
        }
    }
}

/// Компактный плеер в духе мини-плеера Яндекс.Музыки:
/// обложка, две строки текста, тонкий прогресс и три кнопки.
struct MiniPlayerView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            artwork

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(engine.currentTrack?.displayTitle ?? "Ничего не играет")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)

                Text(engine.currentTrack?.displayArtist ?? "—")
                    .font(Theme.Fonts.artist)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)

                progress
            }

            Spacer(minLength: Theme.Space.s)

            HStack(spacing: Theme.Space.xs) {
                Button { engine.previous() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 13))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                Button { engine.toggle() } label: {
                    ZStack {
                        Circle().fill(Theme.accent)
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.background)
                            .offset(x: engine.isPlaying ? 0 : 1)
                    }
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
                }
                Button { engine.next(manual: true) } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 13))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text.opacity(0.9))
        }
        .padding(Theme.Space.m)
        .frame(width: 372, height: 96)
        .background(Theme.panel)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .strokeBorder(Theme.separator, lineWidth: 1)
                .padding(1)
        }
        .tint(Theme.accent)
    }

    private var artwork: some View {
        Group {
            if let data = engine.currentTrack?.artwork, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(hex: 0x2B2F36)
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Theme.secondaryText.opacity(0.8))
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.separator)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(0, geometry.size.width * fraction))
                }
            }
            .frame(height: 3)

            HStack(spacing: 4) {
                Text(timeText(engine.position))
                Text("/")
                    .foregroundStyle(Theme.secondaryText.opacity(0.6))
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
