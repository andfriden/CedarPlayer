import XCTest
import AVFoundation
import SwiftUI
@testable import CedarPlayer

@MainActor
final class RadioBranchTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeWAV(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
        buffer.frameLength = 4410
        try file.write(from: buffer)
        return url
    }

    func testRadioReplacesLocalTrackAndPauses() throws {
        let engine = PlayerEngine()
        let track = Track(url: try makeWAV("tone.wav"))
        engine.setQueue([track], startAt: 0, autoplay: false)
        XCTAssertNotNil(engine.currentTrack)

        let station = RadioStation(name: "Тест", urlString: try makeWAV("radio.wav").absoluteString)
        engine.playRadio(station)
        XCTAssertEqual(engine.currentStation?.id, station.id)
        XCTAssertNil(engine.currentTrack)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertNil(engine.errorMessage)

        engine.pause()
        XCTAssertFalse(engine.isPlaying)
        engine.play()
        XCTAssertTrue(engine.isPlaying)

        engine.stop()
        XCTAssertNil(engine.currentStation)
        XCTAssertFalse(engine.isPlaying)
    }

    func testInvalidStationURLReportsError() {
        let engine = PlayerEngine()
        engine.playRadio(RadioStation(name: "Bad", urlString: "не url"))
        XCTAssertNil(engine.currentStation)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.errorMessage, "Некорректный адрес станции")
    }

    func testRadioVolumeFollowsPlayer() throws {
        let engine = PlayerEngine()
        engine.playRadio(RadioStation(name: "Тест", urlString: try makeWAV("vol.wav").absoluteString))
        engine.volume = 0.3
        XCTAssertTrue(engine.isPlaying)
        engine.isMuted = true
        engine.isMuted = false
        engine.stop()
    }
}

@MainActor
final class UISnapshotTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func image<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height))
        renderer.scale = 2
        let cgImage = try XCTUnwrap(renderer.cgImage, "не удалось отрисовать \(name)")
        let rep = NSBitmapImageRep(cgImage: cgImage)
        XCTAssertEqual(rep.pixelsWide, Int(width * 2), "\(name): ширина")
        XCTAssertEqual(rep.pixelsHigh, Int(height * 2), "\(name): высота")
        XCTAssertGreaterThan(uniqueColors(rep), 3, "\(name): изображение пустое")

        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        return rep
    }

    private func uniqueColors(_ rep: NSBitmapImageRep) -> Int {
        var colors = Set<UInt32>()
        let step = max(1, rep.pixelsWide / 32)
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                if let color = rep.colorAt(x: x, y: y),
                   let rgb = color.usingColorSpace(.deviceRGB) {
                    let packed = UInt32(rgb.redComponent * 255) << 16
                        | UInt32(rgb.greenComponent * 255) << 8
                        | UInt32(rgb.blueComponent * 255)
                    colors.insert(packed)
                }
            }
        }
        return colors.count
    }

    private func makeTrack(_ index: Int) -> Track {
        var track = Track(url: URL(fileURLWithPath: "/tmp/snapshot-\(index).flac"))
        track.title = "Трек \(index)"
        track.artist = "Исполнитель"
        track.album = "Альбом"
        track.duration = 180 + Double(index)
        return track
    }

    func testPlayerAndPlaylistSnapshots() throws {
        let engine = PlayerEngine()
        let library = Library(testTracks: [makeTrack(1), makeTrack(2), makeTrack(3)])

        let pane = PlayerPane().environmentObject(engine).environmentObject(library)
        _ = try image(pane, width: 425, height: 300, name: "player-pane")

        let playlist = PlaylistPane(scrolling: false).environmentObject(engine).environmentObject(library)
        _ = try image(playlist, width: 425, height: 300, name: "playlist-pane")
    }

    func testEqualizerSnapshot() throws {
        let engine = PlayerEngine()
        engine.apply(preset: PlayerEngine.presets[1])
        let eq = EqualizerView().environmentObject(engine)
        _ = try image(eq, width: 760, height: 540, name: "equalizer")
    }

    func testMenuBarPlayerSnapshot() throws {
        let engine = PlayerEngine()
        let library = Library(testTracks: [makeTrack(1)])
        let view = MenuBarPlayerView().environmentObject(engine).environmentObject(library)
        _ = try image(view, width: 300, height: 170, name: "menu-bar-player")
    }

    func testVUMeterSnapshot() throws {
        let engine = PlayerEngine()
        let vu = AnalogVUMeterView().environmentObject(engine)
        _ = try image(vu, width: 520, height: 300, name: "vu-meter")
    }

    func testMiniPlayerSnapshot() throws {
        let engine = PlayerEngine()
        let library = Library(testTracks: [makeTrack(1)])
        let mini = MiniPlayerView().environmentObject(engine).environmentObject(library)
        _ = try image(mini, width: 320, height: 96, name: "mini-player")
    }
}
