import SwiftUI
import AppKit

/// Main window: player pane on top, playlist below. The playlist pane
/// hides via a button in the player, a menu item and ⌥⌘P; the window shrinks
/// to the player and restores the remembered height.
struct MainWindowView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.player) private var player
    @AppStorage("showPlaylist") private var showPlaylist = true
    @AppStorage("resumeLastTrack") private var resumeLastTrack = true
    @State private var window: NSWindow?
    @State private var editingTrack: Track?
    @State private var playlistHeight: CGFloat?
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 0) {
            PlayerPane()
                .padding(.horizontal, Theme.Layout.contentPadding)
                .contextMenu {
                    EditTagsMenuItem { track in editingTrack = track }
                }
            if showPlaylist {
                Rectangle()
                    .fill(Theme.Cyber.separator)
                    .frame(height: 1)
                    .padding(.vertical, 8)
                PlaylistPane()
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minWidth: Theme.Layout.minWidth,
               minHeight: showPlaylist
                   ? Theme.Layout.minHeight - Theme.Layout.titleBarHeight
                   : Theme.Layout.playerHeight)
        .background(Theme.Cyber.background)
        .background(WindowAccessor { candidate in
            if window !== candidate { window = candidate }
        })
        .onChange(of: showPlaylist) { newValue in
            resizeWindow(showPlaylist: newValue)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let window else { return }
                configureWindow(window)
                forceDesignSize(window)
                if let player { NowPlayingService.shared.attach(player) }
                if let shotPath = ProcessInfo.processInfo.environment["CEDAR_WINDOW_SHOT"] {
                    prepareScreenshot(path: shotPath)
                } else {
                    restoreLastPlayback()
                }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: showPlaylist)
        .tint(Theme.Cyber.accent)
        .onReceive(NotificationCenter.default.publisher(for: .editTags)) { _ in
            editingTrack = player?.currentTrack
        }
        .task { await updates.checkAtLaunch() }
        .alert(item: $updates.available) { update in
            Alert(title: Text(L10n.format("Доступна версия %@", update.version)),
                  message: Text(L10n.string("Открыть страницу загрузки?")),
                  primaryButton: .default(Text(L10n.string("Открыть"))) {
                      NSWorkspace.shared.open(update.url)
                  },
                  secondaryButton: .cancel(Text(L10n.string("Позже"))) {
                      UserDefaults.standard.set(update.version, forKey: "skippedUpdateVersion")
                  })
        }
        .sheet(item: $editingTrack) { track in
            if let player {
                TagEditorSheet(track: track)
                    .environmentObject(library)
                    .environmentObject(player)
            }
        }
    }

    /// README window snapshot: draws the window's own layer without screen recording.
    private func prepareScreenshot(path: String) {
        let trackPath = ProcessInfo.processInfo.environment["CEDAR_SHOT_TRACK"] ?? ""
        Task { @MainActor in
            if !trackPath.isEmpty {
                let shotURL = URL(fileURLWithPath: trackPath).standardizedFileURL
                if let index = library.tracks.firstIndex(where: { $0.url.standardizedFileURL.path == shotURL.path }) {
                    player?.setQueue(library.tracks, startAt: index, autoplay: true)
                } else {
                    let track = await MetadataReader.read(url: URL(fileURLWithPath: trackPath))
                    player?.setQueue([track], startAt: 0, autoplay: true)
                }
            }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let content = window?.contentView else {
                print("window shot: нет содержимого окна")
                exit(1)
            }
            // Include the custom title bar in the documentation capture.
            var view = content
            while let parent = view.superview { view = parent }
            let scale: CGFloat = 2
            let bounds = view.bounds
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: Int(bounds.width * scale),
                                             pixelsHigh: Int(bounds.height * scale),
                                             bitsPerSample: 8,
                                             samplesPerPixel: 4,
                                             hasAlpha: true,
                                             isPlanar: false,
                                             colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0,
                                             bitsPerPixel: 0) else {
                print("window shot: не удалось создать буфер")
                exit(1)
            }
            rep.size = bounds.size
            view.cacheDisplay(in: bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                print("window shot: не удалось закодировать PNG")
                exit(1)
            }
            try? data.write(to: URL(fileURLWithPath: path))
            print("window shot: \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
            exit(0)
        }
    }

    /// Restores the last track and position ("Remember last track" setting).
    private func restoreLastPlayback() {
        guard resumeLastTrack, let player, player.currentTrack == nil else { return }
        let defaults = UserDefaults.standard
        guard let idString = defaults.string(forKey: "lastTrackID"),
              let id = UUID(uuidString: idString) else { return }
        let tracks = library.visibleTracks
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }

        player.setQueue(tracks, startAt: index, autoplay: false, clearUpNext: false)
        let position = defaults.double(forKey: "lastPosition")
        if position > 0.5 {
            player.seek(to: position)
        }
    }

    /// Resizes the window to its design height; width stays user-resizable.
    private func configureWindow(_ window: NSWindow) {
        window.title = "Cedar Player"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.backgroundColor = NSColor(Theme.Cyber.background)
    }

    private func forceDesignSize(_ window: NSWindow) {
        let compactHeight = Theme.Layout.titleBarHeight + Theme.Layout.playerHeight
        let minimum = showPlaylist ? Theme.Layout.minHeight : compactHeight
        var targetHeight = showPlaylist ? Theme.Layout.defaultHeight : compactHeight
        if let raw = ProcessInfo.processInfo.environment["CEDAR_SHOT_HEIGHT"],
           let requested = Double(raw) {
            targetHeight = max(minimum, requested)
        }
        window.minSize = NSSize(width: Theme.Layout.minWidth, height: minimum)
        let frame = window.frame
        let top = frame.maxY
        var target = frame
        target.size.width = Theme.Layout.width
        if let raw = ProcessInfo.processInfo.environment["CEDAR_SHOT_WIDTH"],
           let requested = Double(raw), requested >= Theme.Layout.minWidth {
            target.size.width = requested
        }
        target.size.height = targetHeight
        target.origin.y = top - targetHeight
        window.setFrame(target, display: true, animate: false)
    }

    private func resizeWindow(showPlaylist: Bool) {
        guard let window else { return }
        let compactHeight = Theme.Layout.titleBarHeight + Theme.Layout.playerHeight
        let frame = window.frame
        let top = frame.maxY
        var target = frame

        if showPlaylist {
            target.size.height = max(playlistHeight ?? Theme.Layout.defaultHeight,
                                     Theme.Layout.minHeight)
        } else {
            if frame.height > compactHeight + 1 {
                playlistHeight = frame.height
            }
            window.minSize = NSSize(width: Theme.Layout.minWidth, height: compactHeight)
            target.size.height = compactHeight
        }

        target.origin.y = top - target.size.height
        window.setFrame(target, display: true, animate: true)

        if showPlaylist {
            // Raising minSize before the animation forces an instant jump.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard (UserDefaults.standard.object(forKey: "showPlaylist") as? Bool) ?? true,
                      window.frame.height > compactHeight + 1 else { return }
                window.minSize = NSSize(width: Theme.Layout.minWidth,
                                        height: Theme.Layout.minHeight)
            }
        }
    }
}

/// Finds the NSWindow hosting a SwiftUI view.
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


/// Menu item with live current-track state: subscribes to the engine itself,
/// so the main window does not redraw on every position update.
private struct EditTagsMenuItem: View {
    @EnvironmentObject private var engine: PlayerEngine
    let action: (Track?) -> Void

    var body: some View {
        Button("Изменить теги…") { action(engine.currentTrack) }
            .disabled(engine.currentTrack == nil)
    }
}
