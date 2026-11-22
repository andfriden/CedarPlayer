import Foundation
import CVorbis

enum OggMetadata {
    static func read(url: URL) -> AudioTags? {
        var error: Int32 = 0
        guard let handle = url.path.withCString({ cvorbis_open($0, &error) }) else { return nil }
        defer { cvorbis_close(handle) }

        var channels: Int32 = 0
        var rate: Int32 = 0
        var frames: Int64 = 0
        guard cvorbis_info(handle, &channels, &rate, &frames) == 0 else { return nil }

        var tags = AudioTags()
        tags.channels = Int(channels)
        tags.sampleRate = Double(rate)
        if rate > 0, frames > 0 { tags.duration = Double(frames) / Double(rate) }

        let count = Int(cvorbis_comment_count(handle))
        var comments: [String] = []
        comments.reserveCapacity(count)
        for index in 0..<count {
            if let value = cvorbis_comment(handle, Int32(index)) {
                comments.append(String(cString: value))
            }
        }
        TagReader.applyCommentEntries(comments, to: &tags)
        return tags
    }
}
