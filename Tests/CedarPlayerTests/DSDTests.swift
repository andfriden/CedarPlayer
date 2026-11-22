import XCTest
@testable import CedarPlayer

final class DSDTests: XCTestCase {
    private func makeDSF() throws -> URL {
        func u32(_ value: UInt32) -> Data {
            Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                  UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
        }
        func u64(_ value: UInt64) -> Data {
            var data = Data()
            for shift in stride(from: 0, to: 64, by: 8) {
                data.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
            return data
        }

        let sampleCount: UInt64 = 32
        let blockSize: UInt32 = 4
        let rate: UInt32 = 2_822_400
        var fmt = Data()
        fmt.append(u32(1))
        fmt.append(u32(0))
        fmt.append(u32(2))
        fmt.append(u32(2))
        fmt.append(u32(rate))
        fmt.append(u32(1))
        fmt.append(u64(sampleCount))
        fmt.append(u32(blockSize))
        fmt.append(u32(0))

        let data = Data(repeating: 0x01, count: 8)
        var file = Data("DSD ".utf8)
        file.append(u64(28))
        file.append(u64(0))
        file.append(u64(0))
        file.append(Data("fmt ".utf8))
        file.append(u64(UInt64(12 + fmt.count)))
        file.append(fmt)
        file.append(Data("data".utf8))
        file.append(u64(UInt64(12 + data.count)))
        file.append(data)
        file.replaceSubrange(12..<20, with: u64(UInt64(file.count)))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dsf")
        try file.write(to: url)
        return url
    }


    private func makeDFF() throws -> URL {
        func u32be(_ value: UInt32) -> Data {
            Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                  UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
        }
        func u16be(_ value: UInt16) -> Data {
            Data([UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
        }
        func u64be(_ value: UInt64) -> Data {
            var data = Data()
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
            return data
        }
        func chunk(_ id: String, _ payload: Data) -> Data {
            var data = Data(id.utf8) + u64be(UInt64(payload.count)) + payload
            if payload.count % 2 == 1 { data.append(0) }
            return data
        }

        let fs = chunk("FS  ", u32be(2_822_400))
        let chnl = chunk("CHNL", u16be(2) + Data("CH1 CH2 ".utf8))
        let cmpr = chunk("CMPR", Data("DSD ".utf8))
        let prop = chunk("PROP", Data("SND ".utf8) + fs + chnl + cmpr)
        let data = Data(repeating: 0x01, count: 8)
        let dsd = chunk("DSD ", data)
        let body = Data("DSD ".utf8) + prop + dsd
        var file = Data("FRM8".utf8) + u64be(UInt64(body.count)) + body
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dff")
        try file.write(to: url)
        return url
    }

    func testDFFPackingInterleavesChannels() throws {
        let url = try makeDFF()
        defer { try? FileManager.default.removeItem(at: url) }
        let track = try DoPTrack(url: url)
        XCTAssertEqual(track.carrierRate, 176_400)
        XCTAssertEqual(track.frames, 2)
        XCTAssertEqual(Array(track.bytes), [
            0x05, 0x01, 0x01, 0x05, 0x01, 0x01,
            0xFA, 0x01, 0x01, 0xFA, 0x01, 0x01
        ])
    }

    func testDSFPackingUsesDoPMarkersAndBitOrder() throws {
        let url = try makeDSF()
        defer { try? FileManager.default.removeItem(at: url) }

        let track = try DoPTrack(url: url)
        XCTAssertEqual(track.carrierRate, 176_400)
        XCTAssertEqual(track.frames, 2)
        XCTAssertEqual(Array(track.bytes), [
            0x05, 0x80, 0x80, 0x05, 0x80, 0x80,
            0xFA, 0x80, 0x80, 0xFA, 0x80, 0x80
        ])
    }
}
