// rerank-fm — on-device listwise reranking via Apple Foundation Models.
//
// The third and last shim. Reranking is the single biggest lever in the retrieval stack
// (+0.095 to the shipped Ollama tier, and MEASURED to give its largest gains to the WEAKEST
// embedder: +0.147 to embeddinggemma, +0.128 to nomic, against +0.022 to the best one).
// Apple's embedder is the weakest in the fleet, so the default on-device tier is exactly the
// configuration that should benefit most — and until this existed it was the only tier
// running with no reranker at all.
//
// DUMB BY DESIGN. Unlike hyde-fm, which owns its instructions, this shim receives a
// fully-formed prompt and relays it. The ranking prompt, the candidate pool, the snippet
// width and the order parsing all live in rerank.py next to the Ollama arm they must stay
// comparable with. A prompt that drifted between the two arms would make the tiers
// non-comparable, which is the whole point of measuring them.
//
// Protocol, matching the other two shims:
//   stdin :  one fully-formed prompt per line, literal newlines escaped as "\\n"
//   stdout:  one reply per line, same escaping; EMPTY LINE on any failure, which the caller
//            treats as "keep the fused order" (fail open)
//
// Apple FM has a far smaller context window than the 7B running the Ollama arm, and a
// 20-candidate listwise prompt is not small. Overflow surfaces here as a thrown error and
// therefore as an empty line — the caller COUNTS those rather than silently absorbing them,
// because a systematically overflowing reranker would otherwise report the un-reranked
// number under the reranked label.

import Foundation

#if canImport(FoundationModels)
import FoundationModels

let instructions = """
You rank retrieved passages by how directly they ANSWER a question. You reply with passage \
numbers only, best first, comma-separated. Never explain. Never add words. Never repeat a \
number. A passage that merely mentions the topic ranks BELOW one that states the answer.
"""

@available(macOS 26.0, *)
func run() async {
    guard case .available = SystemLanguageModel.default.availability else {
        FileHandle.standardError.write("rerank-fm: model unavailable\n".data(using: .utf8)!)
        exit(2)
    }

    setbuf(stdout, nil)
    print("READY")

    while let line = readLine(strippingNewline: true) {
        let prompt = line.replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty { print(""); continue }

        // Fresh session per request, same rule as hyde-fm: an earlier ranking must not steer
        // a later one, or the eval stops being order-independent and stops being reproducible.
        let session = LanguageModelSession(instructions: instructions)
        do {
            let reply = try await session.respond(to: prompt)
            let text = reply.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: "\\n")
            print(text)
        } catch {
            // Most likely cause is context overflow on a 20-candidate prompt. Reported on
            // stderr for diagnosis; the empty line is what the caller acts on.
            FileHandle.standardError.write(
                "rerank-fm: \(error)\n".data(using: .utf8)!)
            print("")
        }
    }
}

if #available(macOS 26.0, *) {
    await run()
} else {
    FileHandle.standardError.write("rerank-fm: requires macOS 26\n".data(using: .utf8)!)
    exit(2)
}
#else
FileHandle.standardError.write("rerank-fm: FoundationModels unavailable\n".data(using: .utf8)!)
exit(2)
#endif
