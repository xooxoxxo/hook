import Foundation
import RelayCore

/// Watches config.json. The directory is watched
/// because an atomic rename replaces the file's inode; the file itself is
/// watched too, because an in-place edit only touches the file. Events are
/// debounced for 300 ms. Bytes identical to the last delivered state, or to
/// the app's own last write, are not delivered.
@MainActor final class ConfigWatcher {
    static let debounce: Duration = .milliseconds(300)

    private let url: URL
    private let onChange: @MainActor (ConfigLoad) -> Void
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var pending: Task<Void, Never>?
    private var lastBytes: Data?
    private var ownWrite: Data?

    init(url: URL, onChange: @escaping @MainActor (ConfigLoad) -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        stop()
        lastBytes = try? Data(contentsOf: url)
        directorySource = Self.watch(url.deletingLastPathComponent().path) { [weak self] in
            self?.changed()
        }
        armFileSource()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
    }

    /// The next change whose bytes equal `data` is the app's own save: skipped.
    func noteOwnWrite(_ data: Data) {
        ownWrite = data
    }

    private func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    private func fire() {
        armFileSource()
        let bytes = try? Data(contentsOf: url)
        if let own = ownWrite, bytes == own {
            ownWrite = nil
            lastBytes = bytes
            return
        }
        guard bytes != lastBytes else { return }
        lastBytes = bytes
        onChange(ConfigStore.load(url))
    }

    /// The file's inode changes on every atomic save, so its source is re-made.
    private func armFileSource() {
        fileSource?.cancel()
        fileSource = Self.watch(url.path) { [weak self] in
            self?.changed()
        }
    }

    private static func watch(
        _ path: String, _ handler: @escaping @MainActor () -> Void
    ) -> (any DispatchSourceFileSystemObject)? {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib, .link],
            queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        return source
    }
}
