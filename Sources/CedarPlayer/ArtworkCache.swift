import Foundation
import AppKit
import CryptoKit

/// Кэш обложек на диске: файлы по SHA-256, в библиотеке хранится только ключ.
final class ArtworkCache {

    static let shared = ArtworkCache()

    private let directory: URL
    private let queue = DispatchQueue(label: "cedar.artwork.cache")
    private let images = NSCache<NSString, NSImage>()

    private init() {
        let base = Self.defaultRoot.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        directory = base
    }

    /// Отдельный кэш в заданном каталоге — для тестов.
    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static var defaultRoot: URL {
        if let custom = ProcessInfo.processInfo.environment["CEDAR_LIBRARY_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CedarPlayer", isDirectory: true)
    }

    /// Сохраняет изображение и возвращает ключ (nil, если данных нет).
    @discardableResult
    func store(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let key = Self.key(for: data)
        let url = directory.appendingPathComponent(key)
        if !FileManager.default.fileExists(atPath: url.path) {
            queue.sync {
                try? data.write(to: url, options: .atomic)
            }
        }
        return key
    }

    func data(for key: String) -> Data? {
        let url = directory.appendingPathComponent(key)
        return try? Data(contentsOf: url)
    }

    /// Декодированная обложка для списков: повторные перерисовки не декодируют PNG заново.
    func image(for key: String) -> NSImage? {
        let cacheKey = key as NSString
        if let cached = images.object(forKey: cacheKey) {
            return cached
        }
        guard let data = data(for: key), let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: cacheKey)
        return image
    }

    /// Удаляет файлы, на которые больше не ссылается библиотека.
    func prune(keeping keys: Set<String>) {
        queue.sync {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                          includingPropertiesForKeys: nil) else { return }
            for file in files where !keys.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func size() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    private static func key(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
