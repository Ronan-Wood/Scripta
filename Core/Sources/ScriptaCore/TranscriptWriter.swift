import Foundation
import ScriptaShared

/// Writes a transcript as a Markdown file with Obsidian-style YAML frontmatter into the
/// caller-supplied output folder (the app passes its configured folder via the +Live wrapper). The `app: call-transcriber` frontmatter key marks files this
/// app owns — the retention pruner (M5) keys on it so it never touches unrelated vault files.
public enum TranscriptWriter {

    /// Marker written into every transcript's frontmatter. Load-bearing for safe pruning.
    /// The value lives in the shared `OwnerMarker` so retrieval code can reference it too.
    public static let ownerMarker = OwnerMarker.value

    public static func write(
        to folder: URL,
        segments: [TranscriptSegment],
        startedAt: Date,
        duration: TimeInterval,
        participants: [String] = [],
        tags: [String] = ["call"],
        title: String? = nil,
        summary: String? = nil,
        screenSnippets: [ScreenSnippet] = [],
        notes: [CallNote] = [],
        isConference: Bool = false,
    ) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let url = uniqueURL(in: folder, startedAt: startedAt, title: title)
        var contents = frontmatter(startedAt: startedAt, duration: duration,
                                   participants: participants, tags: tags, title: title,
                                   isConference: isConference)
        if let summary, !summary.isEmpty {
            contents += "\n\n## Summary\n\n" + summary
        }
        contents += "\n" + body(segments: segments, notes: notes) + "\n"
        if !screenSnippets.isEmpty {
            contents += "\n" + screenContext(screenSnippets) + "\n"
        }

        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Formatting

    /// Frontmatter and filename stamps are machine-readable contracts (index parsing, `since`
    /// filters, sorting) — POSIX-locked so Thai/Arabic system locales can't write Buddhist-era
    /// years or non-ASCII digits into them.
    private static func posixFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static func frontmatter(startedAt: Date, duration: TimeInterval,
                                    participants: [String], tags: [String], title: String?,
                                    isConference: Bool) -> String {
        let dateFmt = posixFormatter("yyyy-MM-dd")
        let timeFmt = posixFormatter("HH:mm")
        let dateStr = dateFmt.string(from: startedAt)
        let timeStr = timeFmt.string(from: startedAt)

        // Every scalar goes through the sanitizer — enricher topics and calendar attendees are
        // uncontrolled input, and one embedded quote/newline invalidates the whole block.
        let allTags = (tags + [ownerMarker]).map(sanitizeScalar).filter { !$0.isEmpty }
        let tagList = allTags.map { "\"\($0)\"" }.joined(separator: ", ")
        let participantList = participants.map(sanitizeScalar).filter { !$0.isEmpty }
            .map { "\"\($0)\"" }.joined(separator: ", ")

        let cleanTitle = title.map(sanitizeScalar) ?? ""
        let heading = cleanTitle.isEmpty ? "Call — \(dateStr) \(timeStr)" : cleanTitle

        var yaml = "---\n"
        yaml += "date: \(dateStr)\n"
        yaml += "time: \"\(timeStr)\"\n"
        yaml += "duration: \"\(formatClock(duration))\"\n"
        // `title` IS ALWAYS WRITTEN, including the untitled case. It used to be omitted when empty,
        // and `heading` — the very value being omitted — was computed on the line above and used
        // for the H1, so the file carried the title in prose and withheld it as data. The exporter
        // then read it back out of the H1 with a regex (`_title_for`), and every other reader had to
        // do the same or fall back to the filename. One computed value, stated once, in the field
        // that means it.
        yaml += "title: \"\(heading)\"\n"
        yaml += "participants: [\(participantList)]\n"
        yaml += "tags: [\(tagList)]\n"
        // Recorded from a single source, unlabeled. Absent = a normal two-party call.
        if isConference { yaml += "mode: conference\n" }
        // NO `group:`. The workspace is WHERE THE FILE IS (Doc 4 §7) — a transcript inside a
        // vault belongs to that vault, and `TranscriptStore.meta` derives it from the path. Writing
        // it here as well was a second answer to a question the folder already answers, and the two
        // could disagree: `IndexBuilder` had to log the conflict and pick a winner.
        // The spine, so the file is a self-describing note rather than one that only becomes a note
        // rather than leaving four values for something downstream to synthesise. See `TranscriptSpine`
        // for why each is what it is, and why the exporter still authors its own for now.
        yaml += "status: \(TranscriptSpine.status)\n"
        yaml += "doc_type: \(TranscriptSpine.docType)\n"
        yaml += "confidence: \(TranscriptSpine.confidence)\n"
        yaml += "class: \(TranscriptSpine.documentClass)\n"
        yaml += "app: \(ownerMarker)\n"
        yaml += "---\n\n# \(heading)"
        return yaml
    }

