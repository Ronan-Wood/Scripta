import Foundation
import NaturalLanguage

/// Deterministic entity candidate extraction — the reliable first pass (Fable: seeds first, an LLM
/// only *proposes* refinements later). Apple's on-device NLTagger gives person/org NER with zero
/// deps and zero hallucination; calendar attendees are a high-precision people seed. Runs per
/// chunk so every mention carries a real timestamp (provenance + entity-page jump-to-passage).
public enum EntityExtractor {
    public static func mentions(chunks: [IndexedChunk], attendees: [String]) -> [(surface: String, kind: String, startMs: Int)] {
        var out: [(String, String, Int)] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther, .joinNames]

        for chunk in chunks {
            tagger.string = chunk.text
            tagger.enumerateTags(in: chunk.text.startIndex..<chunk.text.endIndex,
                                 unit: .word, scheme: .nameType, options: options) { tag, range in
                let kind: String?
                switch tag {
                case .personalName: kind = "person"
                case .organizationName: kind = "org"
                default: kind = nil
                }
                if let kind {
                    let surface = String(chunk.text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    // Junk gate (cheap confidence proxy): real names carry a capital; drop
                    // all-lowercase single tokens NLTagger occasionally mis-tags from ASR noise.
                    if surface.count >= 2, surface.contains(where: \.isUppercase) {
                        out.append((surface, kind, chunk.startMs))
                    }
                }
                return true
            }
        }

        // Calendar attendees: a zero-hallucination people seed. (List/room/self filtering happens
        // upstream where the attendee list is assembled.)
        for name in attendees {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if n.count >= 2 { out.append((n, "person", 0)) }
        }
        return out
    }
}
