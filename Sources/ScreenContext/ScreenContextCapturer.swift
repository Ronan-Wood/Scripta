import Foundation
import ScreenCaptureKit
import AppKit
import OSLog

/// A timestamped piece of screen text retained during a recording. `imagePath` points at an
/// EPHEMERAL PNG on disk (same posture as the raw audio — temp file, deleted after the post-call
/// caption pass, never in the vault), set only when a vision model is assigned. Nothing is held in
/// memory across the call.
struct ScreenSnippet: Sendable {
    let startMs: Int
    let text: String
    var imagePath: URL?
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
    private let log = Logger(subsystem: "com.ronanwood.Scripta", category: "ScreenContext")

    /// When set, retained frame PNGs are written here (ephemeral, deleted after the post-call
    /// caption pass). nil = OCR-text only. The cap bounds the post-call VLM time (~20s/image), not
    /// memory — nothing accumulates in RAM (each PNG is written and released immediately).
    private let imageDir: URL?
    private static let maxRetainedImages = 20
    private var retainedCount = 0

    // Change detection: only the expensive work (OCR, image retention) runs when the screen
    // visibly changes AND that new screen holds still — a view someone actually dwelled on, not a
    // transient flash or a mid-scroll frame. The tick itself just fingerprints the frame (cheap).
    private var settledHash: UInt64?     // the last committed screen
    private var candidateHash: UInt64?   // a new screen awaiting confirmation
    private var candidateHits = 0        // consecutive stable samples of the candidate
    private static let sameThreshold = 6     // Hamming distance ≤ this ⇒ "same screen" (of 64 bits)
    private static let dwellSamples = 2      // must hold still this many samples before committing

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

    init(interval: TimeInterval, sessionStart: Date, focus: ScreenFocus, source: ScreenSource, imageDir: URL? = nil) {
        self.interval = interval
        self.sessionStart = sessionStart
        self.focus = focus
        self.source = source
        self.imageDir = imageDir
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

            // Cheap fingerprint first — most ticks stop here with no OCR.
            let hash = Self.perceptualHash(image)
            if let settled = settledHash, Self.hamming(hash, settled) <= Self.sameThreshold {
                candidateHash = nil; candidateHits = 0   // still the committed screen
                return
            }
            if let candidate = candidateHash, Self.hamming(hash, candidate) <= Self.sameThreshold {
                candidateHits += 1
                if candidateHits >= Self.dwellSamples { await commit(image, hash: hash) }
            } else {
                candidateHash = hash; candidateHits = 1   // a new screen appeared — start its dwell
            }
        } catch {
            // Transient failures (window closed mid-capture, etc.) just skip this tick.
            log.debug("screen capture tick skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A new screen held still long enough — now do the expensive work: OCR, text-dedup (a second
    /// guard against near-identical content), and (if a vision model is on) retain the frame.
    private func commit(_ image: CGImage, hash: UInt64) async {
        settledHash = hash
        candidateHash = nil; candidateHits = 0
        guard let structured = await DocumentReader.read(image, focus: focus),
              let text = deduplicator.consider(structured) else { return }

        let offsetMs = max(0, Int((Date().timeIntervalSince(sessionStart) - pausedAccum) * 1000))
        var imagePath: URL?
        if let imageDir, retainedCount < Self.maxRetainedImages,
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            let url = imageDir.appendingPathComponent("\(offsetMs).png")
            if (try? png.write(to: url)) != nil { imagePath = url; retainedCount += 1 }
            // png Data is released here — nothing accumulates in memory.
        }
        snippets.append(ScreenSnippet(startMs: offsetMs, text: text, imagePath: imagePath))
    }

    /// 64-bit average hash: downscale to 8×8 grayscale, then bit-per-pixel above/below the mean.
    /// Robust to tiny rendering jitter, sensitive to real content change.
    private static func perceptualHash(_ image: CGImage) -> UInt64 {
        let n = 8
        var pixels = [UInt8](repeating: 0, count: n * n)
        guard let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        let avg = pixels.reduce(0) { $0 + Int($1) } / (n * n)
        var hash: UInt64 = 0
        for (i, p) in pixels.enumerated() where Int(p) >= avg { hash |= (UInt64(1) << UInt64(i)) }
        return hash
    }

    private static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

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
