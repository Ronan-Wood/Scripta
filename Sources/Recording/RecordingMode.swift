import Foundation

/// How a recording uses its two possible capture tracks.
///
/// - `.call` — the default two-party split: mic = "You", system = "Them".
/// - `.conference` — a single source, left unlabeled. For a hybrid room where you're physically
///   present *and* joined online: the mic (the room) and the system audio (the meeting stream)
///   would otherwise capture the *same* speech, doubling every line in the transcript. Conference
///   mode records just one of them.
enum RecordingMode: Equatable {
    case call
    case conference(ConferenceSource)

    var capturesMic: Bool {
        switch self {
        case .call, .conference(.microphone): return true
        case .conference(.system): return false
        }
    }

    var capturesSystem: Bool {
        switch self {
        case .call, .conference(.system): return true
        case .conference(.microphone): return false
        }
    }

    /// Only a two-party call splits into You/Them; a conference is a single unlabeled source.
    var labelsSpeakers: Bool { self == .call }

    var displayName: String {
        switch self {
        case .call: return "Call"
        case .conference(.system): return "Conference · System audio"
        case .conference(.microphone): return "Conference · Microphone"
        }
    }

    /// Stable string for persistence and the settings picker.
    var storageValue: String {
        switch self {
        case .call: return "call"
        case .conference(.system): return "conference-system"
        case .conference(.microphone): return "conference-microphone"
        }
    }

    init(storageValue: String) {
        switch storageValue {
        case "conference-system": self = .conference(.system)
        case "conference-microphone": self = .conference(.microphone)
        default: self = .call
        }
    }
}

/// Which single track a conference recording captures.
enum ConferenceSource: Equatable { case system, microphone }
