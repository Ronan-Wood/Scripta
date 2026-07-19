import Foundation

/// The data currency of the transcript pipeline: what capture/transcription produce and
/// `TranscriptWriter` consumes. Pure values, extracted here so the writer (and its vault-safety
/// frontmatter contract) lives in the dependency-free layer while capture stays app-side.

/// Which side of the conversation a segment came from. `you` = the local microphone,
/// `them` = the far side captured as system audio. `nil` when the split isn't meaningful
/// (e.g. an in-person recording where everyone is on the mic) — then no label is shown.
public enum Speaker: String, Sendable {
    case you = "You"
    case them = "Them"
}

/// One timestamped chunk of transcript.
public struct TranscriptSegment: Sendable {
    public let startMs: Int
    public let text: String
    public let speaker: Speaker?

    public init(startMs: Int, text: String, speaker: Speaker? = nil) {
        self.startMs = startMs
        self.text = text
        self.speaker = speaker
    }
}

/// A timestamped piece of screen text retained during a recording. `imagePath` points at an
/// EPHEMERAL PNG on disk (same posture as the raw audio — temp file, deleted after the post-call
/// caption pass, never in the vault), set only when a vision model is assigned. Nothing is held in
/// memory across the call.
public struct ScreenSnippet: Sendable {
    public let startMs: Int
    public let text: String
    public var imagePath: URL?

    public init(startMs: Int, text: String, imagePath: URL? = nil) {
        self.startMs = startMs
        self.text = text
        self.imagePath = imagePath
    }
}

/// A note the user typed during recording, timestamped against call time (paused intervals
/// spliced out, exactly like the audio tracks) so it interleaves into the transcript body at
/// the right moment.
public struct CallNote: Sendable {
    public let startMs: Int
    public let text: String

    public init(startMs: Int, text: String) {
        self.startMs = startMs
        self.text = text
    }
}
