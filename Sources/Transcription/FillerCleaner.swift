import Foundation

/// Removes speech disfluencies ("um", "uh", "erm", …) from transcript text. Purely
/// deterministic — it strips a fixed set of filler tokens and tidies the surrounding
/// punctuation/spacing. It never paraphrases or reorders real words.
enum FillerCleaner {
    private static let fillers = try! NSRegularExpression(
        pattern: "\\b(u+h+m+|u+m+|u+h+|erm?|hmm+)\\b[,]?",
        options: [.caseInsensitive]
    )

    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = fillers.stringByReplacingMatches(in: text, range: range, withTemplate: "")

        // Tidy the artifacts a removal leaves behind.
        result = result.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "^[\\s,]+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: ",{2,}", with: ",", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
