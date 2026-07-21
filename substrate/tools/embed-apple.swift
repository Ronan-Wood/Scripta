// embed-apple — on-device passage embeddings via Apple's NLContextualEmbedding.
//
// Answers whether the substrate can run with NO Ollama at all. Apple ships two on-device
// embedders; NLContextualEmbedding is the right one here (transformer, contextual) because
// NLEmbedding.sentenceEmbedding is sentence-scale and our chunks average ~1,500 chars.
//
// It returns PER-TOKEN vectors, so passage vectors are mean-pooled then L2-normalized —
// normalizing so a dot product is cosine, matching what the Python store already assumes.
//
// Protocol, matching hyde-fm so the Python side stays trivial:
//   stdin : one text per line, with literal newlines escaped as "\\n"
//   stdout: one line per input — base64 of little-endian float32s, or empty on failure
//   Base64 rather than JSON: 512 floats per chunk over ~1,900 chunks makes encoding cost
//   real, and this keeps it to one allocation per vector.

import Foundation
import NaturalLanguage

guard #available(macOS 14.0, *) else {
    FileHandle.standardError.write("embed-apple: requires macOS 14\n".data(using: .utf8)!)
    exit(2)
}

guard let model = NLContextualEmbedding(language: .english) else {
    FileHandle.standardError.write("embed-apple: no english model\n".data(using: .utf8)!)
    exit(2)
}
do { try model.load() } catch {
    FileHandle.standardError.write("embed-apple: load failed \(error)\n".data(using: .utf8)!)
    exit(2)
}

setbuf(stdout, nil)
print("READY \(model.dimension)")

while let line = readLine(strippingNewline: true) {
    let text = line.replacingOccurrences(of: "\\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { print(""); continue }

    do {
        let result = try model.embeddingResult(for: text, language: .english)
        var sum = [Double](repeating: 0, count: model.dimension)
        var n = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
            for i in 0..<min(vec.count, sum.count) { sum[i] += vec[i] }
            n += 1
            return true
        }
        if n == 0 { print(""); continue }

        // Mean-pool, then L2-normalize so dot product == cosine.
        var norm = 0.0
        for i in 0..<sum.count { sum[i] /= Double(n); norm += sum[i] * sum[i] }
        norm = norm.squareRoot()
        if norm == 0 { print(""); continue }

        var floats = [Float32](repeating: 0, count: sum.count)
        for i in 0..<sum.count { floats[i] = Float32(sum[i] / norm) }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        print(data.base64EncodedString())
    } catch {
        print("")
    }
}
