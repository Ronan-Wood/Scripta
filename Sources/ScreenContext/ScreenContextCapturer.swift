import Foundation
import ScreenCaptureKit
import OSLog

/// A timestamped piece of screen text retained during a recording.
struct ScreenSnippet: Sendable {
    let startMs: Int
    let text: String
}

/// What the screen-context feature reads from, chosen per recording.
enum ScreenSource: Equatable {
    case frontmostWindow            // follows the active window as you switch
    case display                    // the whole screen
    case window(CGWindowID, String) // one fixed window
    case off                        // no screen context this recording
}

/// Periodically screenshots the frontmost window, OCRs it, deduplicates against the last
/// kept capture, and retains only meaningfully-new text — timestamped against the session
/// start. The screenshot image is discarded immediately after OCR; only text is kept.
actor ScreenContextCapturer {
    private let interval: TimeInterval
    private let sessionStart: Date
    private let focus: ScreenFocus
    private let source: ScreenSource
    private let deduplicator = SnippetDeduplicator()
    private let log = Logger(subsystem: "com.ronanwood.CallTranscriber", category: "ScreenContext")

    private var snippets: [ScreenSnippet] = []
    private var loop: Task<Void, Never>?
    private var paused = false
    // Snippet timestamps must exclude paused time, mirroring how the audio tracks splice
    // out paused intervals — otherwise post-pause snippets drift late against the transcript.
    private var pausedAccum: TimeInterval = 0
    private var pauseBegan: Date?

    func setPaused(_ value: Bool) {
        if value {
            if pauseBegan == nil { pauseBegan = Date() }
        } else if let began = pauseBegan {
            pausedAccum += Date().timeIntervalSince(began)
            pauseBegan = nil
        }
        paused = value
    }

    init(interval: TimeInterval, sessionStart: Date, focus: ScreenFocus, source: ScreenSource) {
        self.interval = interval
        self.sessionStart = sessionStart
        self.focus = focus
        self.source = source
    }

    /// On-screen windows the user can pick from in the record-time prompt (app · title), most
    /// recently fronted first, excluding our own windows and untitled/system chrome.
    static func availableWindows() async -> [(id: CGWindowID, label: String)] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { window in
            guard window.owningApplication?.processID != ownPID,
                  let app = window.owningApplication?.applicationName, !app.isEmpty,
                  window.frame.width > 120, window.frame.height > 80 else { return nil }
            let title = window.title?.trimmingCharacters(in: .whitespaces) ?? ""
            let label = title.isEmpty ? app : "\(app) · \(title)"
            return (id: window.windowID, label: label)
        }
    }

    func start() {
        loop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
            }
        }
    }

    /// Cancels the loop, waits for any in-flight tick to finish, and returns the snippets.
    func stop() async -> [ScreenSnippet] {
        loop?.cancel()
        await loop?.value
        loop = nil
        return snippets
    }

    // MARK: - Capture tick

    private func tick() async {
        guard !paused else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let (filter, width, height) = resolveFilter(in: content) else { return }

            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            // Read structured text (tables → Markdown) then immediately drop the image.
            guard let structured = await DocumentReader.read(image, focus: focus) else { return }
            guard let text = deduplicator.consider(structured) else { return }

            let offsetMs = Int((Date().timeIntervalSince(sessionStart) - pausedAccum) * 1000)
            snippets.append(ScreenSnippet(startMs: max(0, offsetMs), text: text))
        } catch {
            // Transient failures (window closed mid-capture, etc.) just skip this tick.
            log.debug("screen capture tick skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Builds the content filter + capture resolution for the chosen source. Captures at ~2x for
    /// legible OCR, capped so huge windows/displays stay reasonable. Skips (nil) if the target is gone.
    private func resolveFilter(in content: SCShareableContent) -> (SCContentFilter, Int, Int)? {
        func window(_ window: SCWindow) -> (SCContentFilter, Int, Int) {
            (SCContentFilter(desktopIndependentWindow: window),
             min(Int(window.frame.width * 2), 4000), min(Int(window.frame.height * 2), 4000))
        }
        switch source {
        case .off:
            return nil
        case .frontmostWindow:
            guard let w = FrontmostWindowResolver.currentWindow(in: content) else { return nil }
            return window(w)
        case .window(let id, _):
            guard let w = content.windows.first(where: { $0.windowID == id }) else { return nil }
            return window(w)
        case .display:
            guard let display = content.displays.first else { return nil }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownApps = content.applications.filter { $0.processID == ownPID }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            return (filter, min(display.width * 2, 4000), min(display.height * 2, 4000))
        }
    }
}
