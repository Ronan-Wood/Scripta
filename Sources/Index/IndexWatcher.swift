import Foundation
import CoreServices
import OSLog

/// Watches the transcript output folder and reconciles the index a couple of seconds after any
/// change. The output folder is often an Obsidian vault / synced folder edited by other apps, so
/// without this the index (and therefore search, Ask, related-calls, and MCP retrieve) stays
/// stale until the next launch. Uses FSEvents with file-level events so in-place edits — not just
/// create/delete — trigger a refresh.
final class IndexWatcher {
    static let shared: IndexWatcher? = IndexStore.shared.map { IndexWatcher(store: $0) }

    private let store: IndexStore
    private let queue = DispatchQueue(label: "com.ronanwood.CallTranscriber.indexWatcher", qos: .utility)
    private let log = Logger(subsystem: "com.ronanwood.CallTranscriber", category: "Index")
    private var stream: FSEventStreamRef?
    private var debounce: DispatchWorkItem?

    private init(store: IndexStore) { self.store = store }

    /// Arms the watcher on `folder` (replacing any previous watch). Reconcile is not run here —
    /// callers do an explicit reconcile when they need the current contents indexed.
    func start(folder: URL) {
        queue.async { [weak self] in self?.arm(folder) }
    }

    private func arm(_ folder: URL) {
        tearDown()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<IndexWatcher>.fromOpaque(info).takeUnretainedValue().scheduleReconcile()
        }
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                               [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else {
            log.error("could not start folder watcher on \(folder.path, privacy: .public)")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func tearDown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Debounced: many events during a sync burst collapse into one reconcile. reconcile is
    /// mtime-diffed and idempotent, so a spurious fire is cheap.
    private func scheduleReconcile() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            IndexBuilder.reconcile(store: self.store)
            Task { @MainActor in AppModel.shared.reloadCalls() }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }
}
