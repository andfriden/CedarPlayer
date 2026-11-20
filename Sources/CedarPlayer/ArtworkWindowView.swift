import SwiftUI
import AppKit

/// Окно «Обложка» 430×560: крупная обложка 380×380, подпись и минимальное управление.
struct ArtworkWindowView: View {
    @EnvironmentObject private var engine: PlayerEngine

    var body: some View {
        VStack(spacing: 14) {
            artwork
                .frame(width: 380, height: 380)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)

            VStack(spacing: 3) {
                Text(engine.currentTrack?.displayTitle ?? "Ничего не играет")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(engine.currentTrack?.displayArtist ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                Text(engine.currentTrack?.displayAlbum ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }

            HStack(spacing: 24) {
                Button { engine.previous() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 15))
                }
                .buttonStyle(.plain)

                Button { engine.toggle() } label: {
                    Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)

                Button { engine.next(manual: true) } label: {
                    Image(systemName: "forward.fill").font(.system(size: 15))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white.opacity(0.9))

            HStack(spacing: 8) {
                Text(timeText(engine.position))
                Slider(value: Binding(
                    get: { engine.duration > 0 ? engine.position / engine.duration : 0 },
                    set: { engine.seek(to: $0 * engine.duration) }
                ))
                .controlSize(.mini)
                .tint(.white)
                Text(timeText(engine.duration))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: 340)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 430, height: 560)
        .background(
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var artwork: some View {
        Group {
            if let data = engine.currentTrack?.artwork, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.32), Color(white: 0.18)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: 90, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
