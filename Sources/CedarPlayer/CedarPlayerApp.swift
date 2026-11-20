import SwiftUI
import AppKit
import MediaPlayer

@main
struct CedarPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = Library()
    @StateObject private var engine = PlayerEngine()
    @AppStorage("showPlaylist") private var showPlaylist = true
    @AppStorage("meterStyle") private var meterStyleRaw = MeterStyle.segments.rawValue
    @Environment(\.openWindow) private var openWindow

    init() {
        if let path = Self.selfTestPath() {
            Self.runSelfTest(path: path)
        }
        if CommandLine.arguments.contains("--eqdump") {
            let d = UserDefaults.standard
            let engine = PlayerEngine()
            print("EQ enabled=\(engine.isEQEnabled) preamp=\(engine.preamp)")
            print("EQ bands=\(engine.bands.map { String(format: "%.1f", $0) }.joined(separator: ","))")
            exit(0)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--import") {
            var paths: [String] = []
            var cursor = index + 1
            while cursor < CommandLine.arguments.count, !CommandLine.arguments[cursor].hasPrefix("--") {
                paths.append(CommandLine.arguments[cursor])
                cursor += 1
            }
            Self.runImportTest(paths: paths)
        }

        if let path = Self.argumentValue("--cuesheet") {
            guard let sheet = CueParser.parse(url: URL(fileURLWithPath: path)) else {
                print("CUE parse failed"); exit(1)
            }
            print("CUE file=\(sheet.fileURL.lastPathComponent) album=\(sheet.title) performer=\(sheet.performer) tracks=\(sheet.tracks.count)")
            for track in sheet.tracks {
                print(String(format: "  %02d %@ %@ start=%.2f end=%@", track.number, track.title,
                             track.performer, track.start,
                             track.end.map { String(format: "%.2f", $0) } ?? "-"))
            }
            exit(0)
        }

        if let path = Self.argumentValue("--segment") {
            let args = CommandLine.arguments
            let index = args.count > (args.firstIndex(of: "--segment") ?? 0) + 2
                ? Int(args[(args.firstIndex(of: "--segment") ?? 0) + 2]) ?? 0 : 0
            Self.runSegmentTest(cuePath: path, index: index)
        }

        if let path = Self.argumentValue("--writetags") {
            let url = URL(fileURLWithPath: path)
            var edit = TagEdit(title: "", artist: "", album: "", albumArtist: "", trackNumber: 0)
            for argument in CommandLine.arguments where argument.contains("=") {
                let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0].lowercased() {
                case "title": edit.title = parts[1]
                case "artist": edit.artist = parts[1]
                case "album": edit.album = parts[1]
                case "albumartist": edit.albumArtist = parts[1]
                case "track": edit.trackNumber = Int(parts[1]) ?? 0
                default: break
                }
            }
            do {
                try TagWriter.write(edit, to: url)
                let tags = TagReader.read(url: url)
                print("WRITE ok title=\(tags.title ?? "-") artist=\(tags.artist ?? "-") album=\(tags.album ?? "-") albumArtist=\(tags.albumArtist ?? "-") track=\(tags.trackNumber.map(String.init) ?? "-") artwork=\(tags.artwork?.count ?? 0)")
                exit(0)
            } catch {
                print("WRITE failed: \(error.localizedDescription)")
                exit(1)
            }
        }

        if let path = Self.argumentValue("--render-ui") {
            Self.runRenderUITest(path: path)
        }

        if let path = Self.argumentValue("--albums") {
            Self.runAlbumsTest(path: path)
        }

        if let path = Self.argumentValue("--nowplaying") {
            Self.runNowPlayingTest(path: path)
        }

        if let path = Self.argumentValue("--tags") {
            let tags = TagReader.read(url: URL(fileURLWithPath: path))
            print("TAGS title=\(tags.title ?? "-") artist=\(tags.artist ?? "-") album=\(tags.album ?? "-") albumArtist=\(tags.albumArtist ?? "-") track=\(tags.trackNumber.map(String.init) ?? "-")")
            print("TAGS artworkBytes=\(tags.artwork?.count ?? 0) sampleRate=\(tags.sampleRate ?? 0) bitDepth=\(tags.bitDepth ?? 0) channels=\(tags.channels ?? 0) duration=\(String(format: "%.2f", tags.duration ?? 0))")
            exit(0)
        }
    }

    private static func argumentValue(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), args.count > index + 1 else { return nil }
        return args[index + 1]
    }

    /// Проверка движка без интерфейса: `CedarPlayer --selftest /путь/файл.wav`
    private static func selfTestPath() -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--selftest"), args.count > index + 1 else { return nil }
        return args[index + 1]
    }

    @MainActor
    private static func runImportTest(paths: [String]) -> Never {
        let library = Library()
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let imported = await library.importFiles(urls)
            print("IMPORT count=\(imported.count) status=\(library.statusMessage ?? "-")")
            for track in imported {
                print(String(format: "  %@ | %@ | %@ | cue=%@..%@ | dur=%.2f | art=%d | %@",
                             track.title, track.artist, track.album,
                             track.cueStart.map { String(format: "%.2f", $0) } ?? "-",
                             track.cueEnd.map { String(format: "%.2f", $0) } ?? "-",
                             track.duration, track.artwork?.count ?? 0, track.qualityText))
            }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        // Дать библиотеке сохранить состояние (debounce 0.6 с).
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        exit(0)
    }

    /// Отрисовка интерфейса в PNG без экрана (для проверки вёрстки).
    /// Требует CEDAR_LIBRARY_DIR, чтобы не тронуть рабочую библиотеку.
    private static func runRenderUITest(path: String) -> Never {
        guard ProcessInfo.processInfo.environment["CEDAR_LIBRARY_DIR"] != nil else {
            print("render-ui: задайте CEDAR_LIBRARY_DIR, чтобы не затронуть рабочую библиотеку")
            exit(1)
        }
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let engine = PlayerEngine()
            let library = Library()

            let art = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/cover-test.png"))
            var sample: [Track] = []
            let names = ["Midnight City", "Reunion", "Wait", "Outro"]
            for (index, name) in names.enumerated() {
                var track = Track(url: URL(fileURLWithPath: "/tmp/cedar-ui-demo-\(index).flac"))
                track.title = name
                track.artist = "M83"
                track.album = "Hurry Up, We're Dreaming"
                track.duration = 243
                track.artwork = art
                sample.append(track)
            }
            var current = Track(url: URL(fileURLWithPath: "/tmp/cedar-music/cover.flac"))
            current.title = "Midnight City"
            current.artist = "M83"
            current.album = "Hurry Up, We're Dreaming"
            current.sampleRate = 44100
            current.bitDepth = 16
            current.channels = 2
            current.duration = 243
            current.artwork = art
            library.tracks = [current] + sample.dropFirst()
            engine.setQueue([current], startAt: 0, autoplay: true)
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            if let style = ProcessInfo.processInfo.environment["CEDAR_RENDER_STYLE"] {
                UserDefaults.standard.set(style, forKey: "meterStyle")
            }

            let view = VStack(spacing: 0) {
                PlayerPane()
                Divider().overlay(Theme.separator)
                PlaylistPane(scrolling: false)
                    .frame(height: 299)
            }
            .environmentObject(library)
            .environmentObject(engine)
            .frame(width: 425, height: 600)
            .background(Theme.background)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let cgImage = renderer.cgImage else {
                print("render-ui: не удалось отрисовать")
                exit(1)
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                print("render-ui: не удалось закодировать PNG")
                exit(1)
            }
            try? png.write(to: URL(fileURLWithPath: path))
            print("render-ui: \(path) \(cgImage.width)x\(cgImage.height)")
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        exit(0)
    }

    /// Проверка группировки по альбомам: импорт папки и печать групп.
    private static func runAlbumsTest(path: String) -> Never {
        let library = Library()
        let url = URL(fileURLWithPath: path)
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await library.importFiles([url])
            for album in AlbumGroup.group(library.tracks) {
                print("ALBUM \(album.title) | \(album.artist) | tracks=\(album.tracks.count) | dur=\(Int(album.duration)) | art=\(album.artwork?.count ?? 0)")
                for track in album.tracks {
                    print("   \(track.trackNumber). \(track.displayTitle) — \(track.displayArtist)")
                }
            }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        exit(0)
    }

    /// Проверка интеграции с Now Playing и медиа-клавишами без интерфейса.
    private static func runNowPlayingTest(path: String) -> Never {
        let url = URL(fileURLWithPath: path)
        let engine = PlayerEngine()
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let track = await MetadataReader.read(url: url)
            engine.setQueue([track], startAt: 0, autoplay: false)
            NowPlayingService.shared.attach(engine)
            NowPlayingService.shared.refreshNow()

            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            print("NP title=\(info[MPMediaItemPropertyTitle] ?? "-")")
            print("NP artist=\(info[MPMediaItemPropertyArtist] ?? "-") album=\(info[MPMediaItemPropertyAlbumTitle] ?? "-")")
            print(String(format: "NP elapsed=%.2f duration=%.2f rate=%.1f artwork=%@",
                         (info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) ?? -1,
                         (info[MPMediaItemPropertyPlaybackDuration] as? Double) ?? -1,
                         (info[MPNowPlayingInfoPropertyPlaybackRate] as? Double) ?? -1,
                         info[MPMediaItemPropertyArtwork] == nil ? "no" : "yes"))
            let remote = MPRemoteCommandCenter.shared()
            print("NP state=\(MPNowPlayingInfoCenter.default().playbackState.rawValue) next=\(remote.nextTrackCommand.isEnabled) seek=\(remote.changePlaybackPositionCommand.isEnabled) toggle=\(remote.togglePlayPauseCommand.isEnabled)")

            engine.play()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        print(String(format: "NP playing elapsed=%.2f rate=%.1f state=%d",
                     (updated[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) ?? -1,
                     (updated[MPNowPlayingInfoPropertyPlaybackRate] as? Double) ?? -1,
                     MPNowPlayingInfoCenter.default().playbackState.rawValue))
        exit(0)
    }

    @MainActor
    private static func runSegmentTest(cuePath: String, index: Int) -> Never {
        guard let sheet = CueParser.parse(url: URL(fileURLWithPath: cuePath)),
              sheet.tracks.indices.contains(index) else {
            print("SEGMENT error: cue/трек не найдены"); exit(2)
        }
        let entry = sheet.tracks[index]
        var track = Track(url: sheet.fileURL)
        track.title = entry.title
        track.artist = entry.performer
        track.album = sheet.title
        track.cueStart = entry.start
        track.cueEnd = entry.end

        let engine = PlayerEngine()
        engine.setQueue([track], startAt: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        print(String(format: "SEGMENT %02d title=%@ duration=%.2f position=%.2f playing=%@ error=%@",
                     entry.number, entry.title, engine.duration, engine.position,
                     engine.isPlaying ? "yes" : "no", engine.errorMessage ?? "нет"))
        exit(engine.errorMessage == nil ? 0 : 1)
    }

    @MainActor
    private static func runSelfTest(path: String) -> Never {
        let engine = PlayerEngine()
        let url = URL(fileURLWithPath: path)
        var report: [String] = []
        guard FileManager.default.fileExists(atPath: path) else {
            print("SELFTEST error: файл не найден")
            exit(2)
        }
        let track = Track(url: url)
        engine.setQueue([track], startAt: 0)
        report.append("loaded=\(engine.currentTrack != nil)")
        report.append("duration=\(String(format: "%.2f", engine.duration))")
        report.append("error=\(engine.errorMessage ?? "нет")")
        engine.play()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        report.append("playing=\(engine.isPlaying)")
        report.append("position=\(String(format: "%.2f", engine.position))")
        report.append("spectrumMax=\(String(format: "%.3f", engine.spectrum.max() ?? 0))")
        report.append("spectrumBands=\(engine.spectrum.count)")
        report.append("levelL=\(String(format: "%.2f", engine.levelL))")
        report.append("levelR=\(String(format: "%.2f", engine.levelR))")
        report.append("peak=\(String(format: "%.2f", engine.peakL))")
        engine.apply(preset: PlayerEngine.presets[1])
        report.append("eq=\(engine.isEQEnabled) bands=\(engine.bands.count) dsp=\(engine.usesDSPEqualizer)")
        engine.seek(to: engine.duration / 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        report.append("seek=\(String(format: "%.2f", engine.position))")
        engine.pause()
        report.append("paused=\(!engine.isPlaying)")
        print("SELFTEST " + report.joined(separator: " "))
        exit(engine.errorMessage == nil && engine.duration > 0 ? 0 : 1)
    }

    var body: some Scene {
        WindowGroup("Cedar Player", id: "main") {
            MainWindowView()
                .environmentObject(library)
                .environmentObject(engine)
                .onAppear { appDelegate.configure(library: library, engine: engine) }
        }
        .defaultSize(width: 425, height: 1006)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Добавить файлы…") { library.presentImportPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Окно обложки") { openWindow(id: "albumart") }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            CommandMenu("Управление") {
                Button(engine.isPlaying ? "Пауза" : "Воспроизвести") { engine.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(engine.currentTrack == nil)
                Button("Следующий трек") { engine.next(manual: true) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Предыдущий трек") { engine.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("Отменить импорт") { library.cancelImport() }
                    .disabled(!library.isImporting)
                Button("Изменить теги…") {
                    NotificationCenter.default.post(name: .editTags, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(engine.currentTrack == nil)
                Divider()
                Button("Громче") { engine.volume = min(1, engine.volume + 0.1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Тише") { engine.volume = max(0, engine.volume - 0.1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button(engine.isMuted ? "Включить звук" : "Заглушить") { engine.isMuted.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Toggle("Перемешивание", isOn: $engine.isShuffle)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Picker("Повтор", selection: $engine.repeatMode) {
                    Text("Выключен").tag(RepeatMode.off)
                    Text("Список").tag(RepeatMode.all)
                    Text("Один трек").tag(RepeatMode.one)
                }
                Divider()
                Button("Эквалайзер") { openWindow(id: "equalizer") }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Текст песни") { openWindow(id: "lyrics") }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Мини-плеер") { openWindow(id: "mini") }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Divider()
                Menu("Индикатор") {
                    ForEach(MeterStyle.allCases) { style in
                        Button(style.title) { meterStyleRaw = style.rawValue }
                    }
                    Divider()
                    Button("Аналоговый VU-метр") { openWindow(id: "vu") }
                        .keyboardShortcut("u", modifiers: .command)
                }

                Toggle("Плейлист", isOn: $showPlaylist)
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Библиотека") { openWindow(id: "library") }
                    .keyboardShortcut("b", modifiers: .command)
            }
        }

        Window("Библиотека", id: "library") {
            ContentView()
                .environmentObject(library)
                .environmentObject(engine)
        }
        .defaultSize(width: 900, height: 560)

        Window("VU-метр", id: "vu") {
            AnalogVUMeterView()
                .preferredColorScheme(.dark)
                .environmentObject(engine)
        }
        .defaultSize(width: 472, height: 276)

        Window("Обложка", id: "albumart") {
            ArtworkWindowView()
                .preferredColorScheme(.dark)
                .environmentObject(library)
                .environmentObject(engine)
        }
        .defaultSize(width: 430, height: 560)
        .keyboardShortcut("1", modifiers: [.command])

        Window("Эквалайзер", id: "equalizer") {
            EqualizerView()
                .preferredColorScheme(.dark)
                .environmentObject(engine)
        }
        .defaultSize(width: 700, height: 480)
        .windowResizability(.contentSize)

        Window("Текст песни", id: "lyrics") {
            LyricsView()
                .environmentObject(engine)
        }
        .defaultSize(width: 480, height: 460)

        Window("Мини-плеер", id: "mini") {
            MiniPlayerView()
                .environmentObject(library)
                .environmentObject(engine)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(library)
                .environmentObject(engine)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var engine: PlayerEngine?
    private weak var library: Library?

    func configure(library: Library, engine: PlayerEngine) {
        self.library = library
        self.engine = engine
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let library, let engine else { return }
        Task { @MainActor in
            let imported = await library.importFiles(urls)
            guard let first = imported.first else { return }
            let queue = library.visibleTracks
            if let index = queue.firstIndex(where: { $0.id == first.id }) {
                engine.setQueue(queue, startAt: index)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
