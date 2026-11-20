import SwiftUI
import AppKit

/// Главное окно: панель плеера сверху, плейлист снизу. Панель плейлиста
/// сворачивается кнопкой в плеере, пунктом меню и ⌥⌘P, окно подстраивает высоту.
struct MainWindowView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var engine: PlayerEngine
    @AppStorage("showPlaylist") private var showPlaylist = true
    @AppStorage("resumeLastTrack") private var resumeLastTrack = true
    @State private var window: NSWindow?
    @State private var editingTrack: Track?

    private let width: CGFloat = 425
    private let playerHeight: CGFloat = 300
    private let playlistHeight: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            PlayerPane()
                .contextMenu {
                    Button("Изменить теги…") { editingTrack = engine.currentTrack }
                        .disabled(engine.currentTrack == nil)
                }
            if showPlaylist {
                Divider().overlay(.white.opacity(0.10))
                PlaylistPane()
                    .frame(height: playlistHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: width)
        .background(Theme.background)
        .background(WindowAccessor { candidate in
            if window !== candidate { window = candidate }
        })
        .onChange(of: showPlaylist) { newValue in
            resizeWindow(showPlaylist: newValue)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let window else { return }
                window.minSize = NSSize(width: width, height: playerHeight)
                forceDesignSize(window)
                NowPlayingService.shared.attach(engine)
                restoreLastPlayback()
            }
        }
        .animation(.easeInOut(duration: 0.16), value: showPlaylist)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .onReceive(NotificationCenter.default.publisher(for: .editTags)) { _ in
            editingTrack = engine.currentTrack
        }
        .sheet(item: $editingTrack) { track in
            TagEditorSheet(track: track)
                .environmentObject(library)
                .environmentObject(engine)
        }
    }

    /// Восстанавливает последний трек и позицию (настройка «Запоминать последний трек»).
    private func restoreLastPlayback() {
        guard resumeLastTrack, engine.currentTrack == nil else { return }
        let defaults = UserDefaults.standard
        guard let idString = defaults.string(forKey: "lastTrackID"),
              let id = UUID(uuidString: idString) else { return }
        let tracks = library.visibleTracks
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }

        engine.setQueue(tracks, startAt: index, autoplay: false)
        let position = defaults.double(forKey: "lastPosition")
        if position > 0.5 {
            engine.seek(to: position)
        }
    }

    /// Приводит окно к проектным размерам: ширина фиксирована, высота зависит от панели.
    private func forceDesignSize(_ window: NSWindow) {
        let targetHeight = showPlaylist ? playerHeight + playlistHeight : playerHeight
        let frame = window.frame
        let top = frame.maxY
        var target = frame
        target.size.width = width
        target.size.height = targetHeight
        target.origin.y = top - targetHeight
        window.setFrame(target, display: true, animate: false)
    }

    private func resizeWindow(showPlaylist: Bool) {
        guard let window else { return }
        let target = NSSize(width: width, height: showPlaylist ? playerHeight + playlistHeight : playerHeight)
        let frame = window.frame
        let top = frame.maxY
        window.minSize = NSSize(width: width, height: playerHeight)

        var newFrame = frame
        newFrame.size = target
        newFrame.origin.y = top - target.height
        window.setFrame(newFrame, display: true, animate: true)
        _ = frame
    }
}

/// Достаёт NSWindow, в котором размещено SwiftUI-представление.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}
