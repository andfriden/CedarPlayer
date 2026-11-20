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

/// Компактный плеер поверх остальных окон.
struct MiniPlayerView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let data = engine.currentTrack?.artwork, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color(hex: 0x2B2F36)
                        Image(systemName: "music.note").foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(engine.currentTrack?.displayTitle ?? "Ничего не играет")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(engine.currentTrack?.displayArtist ?? "—")
                    .font(Theme.Fonts.artist)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                ProgressView(value: engine.duration > 0 ? engine.position / engine.duration : 0)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .frame(height: 3)
            }

            HStack(spacing: Theme.Space.xs) {
                Button { engine.previous() } label: {
                    Image(systemName: "backward.fill").frame(width: 30, height: 30)
                }
                Button { engine.toggle() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                Button { engine.next(manual: true) } label: {
                    Image(systemName: "forward.fill").frame(width: 30, height: 30)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text.opacity(0.9))
        }
        .padding(Theme.Space.m)
        .frame(minWidth: 380, minHeight: 74)
        .background(Theme.background)
        .tint(Theme.accent)
    }
}
