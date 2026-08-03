import Foundation

// MARK: - Reading the wire shape out of the engine that defines it
//
// `substrate/substrate/render.py` owns every field name the Swift side decodes, and it is not
// Swift. The obvious alternative — writing the expected key sets down in this test — is a second
// source of truth for the one thing the gate exists to measure, and it goes stale silently: a suite
// scoring last month's payload passes cheerfully and means nothing. So this reads the keys out of
// the Python instead. There is exactly one set of field names in the repo.
//
// It is the same trade `ThemeTokenSource` made for `Ink.swift`, with the same cost stated plainly:
// this couples to the SHAPE of the declarations, not just their values. Reformat `render.py` and
// the parser stops recognising a dict — which is why `RenderContractTests` asserts floors on what
// it found. A parse failure is loud. A stale copy would not have been.
//
// WHAT IT CATCHES: a key added to, removed from or renamed in any payload builder it is pointed at;
// a value added to or removed from a spine vocabulary.
//
// WHAT IT DOES NOT CATCH, stated so nobody reads more into a green suite than is there:
//   * a TYPE change — `n_chars` becoming a string, `frozen` becoming a three-valued string
//   * a NESTING change — a key moved from `filters` into a new sub-object of the same name
//   * a key emitted through a variable, a comprehension or `**kwargs` rather than a literal
//   * a key added to a dict this test does not name
//   * semantics: `sources_excluded` inverting its meaning renames nothing
// The lossless round-trip against captured bytes covers types and nesting for the shapes that were
// captured; nothing covers the last one, which is why the live test re-checks against the socket.

struct PythonSource {
    let path: String
    let text: String

    /// `#filePath`, not the working directory: `swift test` and Xcode disagree about cwd, and a
    /// gate that silently finds no file is worse than one that cannot run.
    static func load(_ repositoryRelativePath: String) throws -> PythonSource {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SubstrateKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // repository root
        let url = root.appendingPathComponent(repositoryRelativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PythonSourceError.fileMissing(url.path)
        }
        return PythonSource(path: url.path, text: try String(contentsOf: url, encoding: .utf8))
    }

    /// Every dict literal `function` builds, plus the keys it bolts on afterwards.
    func payload(of function: String) throws -> PythonPayload {
        guard let body = Self.functionBody(named: function, in: text) else {
            throw PythonSourceError.functionMissing(function, path)
        }
        let code = Self.strippingCommentsAndDocstrings(body)
        let literals = Self.topLevelBraceGroups(code)
        return PythonPayload(
            // Empty groups are dropped: `freshness.drift` opens with two dict COMPREHENSIONS whose
            // keys are expressions, so they legitimately contribute no literal keys and would
            // otherwise shift the index of the dict that matters.
            dicts: literals.map(\.keys).filter { !$0.isEmpty },
            sets: literals.map(\.members).filter { !$0.isEmpty },
            assigned: Self.subscriptAssignments(code)
        )
    }

    /// A module-level binding — `NAME = {...}` or `NAME = frozenset({...})`.
    func binding(_ name: String) throws -> PythonPayload {
        let lines = text.components(separatedBy: .newlines)
        // Matched at column 0 and on the identifier BOUNDARY, so `CONFIDENCES` does not answer for
        // `STORED_CONFIDENCES` and a mention inside prose cannot stand in for the declaration.
        guard let start = lines.firstIndex(where: { line in
            guard line.hasPrefix(name) else { return false }
            let next = line.dropFirst(name.count).first
            return next == nil || !(next!.isLetter || next!.isNumber || next! == "_")
        }) else { throw PythonSourceError.bindingMissing(name, path) }

        let tail = lines[start...].joined(separator: "\n")
        guard let group = Self.topLevelBraceGroups(
            Self.strippingCommentsAndDocstrings(tail)
        ).first else { throw PythonSourceError.bindingMissing(name, path) }
        return PythonPayload(dicts: [group.keys], sets: [group.members], assigned: [:])
    }

    /// A module-level string constant — `NAME = "value"`.
    func stringConstant(_ name: String) throws -> String {
        for line in text.components(separatedBy: .newlines) {
            guard line.hasPrefix("\(name) = \"") else { continue }
            let body = line.dropFirst("\(name) = \"".count)
            guard let close = body.firstIndex(of: "\"") else { break }
            return String(body[body.startIndex..<close])
        }
        throw PythonSourceError.bindingMissing(name, path)
    }

    // MARK: Parsing

