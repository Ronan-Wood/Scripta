import Foundation
import ScriptaCore

/// The post-call VLM caption pass. Lives in the app layer (not the recording pipeline, which never
/// touches the engine): it reads the ephemeral screenshots a recording retained, captions each with
/// the local vision model, patches the caption into the transcript's Screen Context, reindexes, and
/// deletes the images. Best-effort — a failure just leaves OCR-only screen text.
enum ScreenCaptionPatcher {
    static func run(transcriptURL: URL, imageDir: URL) async {
        defer { try? FileManager.default.removeItem(at: imageDir) }   // images are always ephemeral
        guard VLMCaptioner.isConfigured,
              var content = try? String(contentsOf: transcriptURL, encoding: .utf8),
              let files = try? FileManager.default.contentsOfDirectory(at: imageDir, includingPropertiesForKeys: nil)
        else { return }

        var patched = 0
        // Oldest first (filenames are the ms offset), one at a time (the endpoint is single-flight).
        for file in files.filter({ $0.pathExtension == "png" })
            .sorted(by: { ($0.deletingPathExtension().lastPathComponent as NSString).integerValue
                        < ($1.deletingPathExtension().lastPathComponent as NSString).integerValue }) {
            guard let ms = Int(file.deletingPathExtension().lastPathComponent),
                  let png = try? Data(contentsOf: file),
                  let raw = await VLMCaptioner.caption(imageData: png) else { continue }
            let caption = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !caption.isEmpty else { continue }
            // Insert under the matching Screen Context entry ("**[m:ss]**"), so it re-chunks with
            // the OCR text and becomes searchable.
            let marker = "**[\(clock(ms))]**\n\n"
            if let r = content.range(of: marker) {
                content.replaceSubrange(r, with: marker + "_Screen: \(caption)_\n\n")
                patched += 1
            }
        }

        if patched > 0 {
            try? content.write(to: transcriptURL, atomically: true, encoding: .utf8)
            if let store = IndexStore.shared { IndexBuilder.index(transcriptURL, into: store) }
            await MainActor.run { AppModel.shared.reloadCalls() }
        }
    }

    /// Matches TranscriptWriter's clock format (M:SS / H:MM:SS).
    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000, h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
