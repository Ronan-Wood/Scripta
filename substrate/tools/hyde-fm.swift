// hyde-fm — on-device HyDE query expansion via Apple Foundation Models.
//
// Why this exists: the Python engine cannot reach FoundationModels (Swift-only), but the
// whole point of the substrate is that it works on-device by default. This is the smallest
// possible bridge — a persistent process that reads one query per line and writes one
// hypothetical passage per line.
//
// PERSISTENT, not one-shot: LanguageModelSession setup dominates per-query cost, so a
// process per query would measure startup rather than generation.
//
// Protocol is deliberately trivial so the Python side needs no parser:
//   stdin :  one query per line (newlines within a query are not supported, and are not
//            needed — queries are single-line by construction)
//   stdout:  one line per query, with literal \n escaped as "\\n"; empty line on failure,
//            which the caller treats as "fall back to the raw query"

import Foundation

#if canImport(FoundationModels)
import FoundationModels

let instructions = """
You write short factual paragraphs for a technical reference book. Given a question, write \
ONE paragraph, at most 80 words, in precise domain terminology, that would plausibly appear \
in the book section answering it. Use the field's standard vocabulary. Never mention the \
question. Never hedge. Never add preamble.
"""

@available(macOS 26.0, *)
func run() async {
    guard case .available = SystemLanguageModel.default.availability else {
        FileHandle.standardError.write("hyde-fm: model unavailable\n".data(using: .utf8)!)
        exit(2)
    }

    // One session, reused. Reset per query so an earlier answer cannot steer a later one —
    // each expansion must depend only on its own query, or results become order-dependent
    // and the eval stops being reproducible.
    setbuf(stdout, nil)
    print("READY")

    while let line = readLine(strippingNewline: true) {
        let query = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { print(""); continue }

        let session = LanguageModelSession(instructions: instructions)
        do {
            let reply = try await session.respond(to: query)
            let text = reply.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: "\\n")
            print(text)
        } catch {
            print("")
        }
    }
}

if #available(macOS 26.0, *) {
    await run()
} else {
    FileHandle.standardError.write("hyde-fm: requires macOS 26\n".data(using: .utf8)!)
    exit(2)
}
#else
FileHandle.standardError.write("hyde-fm: FoundationModels unavailable\n".data(using: .utf8)!)
exit(2)
#endif
