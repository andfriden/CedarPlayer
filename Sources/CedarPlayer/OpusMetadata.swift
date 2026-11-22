import Foundation
import COpus

enum OpusMetadata {
    static func read(url: URL) -> AudioTags? {
        guard let handle = url.path.withCString({ copus_open($0) }) else { return nil }
        defer { copus_close(handle) }

        var channels: Int32 = 0
        var rate: Int32 = 0
        var frames: Int64 = 0
        guard copus_info(handle, &channels, &rate, &frames) == 0 else { return nil }

        var tags = AudioTags()
        tags.channels = Int(channels)
        tags.sampleRate = Double(rate)
        if rate > 0, frames > 0 { tags.duration = Double(frames) / Double(rate) }

        let count = Int(copus_tag_count(handle))
        var comments: [String] = []
        comments.reserveCapacity(count)
        for index in 0..<count {
            if let value = copus_tag(handle, Int32(index)) {
                comments.append(String(cString: value))
            }
        }
        TagReader.applyCommentEntries(comments, to: &tags)
        return tags
    }
}