    private static func functionBody(named function: String, in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("def \(function)(")
        }) else { return nil }
        let defIndent = lines[start].prefix { $0 == " " }.count

        // Walk past the SIGNATURE first. A multi-line one closes with `) -> dict:` sitting at the
        // def's own indent, so "the first line back at the def's indent" is not the end of the
        // function — reading it that way silently made `applied_filters`' body two parameter lines
        // long, and every key it emits would have gone unchecked.
        var cursor = start
        var parens = 0
        repeat {
            for character in lines[cursor] where character == "(" || character == ")" {
                parens += (character == "(" ? 1 : -1)
            }
            cursor += 1
        } while cursor < lines.count && parens > 0

        var body: [String] = []
        for line in lines[cursor...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && line.prefix(while: { $0 == " " }).count <= defIndent { break }
            body.append(line)
        }
        return body.joined(separator: "\n")
    }

    /// Comments and triple-quoted docstrings out; every other character, string literals included,
    /// left exactly where it was. Done character-wise because a `#` inside a string is not a
    /// comment and an f-string's `{}` is not a dict.
    static func strippingCommentsAndDocstrings(_ source: String) -> String {
        var out = ""
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "#" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "\"" || c == "'" {
                let triple = i + 2 < chars.count && chars[i + 1] == c && chars[i + 2] == c
                let delimiter = triple ? String(repeating: String(c), count: 3) : String(c)
                let (literal, next) = consumeString(chars, from: i, delimiter: delimiter)
                if !triple { out += literal }
                i = next
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Returns the literal INCLUDING its delimiters, and the index just past it.
    private static func consumeString(_ chars: [Character], from start: Int,
                                      delimiter: String) -> (String, Int) {
        let delimiterChars = Array(delimiter)
        var literal = String(delimiterChars)
        var i = start + delimiterChars.count
        while i < chars.count {
            if chars[i] == "\\" && i + 1 < chars.count {
                literal.append(chars[i])
                literal.append(chars[i + 1])
                i += 2
                continue
            }
            if chars[i] == delimiterChars[0],
               Array(chars[i..<min(i + delimiterChars.count, chars.count)]) == delimiterChars {
                literal += delimiter
                return (literal, i + delimiterChars.count)
            }
            literal.append(chars[i])
            i += 1
        }
        return (literal, chars.count)
    }

    struct BraceGroup {
        /// String literals at depth 1 followed by `:` — a dict's keys.
        var keys: [String] = []
        /// String literals at depth 1 NOT followed by `:` — a set's members, or a positional
        /// argument inside a dict's value.
        var members: [String] = []
    }

    /// Every outermost `{ … }` in `code`, in source order.
    static func topLevelBraceGroups(_ code: String) -> [BraceGroup] {
        var groups: [BraceGroup] = []
        var current = BraceGroup()
        var depth = 0
        let chars = Array(code)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" || c == "'" {
                let (literal, next) = consumeString(chars, from: i, delimiter: String(c))
                if depth == 1 {
                    var j = next
                    while j < chars.count, chars[j] == " " || chars[j] == "\n" { j += 1 }
                    let value = String(literal.dropFirst().dropLast())
                    if j < chars.count && chars[j] == ":" {
                        current.keys.append(value)
                    } else {
                        current.members.append(value)
                    }
                }
                i = next
                continue
            }
            if c == "{" {
                depth += 1
                if depth == 1 { current = BraceGroup() }
            } else if c == "}" {
                if depth == 1 { groups.append(current) }
                depth = max(0, depth - 1)
            }
            i += 1
        }
        return groups
    }

    /// `target["key"] = …`, the form a payload builder uses to bolt a field on after the literal.
    static func subscriptAssignments(_ code: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for raw in code.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let open = line.range(of: "[\""),
                  let close = line.range(of: "\"]", range: open.upperBound..<line.endIndex),
                  line[close.upperBound...].trimmingCharacters(in: .whitespaces).hasPrefix("=") else {
                continue
            }
            let target = String(line[line.startIndex..<open.lowerBound])
            guard !target.isEmpty,
                  target.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            let key = String(line[open.upperBound..<close.lowerBound])
            // A repeated assignment (`out["drift"]` in both branches of a try/except) is one key.
            if !(out[target] ?? []).contains(key) { out[target, default: []].append(key) }
        }
        return out
    }
}

struct PythonPayload {
    let dicts: [[String]]
    let sets: [[String]]
    let assigned: [String: [String]]

    /// The first non-empty dict's keys plus anything assigned onto `target` afterwards.
    func keys(dict index: Int = 0, plus target: String? = nil) -> Set<String> {
        var out = Set(dicts.indices.contains(index) ? dicts[index] : [])
        if let target { out.formUnion(assigned[target] ?? []) }
        return out
    }

    var members: Set<String> { Set(sets.first ?? []) }
}

enum PythonSourceError: Error, CustomStringConvertible {
    case fileMissing(String)
    case functionMissing(String, String)
    case bindingMissing(String, String)

    var description: String {
        switch self {
        case .fileMissing(let path):
            return "\(path) not found. The wire-shape gate reads the engine's own source; without "
                + "it there is nothing to compare the Swift decoder against."
        case .functionMissing(let name, let path):
            return "no `def \(name)(` in \(path). It was renamed or moved — point the gate at its "
                + "new home rather than deleting the assertion."
        case .bindingMissing(let name, let path):
            return "no module-level `\(name)` in \(path)."
        }
    }
}
