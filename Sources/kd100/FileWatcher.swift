import Foundation

/// Watches a single file for changes and invokes `onChange` on a private queue.
///
/// The tricky case is an **atomic write** (`String.write(atomically: true)` writes
/// a temp file then `rename()`s it over the target). That replaces the inode, so a
/// vnode source bound to the old descriptor goes dead after one `.rename`/`.delete`
/// event. We handle it by cancelling and re-opening the path after such an event,
/// so the watch survives editors and our own atomic persists alike.
final class FileWatcher {
    private let path: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "dev.otherlandlabs.kd100.filewatch")
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var stopped = false

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() { queue.async { [weak self] in self?.arm() } }

    func stop() {
        queue.async { [weak self] in
            self?.stopped = true
            self?.cancel()
        }
    }

    // MARK: - Internals (all run on `queue`)

    private func arm() {
        guard !stopped else { return }
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File not present yet (or transiently gone mid-rename); retry soon.
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let flags = src.data
            self.onChange()
            if flags.contains(.delete) || flags.contains(.rename) {
                // Inode was replaced (atomic write / move) — re-establish the watch.
                self.cancel()
                self.queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.arm() }
            }
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 { close(self.fd); self.fd = -1 }
        }
        source = src
        src.resume()
    }

    private func cancel() {
        source?.cancel()   // cancel handler closes the fd
        source = nil
    }
}