    /// The one YAML scalar sanitizer (writer + metadata editor). Values are emitted inside
    /// double quotes on a single key line, so stripping quotes and line breaks is what keeps a
    /// value — including one containing `---` — from escaping its line. Parsers must split
    /// frontmatter on delimiter LINES (see `Frontmatter`), never on the `---` substring.
    ///
    /// "LINE BREAK" IS THE READER'S DEFINITION, NOT `\n`. This replaced `\r\n`, `\n` and `\r` by
    /// name and let eight other characters through — `U+000B`, `U+000C`, `U+001C`–`U+001E`,
    /// `U+0085`, `U+2028`, `U+2029` — every one of which Python's `str.splitlines()` treats as a
    /// break, and `str.splitlines()` is what the engine's frontmatter reader splits the block with.
    /// One of those in a title (`U+2028` and `U+0085` arrive routinely in text pasted from Word or
    /// a browser, and `TranscriptMetadataEditor` feeds operator-typed titles straight here) forges
    /// a frontmatter line, and a line with no colon stops the block being frontmatter at all —
    /// which refuses the whole scope at the next compose, over a recorded call, the artefact this
    /// codebase calls unrecreatable.
    ///
    /// So the predicate is structural: anything Swift calls a newline, plus the C0 range. That is
    /// `NoteWriter.sanitized`'s rule, and this is now the one implementation of it — the note
    /// writer was the only one of the four scalar writers that had it right, and it had it right
    /// because it was written after this gap was found rather than before.
    ///
    /// TAB GOES TOO, and it is the one character where "one rule" beat a defensible exception. A
    /// tab is not a line break to any reader here and a tab inside a quoted scalar is legal, so
    /// keeping it would have been fine — but the note writer spaces it, and two sanitizers that
    /// agree on ten characters and differ on the eleventh is exactly the divergence that has to be
    /// re-derived by every reader who compares them.
    public static func sanitizeScalar(_ text: String) -> String {
        flattenedControlCharacters(text)
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every line break and control character replaced by a space — THE HALF ALL FOUR SCALAR
    /// WRITERS SHARE, written once.
    ///
    /// The four differ on quoting and they should: `tomlString` escapes because a TOML reader
    /// unescapes, `SubstrateLibraryVault.scalar` decides quoting per value, and this substitutes.
    /// What none of them may do is emit a line break, because every reader on both sides splits
    /// frontmatter into LINES — and that half was copied verbatim into three files while the fourth
    /// carried a weaker version for months. Copies of a rule agree until they do not, and the way
    /// this one stopped agreeing was eight characters wide and refused a whole scope.
    ///
    /// `isNewline` IS THE POINT, not `\n`. It covers `U+000B`, `U+000C`, `U+0085`, `U+2028` and
    /// `U+2029`, which Python's `str.splitlines()` — what the engine's frontmatter reader uses —
    /// treats as breaks and a `\n`-only rule does not. The C0 test then catches `U+001C`–`U+001E`,
    /// which `splitlines()` also breaks on and which `isNewline` alone misses.
    public static func flattenedControlCharacters(_ text: String) -> String {
        String(text.map { character in
            character.isNewline || (character.asciiValue.map { $0 < 0x20 } ?? false)
                ? " " : character
        })
    }

    /// Renders spoken segments and manual notes as one chronological stream. A note is emitted as
    /// a `Note:`-labelled line — the same `**[stamp] Label:**` shape as a speaker turn — so the
    /// viewer renders it in place and the index chunks it as a searchable "Note" turn for free.
    /// At an identical timestamp the note sorts after the segment (it was typed in response to it).
    private static func body(segments: [TranscriptSegment], notes: [CallNote]) -> String {
        guard !segments.isEmpty || !notes.isEmpty else {
            return "\n_(No speech detected.)_"
        }
        var lines: [(ms: Int, order: Int, text: String)] = []
        for segment in segments {
            let stamp = formatClock(Double(segment.startMs) / 1000.0)
            let label = segment.speaker.map { " \($0.rawValue):" } ?? ""
            lines.append((segment.startMs, 0, "**[\(stamp)]\(label)** \(segment.text)"))
        }
        for note in notes {
            let stamp = formatClock(Double(note.startMs) / 1000.0)
            lines.append((note.startMs, 1, "**[\(stamp)] Note:** \(note.text)"))
        }
        let ordered = lines.sorted { $0.ms != $1.ms ? $0.ms < $1.ms : $0.order < $1.order }
        return "\n" + ordered.map(\.text).joined(separator: "\n\n")
    }

    private static func screenContext(_ snippets: [ScreenSnippet]) -> String {
        // Not blockquoted, so Markdown tables from the document reader render properly.
        let entries = snippets.map { snippet in
            "**[\(formatClock(Double(snippet.startMs) / 1000.0))]**\n\n\(snippet.text)"
        }
        return "## Screen Context\n\n" + entries.joined(separator: "\n\n---\n\n")
    }

    /// Seconds → M:SS or H:MM:SS.
    public static func formatClock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Builds a collision-free filename: "<Title> — 2026-07-13 1150.md", or
    /// "Call — 2026-07-13 1150.md" when there's no title.
    private static func uniqueURL(in folder: URL, startedAt: Date, title: String?) -> URL {
        let stamp = posixFormatter("yyyy-MM-dd HHmm").string(from: startedAt)
        let clean = title.map(sanitizeFilename) ?? ""
        let base = clean.isEmpty ? "Call — \(stamp)" : "\(clean) — \(stamp)"

        var candidate = folder.appendingPathComponent("\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(counter)).md")
            counter += 1
        }
        return candidate
    }

    private static func sanitizeFilename(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var result = title.components(separatedBy: invalid).joined(separator: " ")
        result = result.replacingOccurrences(of: "\n", with: " ")
        result = result.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > 50 {
            result = String(result.prefix(50)).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
