import Foundation

// Retrieval eval harness. Builds a throwaway SQLite index from a transcript folder using the SAME
// shared indexing code the app uses (Frontmatter + Indexing + IndexStore), then runs each gold
// query through IndexStore.search and reports recall@1, recall@5, and MRR against written gates.
//
// Usage: eval [--legacy] [--folder <path>] [--gold <path>] [--k <n>]
//   --legacy  measure the pre-overhaul OR-of-all-terms behaviour (baseline comparison)

// MARK: - Gold

struct Gold: Decodable {
    struct Case: Decodable {
        let id: String
        let query: String
        let expect: [String]
        var participant: String?
        var tag: String?
        var since: String?
    }
    struct Gates: Decodable { let recallAt5: Double; let recallAt1: Double; let mrr: Double }
    let cases: [Case]
    let gates: Gates
}

// MARK: - Args

var legacy = false
var folderPath = ("~/Documents/CallTranscriber" as NSString).expandingTildeInPath
var goldPath = "Eval/gold.json"
var topK = 5
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--legacy": legacy = true
        case "--folder": if let v = it.next() { folderPath = (v as NSString).expandingTildeInPath }
        case "--gold": if let v = it.next() { goldPath = v }
        case "--k": if let v = it.next(), let n = Int(v) { topK = n }
        default: break
        }
    }
}

func die(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(2) }

guard let goldData = FileManager.default.contents(atPath: goldPath),
      let gold = try? JSONDecoder().decode(Gold.self, from: goldData) else {
    die("Could not read gold cases at \(goldPath)")
}

// MARK: - Minimal frontmatter field parsing (eval-only glue; the app uses TranscriptStore)

func field(_ fm: String, _ key: String) -> String {
    for line in fm.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\(key):") {
            return String(t.dropFirst(key.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: " \"[]"))
        }
    }
    return ""
}

func list(_ fm: String, _ key: String) -> [String] {
    var raw = ""
    for line in fm.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\(key):") { raw = String(t.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces); break }
    }
    if raw.hasPrefix("[") { raw.removeFirst() }
    if raw.hasSuffix("]") { raw.removeLast() }
    if raw.contains("\"") {
        var items: [String] = []; var cur = ""; var q = false
        for ch in raw {
            if ch == "\"" { if q { let it = cur.trimmingCharacters(in: .whitespaces); if !it.isEmpty { items.append(it) }; cur = "" }; q.toggle() }
            else if q { cur.append(ch) }
        }
        return items
    }
    return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

// MARK: - Build a fresh index

let tmpDB = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("calltranscriber-eval-\(UUID().uuidString).db")
defer { try? FileManager.default.removeItem(at: tmpDB) }

guard let store = try? IndexStore(url: tmpDB) else { die("Could not open temp index") }
store.queryMode = legacy ? .legacyOr : .andFirst

let folder = URL(fileURLWithPath: folderPath)
let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "md" }
var indexed = 0
for url in files {
    guard let content = try? String(contentsOf: url, encoding: .utf8),
          let split = Frontmatter.split(content), Frontmatter.hasOwnerMarker(split.frontmatter) else { continue }
    let fm = split.frontmatter
    let transcript = IndexedTranscript(
        path: url.path, title: field(fm, "title"), date: field(fm, "date"), time: field(fm, "time"),
        duration: field(fm, "duration"),
        participants: list(fm, "participants"),
        tags: list(fm, "tags").filter { $0 != OwnerMarker.value },
        summary: Indexing.summary(from: content), mtime: 0)
    store.upsert(transcript, chunks: Indexing.chunks(from: content))
    indexed += 1
}
if indexed == 0 { die("No app-authored transcripts found in \(folderPath)") }

// MARK: - Score

func relevant(_ path: String, _ expect: [String]) -> Bool {
    let name = (path as NSString).lastPathComponent
    return expect.contains { name.contains($0) }
}

var recall1 = 0.0, recall5 = 0.0, mrrSum = 0.0
var rows: [String] = []
for c in gold.cases {
    let hits = store.search(c.query, participant: c.participant, tag: c.tag, since: c.since, limit: max(topK, 10))
    let rank = hits.firstIndex(where: { relevant($0.path, c.expect) }).map { $0 + 1 }
    let inTop1 = (rank ?? 99) <= 1
    let inTopK = (rank ?? 99) <= topK
    if inTop1 { recall1 += 1 }
    if inTopK { recall5 += 1 }
    if let r = rank { mrrSum += 1.0 / Double(r) }
    let mark = inTopK ? "ok " : "MISS"
    let rankStr = rank.map { "#\($0)" } ?? "—"
    rows.append(String(format: "  [%@] %-26@ rank %@", mark, c.id as NSString, rankStr as NSString))
}

let n = Double(gold.cases.count)
let r1 = recall1 / n, r5 = recall5 / n, mrr = mrrSum / n

print("Retrieval eval — \(legacy ? "LEGACY (OR-of-all-terms)" : "current (AND-first + stopwords)")")
print("  corpus: \(indexed) transcripts · \(gold.cases.count) gold cases · k=\(topK)\n")
print(rows.joined(separator: "\n"))
print(String(format: "\n  recall@1 %.2f   recall@%d %.2f   MRR %.3f", r1, topK, r5, mrr))

let pass = r5 >= gold.gates.recallAt5 && r1 >= gold.gates.recallAt1 && mrr >= gold.gates.mrr
print(String(format: "  gates: recall@5≥%.2f recall@1≥%.2f MRR≥%.2f  →  %@",
             gold.gates.recallAt5, gold.gates.recallAt1, gold.gates.mrr, (pass ? "PASS" : "FAIL") as NSString))
exit(pass ? 0 : 1)
