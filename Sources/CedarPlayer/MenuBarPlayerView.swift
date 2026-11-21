import SwiftUI
import AppKit

/// Компактный плеер в строке меню: трек, транспорт и возврат к основному окну.
struct MenuBarPlayerView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.currentStation?.name ?? engine.currentTrack?.displayTitle ?? "Ничего не играет")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(engine.currentStation.map { _ in engine.radioArtist ?? "Онлайн-радио" }
                         ?? engine.currentTrack?.displayArtist ?? "—")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: Theme.Space.s) {
                Button { engine.previous() } label: {
                    Image(systemName: "backward.fill").frame(width: 28, height: 28)
                }
                Button { engine.toggle() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 32, height: 32)
                        .background(Theme.text.opacity(0.1), in: Circle())
                }
                Button { engine.next(manual: true) } label: {
                    Image(systemName: "forward.fill").frame(width: 28, height: 28)
                }
                Spacer()
                if !engine.outputFormatDescription.isEmpty, engine.outputFormatDescription != "—" {
                    Text(engine.outputFormatDescription)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text.opacity(0.9))
            .accessibilityElement(children: .contain)

            Divider().overlay(Theme.separator)

            HStack {
                Button("Открыть плеер") { openPlayer() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .font(Theme.Fonts.artist)
                Spacer()
                Button("Выход") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
                    .font(Theme.Fonts.caption)
            }
        }
        .padding(Theme.Space.m)
        .frame(width: 300)
        .background(Theme.panel)
        .tint(Theme.accent)
    }

    private var artwork: some View {
        Group {
            if let station = engine.currentStation,
               let data = library.stationLogo(station),
               let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let data = engine.currentTrack?.artwork, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(hex: 0x2B2F36)
                    Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .light))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.small)
                .strokeBorder(Theme.separator, lineWidth: 1)
        }
    }

    private func openPlayer() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows
        where window.identifier?.rawValue.contains("main-AppWindow") == true {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
