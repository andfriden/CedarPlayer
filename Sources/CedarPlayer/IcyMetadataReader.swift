import Foundation

/// Reads StreamTitle from ICY stream metadata (second connection with Icy-MetaData: 1).
final class IcyMetadataReader: NSObject {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var metaInterval = 0
    private var audioRemaining = 0
    private var pendingMetadata = -1
    private var buffer = Data()
    private var onTitle: ((String) -> Void)?
    private let queue = OperationQueue()

    func start(url: URL, onTitle: @escaping (String) -> Void) {
        self.onTitle = onTitle
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session

        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("CedarPlayer/1.0", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()

        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.cancel()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        onTitle = nil
    }

    /// "Artist - Song" → ("Artist", "Song"); hyphens inside a name are kept,
    /// because the separator is only a hyphen surrounded by spaces.
    static func splitTitle(_ value: String) -> (artist: String?, title: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, value) }
        for separator in [" - ", " – ", " — "] {
            if let range = trimmed.range(of: separator) {
                let artist = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let title = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty, !title.isEmpty {
                    return (artist, title)
                }
            }
        }
        return (nil, trimmed)
    }

    /// "StreamTitle='Artist - Song';" → "Artist - Song".
    static func extractTitle(from metadata: Data) -> String? {
        guard let text = String(data: metadata, encoding: .utf8)
                ?? String(data: metadata, encoding: .isoLatin1),
              let start = text.range(of: "StreamTitle='") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        let title = String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}

extension IcyMetadataReader: URLSessionDataDelegate {
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse,
           let value = http.value(forHTTPHeaderField: "icy-metaint"),
           let interval = Int(value), interval > 0 {
            metaInterval = interval
            audioRemaining = interval
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard metaInterval > 0 else { return }
        buffer.append(data)

        while true {
            if audioRemaining > 0 {
                let drop = min(audioRemaining, buffer.count)
                guard drop > 0 else { return }
                buffer.removeFirst(drop)
                audioRemaining -= drop
                continue
            }

            if pendingMetadata < 0 {
                guard let lengthByte = buffer.first else { return }
                buffer.removeFirst()
                pendingMetadata = Int(lengthByte) * 16
                if pendingMetadata == 0 {
                    pendingMetadata = -1
                    audioRemaining = metaInterval
                }
                continue
            }

            guard buffer.count >= pendingMetadata else { return }
            let metadata = buffer.prefix(pendingMetadata)
            buffer.removeFirst(pendingMetadata)
            pendingMetadata = -1
            audioRemaining = metaInterval

            if let title = Self.extractTitle(from: metadata) {
                let handler = onTitle
                cancel()
                handler?(title)
                return
            }
        }
    }
}
