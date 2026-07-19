import Foundation
import CoreServices
import OSLog

/// Watches a folder and fires a debounced `onChange` a couple of seconds after any change. The
/// watched folder is often an Obsidian vault / synced folder edited by other apps, so without
/// this the index (and therefore search, Ask, related-calls, and MCP retrieve) stays stale until
/// the next launch. Uses FSEvents with file-level events so in-place edits — not just
/// create/delete — trigger a refresh. The action is injected (the app passes reconcile + UI
/// refresh) so the watcher itself stays dependency-free and its debounce is testable host-less.
public final class IndexWatcher {
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.ronanwood.Scripta.indexWatcher", qos: .utility)
    private let log = Logger(subsystem: "com.ronanwood.Scripta", category: "Index")
    private var stream: FSEventStreamRef?
    private var debounce: DispatchWorkItem?

    public init(onChange: @escaping () -> Void) { self.onChange = onChange }

    /// `arm`/`tearDown` and the FSEvents callback are all serialized on `queue`, so a synchronous
    /// teardown here drains any in-flight callback and invalidates the stream before the memory
    /// backing its `passUnretained` context pointer is reused.
    deinit { queue.sync { tearDown() } }

    /// Arms the watcher on `folder` (replacing any previous watch). Reconcile is not run here —
    /// callers do an explicit reconcile when they need the current contents indexed.
    public func start(folder: URL) {
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

    /// Debounced: many events during a sync burst collapse into one onChange. The injected action
    /// (reconcile) is mtime-diffed and idempotent, so a spurious fire is cheap.
    private func scheduleReconcile() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }
}
