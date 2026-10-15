import Foundation
import Dispatch
import Darwin

/// A local directory notification replaces repeated event-spool polling. A slow
/// heartbeat in the app remains as a fallback if the directory gets replaced.
final class EventWake {
    private let directory: URL
    private let onEvents: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private(set) var isWatching = false

    init(directory: URL, onEvents: @escaping () -> Void) {
        self.directory = directory
        self.onEvents = onEvents
    }

    func start() {
        guard !isWatching else { return }
        guard (try? EventSpool(directory: directory).prepare()) != nil else { return }
        let descriptor = open(directory.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let next = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke], queue: .main)
        next.setEventHandler { [weak self, weak next] in
            guard let self, let next else { return }
            if !next.data.intersection([.delete, .rename, .revoke]).isEmpty {
                self.stop()
                return
            }
            // Our own library/statistics writes share this directory. They must
            // never feed a refresh loop back into themselves.
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: self.directory.path),
                  files.contains(where: { $0.hasSuffix(".event") }), self.pending == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.onEvents()
            }
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
        next.setCancelHandler { close(descriptor) }
        source = next
        isWatching = true
        next.resume()
    }

    func stop() {
        pending?.cancel(); pending = nil
        source?.cancel(); source = nil
        isWatching = false
    }

    deinit { pending?.cancel(); source?.cancel() }
}
