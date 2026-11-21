import Foundation

/// Следит за каталогами через DispatchSource и сообщает об изменениях с задержкой,
/// чтобы не реагировать на каждый временный файл.
final class FolderWatcher {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: [String: DispatchWorkItem] = [:]
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "cedar.folder.watcher")

    var onChange: ((URL) -> Void)?

    init(debounce: TimeInterval = 1.5) {
        self.debounce = debounce
    }

    deinit {
        stopAll()
    }

    func watch(_ folders: [URL]) {
        let paths = Set(folders.map { $0.standardizedFileURL.path })

        for (path, source) in sources where !paths.contains(path) {
            source.cancel()
            sources[path] = nil
            pending[path]?.cancel()
            pending[path] = nil
        }

        for path in paths where sources[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                   eventMask: [.write, .rename, .delete],
                                                                   queue: queue)
            source.setEventHandler { [weak self] in
                self?.scheduleChange(path)
            }
            source.setCancelHandler {
                close(descriptor)
            }
            sources[path] = source
            source.resume()
        }
    }

    func stopAll() {
        sources.values.forEach { $0.cancel() }
        sources.removeAll()
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
    }

    private func scheduleChange(_ path: String) {
        pending[path]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async { self.onChange?(url) }
        }
        pending[path] = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
