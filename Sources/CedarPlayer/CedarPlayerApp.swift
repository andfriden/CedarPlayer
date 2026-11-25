import SwiftUI
import AppKit
import AVFoundation
import MediaPlayer

@main
struct CedarPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = Library()
    @StateObject private var engine = PlayerEngine()
    @AppStorage("showPlaylist") private var showPlaylist = true
    @AppStorage("meterStyle") private var meterStyleRaw = MeterStyle.spectrum.rawValue
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue
    @AppStorage("accentChoice") private var accentChoice = AccentChoice.theme.rawValue
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    @Environment(\.openWindow) private var openWindow

    init() {
        if let path = Self.selfTestPath() {
            Self.runSelfTest(path: path)
        }
        if CommandLine.arguments.contains("--eqdump") {
            let engine = PlayerEngine()
            print("EQ enabled=\(engine.isEQEnabled) preamp=\(engine.preamp) replayGain=\(engine.isReplayGainEnabled)")
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
                case "genre": edit.genre = parts[1]
                case "year": edit.year = parts[1]
                case "composer": edit.composer = parts[1]
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

        if let index = CommandLine.arguments.firstIndex(of: "--embedcover") {
            let rest = Array(CommandLine.arguments.dropFirst(index + 1))
            guard rest.count >= 2 else { print("нужны файл и картинка"); exit(1) }
            do {
                let image = try Data(contentsOf: URL(fileURLWithPath: rest[1]))
                try TagWriter.embedArtwork(image, in: URL(fileURLWithPath: rest[0]))
                let tags = TagReader.read(url: URL(fileURLWithPath: rest[0]))
                print("EMBED ok artwork=\(tags.artwork?.count ?? 0) title=\(tags.title ?? "-")")
                exit(0)
            } catch {
                print("EMBED failed: \(error.localizedDescription)")
                exit(1)
            }
        }

        if CommandLine.arguments.contains("--audiodevices") {
            let engine = PlayerEngine()
            print("AUDIO default=\(AudioDevices.defaultOutputUID ?? "-")")
            for device in engine.outputDevices {
                print("AUDIO device=\(device.name) uid=\(device.id) channels=\(device.channels)")
            }
            if let index = CommandLine.arguments.firstIndex(of: "--audiodevices"),
               CommandLine.arguments.count > index + 1 {
                engine.selectOutput(uid: CommandLine.arguments[index + 1])
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            }
            print("AUDIO selected=\(engine.selectedOutputUID ?? "-") format=\(engine.outputFormatDescription) error=\(engine.errorMessage ?? "-")")
            exit(0)
        }

        if CommandLine.arguments.contains("--bench") {
            Self.runBench()
        }

        if let path = Self.argumentValue("--snapshots") {
            Self.runSnapshots(path: path)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-compare") {
            let rest = Array(CommandLine.arguments.dropFirst(index + 1))
            guard rest.count >= 2 else { print("нужны каталог снимков и эталонов"); exit(1) }
            Self.runSnapshotCompare(output: rest[0], baseline: rest[1])
        }

        if CommandLine.arguments.contains("--doctor") {
            Self.runDoctor()
        }

        if let index = CommandLine.arguments.firstIndex(of: "--watchtest") {
            guard ProcessInfo.processInfo.environment["CEDAR_LIBRARY_DIR"] != nil else {
                print("watchtest: задайте CEDAR_LIBRARY_DIR")
                exit(1)
            }
            let rest = Array(CommandLine.arguments.dropFirst(index + 1))
            guard rest.count >= 2 else { print("нужны папка и файл"); exit(1) }
            let library = Library()
            let folder = URL(fileURLWithPath: rest[0])
            library.addWatchFolder(folder)
            let source = URL(fileURLWithPath: rest[1])
            let target = folder.appendingPathComponent("watch-added-" + source.lastPathComponent)
            try? FileManager.default.copyItem(at: source, to: target)
            RunLoop.main.run(until: Date().addingTimeInterval(4.0))
            print("WATCH tracks=\(library.tracks.count) status=\(library.statusMessage ?? "-")")
            exit(0)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--gapless") {
            let rest = Array(CommandLine.arguments.dropFirst(index + 1))
            guard rest.count >= 2 else { print("нужны два файла"); exit(1) }
            let engine = PlayerEngine()
            var first = Track(url: URL(fileURLWithPath: rest[0])); first.title = "A"
            var second = Track(url: URL(fileURLWithPath: rest[1])); second.title = "B"
            engine.setQueue([first, second], startAt: 0, autoplay: false)
            engine.crossfadeSeconds = 0
            engine.transitionFadeSeconds = 1.0
            engine.play()
            RunLoop.main.run(until: Date().addingTimeInterval(4.5))
            let gap = engine.lastTransitionGap.map { String(format: "%.1f", $0 * 1000) } ?? "-"
            print("GAPLESS current=\(engine.currentTrack?.title ?? "-") playing=\(engine.isPlaying) gapMs=\(gap)")
            exit(0)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--crossfadetest") {
            let rest = Array(CommandLine.arguments.dropFirst(index + 1))
            guard rest.count >= 2 else { print("нужны два файла"); exit(1) }
            let engine = PlayerEngine()
            var first = Track(url: URL(fileURLWithPath: rest[0]))
            first.title = "A"
            var second = Track(url: URL(fileURLWithPath: rest[1]))
            second.title = "B"
            engine.setQueue([first, second], startAt: 0, autoplay: false)
            engine.crossfadeSeconds = 1.5
            engine.play()
            RunLoop.main.run(until: Date().addingTimeInterval(3.2))
            print(String(format: "CROSSFADE current=%@ playing=%@ pos=%.2f", engine.currentTrack?.title ?? "-", engine.isPlaying ? "true" : "false", engine.position))
            exit(0)
        }

        if let path = Self.argumentValue("--logotest") {
            let station = RadioStation(name: "Тест", urlString: path)
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                let data = await RadioLogoLoader.load(station)
                print("LOGO bytes=\(data?.count ?? 0) image=\(data != nil)")
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            exit(0)
        }

        if let path = Self.argumentValue("--radiotest") {
            let engine = PlayerEngine()
            let urlString = path.hasPrefix("http://") || path.hasPrefix("https://")
                ? path
                : URL(fileURLWithPath: path).absoluteString
            let station = RadioStation(name: "Проверка", urlString: urlString)
            engine.playRadio(station)
            RunLoop.main.run(until: Date().addingTimeInterval(6))
            print("RADIO station=\(engine.currentStation?.name ?? "-") playing=\(engine.isPlaying) trackEmpty=\(engine.currentTrack == nil) artist=\(engine.radioArtist ?? "-") track=\(engine.radioTrack ?? "-") error=\(engine.errorMessage ?? "-")")
            engine.pause()
            print("RADIO paused=\(!engine.isPlaying)")
            exit(0)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--playlist-import") {
            let rest = Array(CommandLine.arguments.dropFirst(index + 1))
            Self.runPlaylistImportTest(path: rest.first ?? "", name: rest.count > 1 ? rest[1] : "Плейлист")
        }

        if let index = CommandLine.arguments.firstIndex(of: "--cover") {
            let rest = Array(CommandLine.arguments.dropFirst(index + 1))
            Self.runCoverTest(artist: rest.first ?? "", album: rest.count > 1 ? rest[1] : "")
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
            print("TAGS title=\(tags.title ?? "-") artist=\(tags.artist ?? "-") album=\(tags.album ?? "-") albumArtist=\(tags.albumArtist ?? "-") track=\(tags.trackNumber.map(String.init) ?? "-") genre=\(tags.genre ?? "-") year=\(tags.year ?? "-") composer=\(tags.composer ?? "-") disc=\(tags.discNumber.map(String.init) ?? "-")")
            print("TAGS artworkBytes=\(tags.artwork?.count ?? 0) sampleRate=\(tags.sampleRate ?? 0) bitDepth=\(tags.bitDepth ?? 0) channels=\(tags.channels ?? 0) duration=\(String(format: "%.2f", tags.duration ?? 0)) replayGain=\(tags.replayGainDB.map { String(format: "%.2f", $0) } ?? "-") peak=\(tags.replayGainPeak.map { String(format: "%.3f", $0) } ?? "-")")
            exit(0)
        }
    }

    private static func argumentValue(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), args.count > index + 1 else { return nil }
        return args[index + 1]
    }

    /// Headless engine check: `CedarPlayer --selftest /path/file.wav`
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
        // Let the library persist state and wait for automatic artwork search.
        let wait: TimeInterval = ProcessInfo.processInfo.environment["CEDAR_WAIT_IMPORT"] != nil ? 8 : 1.0
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        exit(0)
    }

    // MARK: Large library benchmark

    private static func runBench() -> Never {
        let count = Int(Self.argumentValue("--tracks") ?? "") ?? 10000
        let playlistSize = min(count, Int(Self.argumentValue("--playlist") ?? "") ?? 5000)
        var tracks: [Track] = []
        tracks.reserveCapacity(count)
        for index in 0..<count {
            var track = Track(url: URL(fileURLWithPath: "/tmp/bench/\(index).flac"))
            track.title = "Track \(index)"
            track.artist = "Artist \(index % 100)"
            track.album = "Album \(index % 250)"
            track.duration = 120 + Double(index % 240)
            track.addedAt = Date(timeIntervalSince1970: Double(index))
            tracks.append(track)
        }
        let library = Library(testTracks: tracks)
        var playlist = Playlist(name: "Bench")
        playlist.trackIDs = tracks.prefix(playlistSize).map(\.id)
        library.playlists = [playlist]

        func measure(_ name: String, iterations: Int, _ body: () -> Int) {
            _ = body()
            let start = Date()
            var sink = 0
            for _ in 0..<iterations { sink &+= body() }
            let ms = Date().timeIntervalSince(start) / Double(iterations) * 1000
            print(String(format: "BENCH %@ avg=%.2f ms sink=%d", name, ms, sink))
        }

        print("BENCH tracks=\(count) playlist=\(playlistSize)")
        measure("visibleTracks", iterations: 20) { library.visibleTracks.count }
        measure("playlistTracks", iterations: 20) { library.tracks(in: playlist).count }
        measure("sortedPlaylistQuery", iterations: 20) {
            let list = library.tracks(in: playlist).sorted {
                $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
            }
            return list.count
        }
        var searchCounter = 0
        measure("querySearchCold", iterations: 20) {
            searchCounter += 1
            return library.query(filterID: "all",
                                 search: "Track \(searchCounter)",
                                 sortKey: .title,
                                 ascending: true).tracks.count
        }
        exit(0)
    }

    // MARK: UI snapshots

    private static func snapshotView(_ name: String, scheme: ColorScheme) -> AnyView {
        let engine = PlayerEngine()
        engine.isEQEnabled = true
        engine.apply(preset: PlayerEngine.presets[0])
        var tracks: [Track] = []
        for index in 0..<6 {
            var track = Track(url: URL(fileURLWithPath: "/tmp/snapshot-track-\(index).flac"))
            track.title = "Трек \(index + 1)"
            track.artist = "Исполнитель"
            track.album = "Альбом"
            track.duration = 180 + Double(index) * 12
            track.rating = index % 6
            tracks.append(track)
        }
        let library = Library(testTracks: tracks)

        let base: AnyView
        switch name {
        case "player":
            base = AnyView(PlayerPane().environmentObject(engine).environmentObject(library))
        case "playlist":
            base = AnyView(PlaylistPane(scrolling: false).environmentObject(engine).environmentObject(library))
        case "equalizer":
            base = AnyView(EqualizerView().environmentObject(engine))
        case "vu":
            base = AnyView(AnalogVUMeterView(preview: VULevels(left: 0.70, right: 0.52,
                                                              peakLeft: 0.98, peakRight: 0.60))
                .environmentObject(engine))
        case "mini":
            base = AnyView(MiniPlayerView().environmentObject(engine).environmentObject(library))
        case "menubar":
            base = AnyView(MenuBarPlayerView().environmentObject(engine).environmentObject(library))
        default:
            base = AnyView(EmptyView())
        }
        return AnyView(base.preferredColorScheme(scheme))
    }

    private static let snapshotSizes: [(String, CGFloat, CGFloat)] = [
        ("player", Theme.Layout.width, Theme.Layout.playerHeight),
        ("playlist", Theme.Layout.width, Theme.Layout.playlistHeight),
        ("equalizer", 760, 540),
        ("vu", 520, 300),
        ("mini", 320, 96),
        ("menubar", 300, 170)
    ]

    private static func runSnapshots(path: String) -> Never {
        let directory = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        defaults.set("segments", forKey: "meterStyle")
        defaults.set("ru", forKey: "appLanguage")
        defaults.set("all", forKey: "playlistFilter")
        defaults.set(SortKey.added.rawValue, forKey: "sortKey")
        defaults.set(true, forKey: "playlistSortAscending")

        var written = 0
        for (name, width, height) in snapshotSizes {
            for scheme in [ColorScheme.dark, .light] {
                let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                Theme.forcedDark = scheme == .dark
                NSAppearance.current = appearance ?? NSAppearance.current
                let view = snapshotView(name, scheme: scheme)
                let renderer = ImageRenderer(content: view.frame(width: width, height: height))
                renderer.scale = 2
                guard let cgImage = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                    print("SNAPSHOTS failed=\(name)-\(scheme)")
                    continue
                }
                let file = directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
                try? png.write(to: file)
                written += 1
            }
        }
        Theme.forcedDark = nil
        print("SNAPSHOTS dir=\(directory.path) files=\(written)")
        exit(0)
    }

    private static func runSnapshotCompare(output: String, baseline: String) -> Never {
        let fm = FileManager.default
        let outputDir = URL(fileURLWithPath: output)
        let baselineDir = URL(fileURLWithPath: baseline)
        guard let files = try? fm.contentsOfDirectory(at: baselineDir, includingPropertiesForKeys: nil) else {
            print("SNAPSHOT COMPARE: эталоны не найдены")
            exit(1)
        }
        var failures = 0
        var compared = 0
        for expected in files.filter({ $0.pathExtension == "png" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let actual = outputDir.appendingPathComponent(expected.lastPathComponent)
            guard fm.fileExists(atPath: actual.path) else {
                print("SNAPSHOT missing=\(expected.lastPathComponent)")
                failures += 1
                continue
            }
            let diff = imageDifference(expected, actual)
            compared += 1
            let percent = (diff ?? 1) * 100
            print(String(format: "SNAPSHOT %@ diff=%.2f%%", expected.lastPathComponent, percent))
            if percent > 10 { failures += 1 }
        }
        print("SNAPSHOT COMPARE files=\(compared) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// Mean brightness difference after scaling to 64×64; tolerates font smoothing.
    private static func imageDifference(_ lhs: URL, _ rhs: URL) -> Double? {
        guard let left = graySamples(lhs), let right = graySamples(rhs) else { return nil }
        var sum = 0
        for index in 0..<min(left.count, right.count) {
            sum += abs(Int(left[index]) - Int(right[index]))
        }
        return Double(sum) / Double(min(left.count, right.count)) / 255
    }

    private static func graySamples(_ url: URL) -> [UInt8]? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 64
        var data = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &data,
                                      width: side,
                                      height: side,
                                      bitsPerComponent: 8,
                                      bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return data
    }

    /// Diagnostics: library, files, artwork cache and settings.
    private static func runDoctor() -> Never {
        let fm = FileManager.default
        let support = ProcessInfo.processInfo.environment["CEDAR_LIBRARY_DIR"].map { URL(fileURLWithPath: $0) }
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CedarPlayer")
        print("DOCTOR data=\(support.path)")

        var problems = 0
        let probe = support.appendingPathComponent(".write-test")
        do {
            try Data("ok".utf8).write(to: probe)
            try fm.removeItem(at: probe)
            print("DOCTOR writable=true")
        } catch {
            print("DOCTOR writable=false error=\(error.localizedDescription)")
            problems += 1
        }

        let libraryURL = support.appendingPathComponent("library.json")
        var artworkIDs = Set<String>()
        if let data = try? Data(contentsOf: libraryURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let tracks = json["tracks"] as? [[String: Any]] ?? []
            let playlists = json["playlists"] as? [[String: Any]] ?? []
            let stations = json["stations"] as? [[String: Any]] ?? []
            let folders = json["watchFolders"] as? [String] ?? []
            let urls: [URL] = tracks.compactMap { ($0["url"] as? String).flatMap { URL(string: $0) } }
            let missingURLs = urls.filter { !fm.fileExists(atPath: $0.path) }
            let offlineVolumes = Set(missingURLs.compactMap { url -> String? in
                let parts = url.pathComponents
                guard parts.count > 2, parts[1] == "Volumes" else { return nil }
                let root = "/Volumes/\(parts[2])"
                return fm.fileExists(atPath: root) ? nil : root
            })
            let missingOnMounted = missingURLs.filter { url in
                !offlineVolumes.contains { url.path.hasPrefix($0 + "/") }
            }
            let missing = missingURLs
            for track in tracks {
                if let key = track["artworkID"] as? String { artworkIDs.insert(key) }
            }
            print("DOCTOR library bytes=\(data.count) tracks=\(tracks.count) playlists=\(playlists.count) stations=\(stations.count) watch=\(folders.count)")
            print("DOCTOR missingFiles=\(missing.count) offlineVolumes=\(offlineVolumes.sorted().joined(separator: ","))")
            let missingWatch = folders.filter { !fm.fileExists(atPath: $0) }
            if !missingWatch.isEmpty { print("DOCTOR missingWatchFolders=\(missingWatch.count)") }
            if !missingOnMounted.isEmpty {
                print("DOCTOR missingOnMounted=\(missingOnMounted.count)")
                problems += 1
            }
        } else if fm.fileExists(atPath: libraryURL.path) {
            print("DOCTOR library corrupt")
            problems += 1
        } else {
            print("DOCTOR library absent (пустая библиотека)")
        }

        let artworkDir = support.appendingPathComponent("Artwork")
        let files = (try? fm.contentsOfDirectory(at: artworkDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let size = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let orphan = files.map(\.lastPathComponent).filter { !artworkIDs.contains($0) }
        print("DOCTOR artwork files=\(files.count) bytes=\(size) orphan=\(orphan.count)")

        let defaults = UserDefaults.standard
        print("DOCTOR eq=\(defaults.bool(forKey: "eqEnabled")) replayGain=\(defaults.bool(forKey: "replayGainEnabled")) crossfade=\(defaults.object(forKey: "crossfadeSeconds") as? Double ?? 0) fade=\(defaults.object(forKey: "transitionFadeSeconds") as? Double ?? 1)")
        print(problems == 0 ? "DOCTOR result=ok" : "DOCTOR result=issues=\(problems)")
        exit(problems == 0 ? 0 : 1)
    }

    /// Playlist import check: `--playlist-import <folder> <name>`.
    /// Requires CEDAR_LIBRARY_DIR to avoid touching the working library.
    private static func runPlaylistImportTest(path: String, name: String) -> Never {
        guard ProcessInfo.processInfo.environment["CEDAR_LIBRARY_DIR"] != nil else {
            print("playlist-import: задайте CEDAR_LIBRARY_DIR")
            exit(1)
        }
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let library = Library()
            let playlist = library.createPlaylist(named: name)
            let imported = await library.importFiles([URL(fileURLWithPath: path)], into: playlist.id)
            let inPlaylist = library.playlists.first { $0.id == playlist.id }?.trackIDs.count ?? -1

            // Adding a selection must not depend on search.
            library.searchText = "zzz"
            let second = library.createPlaylist(named: "Второй")
            library.add(Set(library.tracks.map(\.id)), to: second.id)
            let inSecond = library.playlists.first { $0.id == second.id }?.trackIDs.count ?? -1
            library.searchText = ""

            print("PLAYLIST name=\(name) imported=\(imported.count) inPlaylist=\(inPlaylist) all=\(library.tracks.count) secondUnderSearch=\(inSecond)")
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        exit(0)
    }

    /// Artwork search check: `--cover "Artist" "Album"`.
    private static func runCoverTest(artist: String, album: String) -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let candidates = try await CoverArtService.shared.search(artist: artist, album: album)
                print("COVER count=\(candidates.count)")
                for candidate in candidates.prefix(6) {
                    print("  \(candidate.source) | \(candidate.artist) | \(candidate.album) | bytes=\(candidate.imageData.count)")
                }
            } catch {
                print("COVER failed: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        exit(0)
    }

    /// Renders the UI to PNG offscreen (for layout checks).
    /// Requires CEDAR_LIBRARY_DIR to avoid touching the working library.
    private static func runRenderUITest(path: String) -> Never {
        guard ProcessInfo.processInfo.environment["CEDAR_LIBRARY_DIR"] != nil else {
            print("render-ui: задайте CEDAR_LIBRARY_DIR, чтобы не затронуть рабочую библиотеку")
            exit(1)
        }
        let semaphore = DispatchSemaphore(value: 0)
        let scheme: ColorScheme? = {
            switch ProcessInfo.processInfo.environment["CEDAR_APPEARANCE"] {
            case "light": return .light
            case "dark": return .dark
            default: return nil
            }
        }()
        if let scheme {
            NSAppearance.current = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) ?? NSAppearance.current
        }
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
            if ProcessInfo.processInfo.environment["CEDAR_RENDER_MISSING"] != nil, sample.count > 1 {
                sample[1].isMissing = true
            }
            let demoURL = URL(fileURLWithPath: "/tmp/cedar-render-demo.wav")
            if !FileManager.default.fileExists(atPath: demoURL.path),
               let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2),
               let demoFile = try? AVAudioFile(forWriting: demoURL, settings: format.settings),
               let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 2) {
                buffer.frameLength = 44100 * 2
                try? demoFile.write(from: buffer)
            }
            var current = Track(url: demoURL)
            current.title = "Midnight City"
            current.artist = "M83"
            current.album = "Hurry Up, We're Dreaming"
            current.sampleRate = 44100
            current.bitDepth = 16
            current.channels = 2
            current.duration = 243
            if ProcessInfo.processInfo.environment["CEDAR_RENDER_NO_ART"] == nil {
                current.artwork = art
            }
            library.tracks = [current] + sample.dropFirst()
            engine.setQueue([current], startAt: 0, autoplay: true)
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            if let style = ProcessInfo.processInfo.environment["CEDAR_RENDER_STYLE"] {
                UserDefaults.standard.set(style, forKey: "meterStyle")
            }

            if ProcessInfo.processInfo.environment["CEDAR_RENDER_VU"] != nil {
                let vuEngine = PlayerEngine()
                let vuView = AnalogVUMeterView(preview: VULevels(left: 0.88, right: 0.55,
                                                                 peakLeft: 0.98, peakRight: 0.60))
                    .environmentObject(vuEngine)
                    .preferredColorScheme(scheme)
                .frame(width: 520, height: 300)
                let renderer = ImageRenderer(content: vuView)
                renderer.scale = 2
                if let cg = renderer.cgImage,
                   let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("render-ui vu: \(path)")
                }
                semaphore.signal()
                return
            }

            if ProcessInfo.processInfo.environment["CEDAR_RENDER_EQ"] != nil {
                let eqEngine = PlayerEngine()
                eqEngine.apply(preset: PlayerEngine.presets[1])
                let eqView = EqualizerView()
                    .environmentObject(eqEngine)
                    .preferredColorScheme(scheme)
                .frame(width: 760, height: 540)
                let renderer = ImageRenderer(content: eqView)
                renderer.scale = 2
                if let cg = renderer.cgImage,
                   let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("render-ui eq: \(path)")
                }
                semaphore.signal()
                return
            }

            if ProcessInfo.processInfo.environment["CEDAR_RENDER_MINI"] != nil {
                let mini = MiniPlayerView()
                    .environmentObject(library)
                    .environmentObject(engine)
                    .preferredColorScheme(scheme)
                .frame(width: 372, height: 96)
                let renderer = ImageRenderer(content: mini)
                renderer.scale = 2
                if let cg = renderer.cgImage,
                   let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("render-ui mini: \(path)")
                }
                semaphore.signal()
                return
            }

            let view = VStack(spacing: 0) {
                PlayerPane()
                Divider().overlay(Theme.separator)
                PlaylistPane(scrolling: false)
                    .frame(height: 299)
            }
            .environmentObject(library)
            .environmentObject(engine)
            .preferredColorScheme(scheme)
                .frame(width: Theme.Layout.width, height: Theme.Layout.defaultHeight)
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

    /// Album grouping check: import a folder and print the groups.
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

    /// Headless check of Now Playing and media key integration.
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
        var track = Track(url: url)
        let tags = TagReader.read(url: url)
        track.title = tags.title ?? track.title
        track.replayGainDB = tags.replayGainDB
        track.replayGainPeak = tags.replayGainPeak
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

    private var colorScheme: ColorScheme? {
        AppearanceMode(rawValue: appearanceMode)?.colorScheme
    }

    private var interfaceIdentity: String {
        "\(appLanguage)-\(appearanceMode)-\(accentChoice)"
    }

    private var interfaceLocale: Locale {
        _ = appLanguage
        return L10n.locale
    }

    var body: some Scene {
        WindowGroup("Cedar Player", id: "main") {
            MainWindowView()
                .environmentObject(library)
                .environmentObject(engine)
                .environment(\.player, engine)
                .environment(\.locale, interfaceLocale)
                .onAppear { appDelegate.configure(library: library, engine: engine) }
                .id(interfaceIdentity)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: Theme.Layout.width, height: Theme.Layout.defaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.string("Добавить файлы…")) { library.presentImportPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button(L10n.string("Проверить файлы библиотеки")) { library.refreshAvailability() }
                Button(L10n.string("Обновить обложки")) { library.repairArtwork() }
                Button(L10n.string("Окно обложки")) { openWindow(id: "albumart") }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            CommandMenu(L10n.string("Управление")) {
                Button(engine.isPlaying ? L10n.string("Пауза") : L10n.string("Воспроизвести")) { engine.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(engine.currentTrack == nil)
                Button(L10n.string("Следующий трек")) { engine.next(manual: true) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button(L10n.string("Предыдущий трек")) { engine.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button(L10n.string("Отменить импорт")) { library.cancelImport() }
                    .disabled(!library.isImporting)
                Menu(L10n.string("Оценка текущего трека")) {
                    ForEach(1...5, id: \.self) { value in
                        Button(String(repeating: "★", count: value)) {
                            if let track = engine.currentTrack {
                                library.setRating(value, for: [track.id])
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(value)")), modifiers: [.option])
                    }
                    Divider()
                    Button(L10n.string("Без оценки")) {
                        if let track = engine.currentTrack {
                            library.setRating(0, for: [track.id])
                        }
                    }
                    .keyboardShortcut("0", modifiers: [.option])
                }
                .disabled(engine.currentTrack == nil)

                Menu(L10n.string("Добавить в плейлист")) {
                    if library.playlists.isEmpty {
                        Text(L10n.string("Нет плейлистов"))
                    }
                    ForEach(library.playlists) { playlist in
                        Button(playlist.name) {
                            if let track = engine.currentTrack {
                                library.add([track.id], to: playlist.id)
                                library.statusMessage = L10n.format("Добавлено в «%@»", playlist.name)
                            }
                        }
                    }
                }
                .disabled(engine.currentTrack == nil)

                Button(L10n.string("Отменить удаление")) { library.undoRemove() }
                    .keyboardShortcut("z", modifiers: [.option, .command])
                    .disabled(!library.canUndoRemove)
                Button(L10n.string("Изменить теги…")) {
                    NotificationCenter.default.post(name: .editTags, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(engine.currentTrack == nil)
                Divider()
                Button(L10n.string("Перемотка назад")) {
                    engine.seek(to: max(0, engine.position - 5))
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                Button(L10n.string("Перемотка вперёд")) {
                    engine.seek(to: min(engine.duration, engine.position + 5))
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                Divider()
                Button(L10n.string("Громче")) { engine.volume = min(1, engine.volume + 0.05) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button(L10n.string("Тише")) { engine.volume = max(0, engine.volume - 0.05) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button(engine.isMuted ? L10n.string("Включить звук") : L10n.string("Заглушить")) { engine.isMuted.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Toggle(L10n.string("Перемешивание"), isOn: $engine.isShuffle)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Picker(L10n.string("Повтор"), selection: $engine.repeatMode) {
                    Text(L10n.string("Выключен")).tag(RepeatMode.off)
                    Text(L10n.string("Список")).tag(RepeatMode.all)
                    Text(L10n.string("Один трек")).tag(RepeatMode.one)
                }
                Divider()
                Button(L10n.string("Эквалайзер")) { openWindow(id: "equalizer") }
                    .keyboardShortcut("e", modifiers: .command)
                Button(L10n.string("Текст песни")) { openWindow(id: "lyrics") }
                    .keyboardShortcut("l", modifiers: .command)
                Button(L10n.string("Мини-плеер")) { openWindow(id: "mini") }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Divider()
                Menu(L10n.string("Индикатор")) {
                    ForEach(MeterStyle.allCases) { style in
                        Button(style.title) { meterStyleRaw = style.rawValue }
                    }
                    Divider()
                    Button(L10n.string("Аналоговый VU-метр")) { openWindow(id: "vu") }
                        .keyboardShortcut("u", modifiers: .command)
                }

                Toggle(L10n.string("Плейлист"), isOn: $showPlaylist)
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button(L10n.string("Библиотека")) { openWindow(id: "library") }
                    .keyboardShortcut("b", modifiers: .command)
                Button(L10n.string("Очередь")) { openWindow(id: "queue") }
                    .keyboardShortcut("q", modifiers: [.command, .option])
            }
        }

        Window(L10n.string("Очередь"), id: "queue") {
            QueueView()
                .environmentObject(engine)
                .environment(\.locale, interfaceLocale)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 360, height: 420)

        Window(L10n.string("Библиотека"), id: "library") {
            ContentView()
                .environmentObject(library)
                .environmentObject(engine)
                .environment(\.player, engine)
                .environment(\.locale, interfaceLocale)
                .id(interfaceIdentity)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 900, height: 560)

        Window(L10n.string("VU-метр"), id: "vu") {
            AnalogVUMeterView()
                .environmentObject(engine)
                .environment(\.locale, interfaceLocale)
                .id(interfaceIdentity)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 520, height: 300)

        Window(L10n.string("Обложка"), id: "albumart") {
            ArtworkWindowView()
                .environmentObject(library)
                .environmentObject(engine)
                .environment(\.locale, interfaceLocale)
                .id(interfaceIdentity)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 430, height: 560)
        .keyboardShortcut("1", modifiers: [.command])

        Window(L10n.string("Эквалайзер"), id: "equalizer") {
            EqualizerView()
                .environmentObject(engine)
                .environment(\.locale, interfaceLocale)
                .id(interfaceIdentity)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 760, height: 540)
        .windowResizability(.contentSize)

        Window(L10n.string("Текст песни"), id: "lyrics") {
            LyricsView()
                .environmentObject(engine)
                .environment(\.locale, interfaceLocale)
                .id(interfaceIdentity)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 480, height: 460)

        Window(L10n.string("Мини-плеер"), id: "mini") {
            MiniPlayerView()
                .environmentObject(library)
                .environmentObject(engine)
                .environment(\.locale, interfaceLocale)
                .id(interfaceIdentity)
                .preferredColorScheme(colorScheme)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 320, height: 96)

        MenuBarExtra {
            MenuBarPlayerView()
                .environmentObject(library)
                .environmentObject(engine)
                .environment(\.locale, interfaceLocale)
                .id(interfaceIdentity)
                .preferredColorScheme(colorScheme)
        } label: {
            Image(systemName: "music.note")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(\.locale, interfaceLocale)
                .id(interfaceIdentity)
                .preferredColorScheme(colorScheme)
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

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let engine else { return nil }
        let menu = NSMenu()
        menu.addItem(dockItem(engine.isPlaying ? L10n.string("Пауза") : L10n.string("Воспроизвести"), action: #selector(dockToggle)))
        menu.addItem(dockItem(L10n.string("Следующий трек"), action: #selector(dockNext)))
        menu.addItem(dockItem(L10n.string("Предыдущий трек"), action: #selector(dockPrevious)))
        menu.addItem(.separator())
        menu.addItem(dockItem(L10n.string("Показать плеер"), action: #selector(dockShowPlayer)))
        return menu
    }

    private func dockItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @MainActor @objc private func dockToggle() { engine?.toggle() }
    @MainActor @objc private func dockNext() { engine?.next(manual: true) }
    @MainActor @objc private func dockPrevious() { engine?.previous() }

    @MainActor @objc private func dockShowPlayer() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows
        where window.identifier?.rawValue.contains("main-AppWindow") == true {
            window.makeKeyAndOrderFront(nil)
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
