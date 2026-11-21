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

/// Скорость вращения «пластинки»: 33⅓ об/мин, как у винила и в мини-плеере
/// Яндекс.Музыки.
enum MiniRotation {
    static let degreesPerSecond: Double = 200

    static func advance(_ angle: Double, by seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else { return angle }
        return (angle + degreesPerSecond * seconds).truncatingRemainder(dividingBy: 360)
    }
}

/// Компактный мини-плеер: вращающаяся «пластинка» с обложкой, две строки
/// текста, тонкий прогресс и кнопки. Окно тянется за угол.
struct MiniPlayerView: View {
    @EnvironmentObject private var engine: PlayerEngine
    @EnvironmentObject private var library: Library

    @State private var angle: Double = 0
    @State private var lastTick: Date?
    @State private var miniWindow: NSWindow?
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            vinyl
                .frame(width: 62, height: 62)

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
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Theme.Space.xs) {
                Button { engine.previous() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Предыдущий трек")
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
                .accessibilityLabel(engine.isPlaying ? "Пауза" : "Воспроизвести")
                Button { engine.next(manual: true) } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Следующий трек")
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
        .onAppear { setMainWindowHidden(true) }
        .onDisappear { setMainWindowHidden(false) }
        .onReceive(tick) { now in
            guard engine.isPlaying else {
                lastTick = nil
                return
            }
            if let lastTick {
                angle = MiniRotation.advance(angle, by: now.timeIntervalSince(lastTick))
            }
            lastTick = now
        }
    }

    /// Закрывает мини-плеер; главное окно вернёт onDisappear.
    private func returnToMain() {
        if let miniWindow {
            miniWindow.close()
            return
        }
        guard NSApp != nil else { return }
        for window in NSApp.windows where window.title == "Мини-плеер" {
            window.close()
        }
    }

    /// Пока открыт мини-плеер, основное окно убрано; после закрытия возвращается.
    private func setMainWindowHidden(_ hidden: Bool) {
        // В CLI-рендере AppKit ещё не запущен: не трогаем окна.
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

    // MARK: Пластинка

    private var vinyl: some View {
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
            Circle()
                .fill(Theme.panel)
                .frame(width: 6, height: 6)
        }
        .rotationEffect(.degrees(angle))
        .overlay {
            Circle().strokeBorder(.white.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }

    @ViewBuilder
    private var coverCircle: some View {
        if let data = engine.currentTrack?.artwork, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(Color(hex: 0x2B2F36))
                Image(systemName: "music.note")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(Theme.secondaryText.opacity(0.8))
            }
        }
    }

    // MARK: Прогресс

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
