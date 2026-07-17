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
        var slice: String?   // "lexical" (default), "paraphrase", "temporal", … for slice-level gates
    }
    struct Gates: Decodable { let recallAt5: Double; let recallAt1: Double; let mrr: Double }
    let cases: [Case]
    let gates: Gates
}

/// Per-case pass/fail from the last run at the SAME config+corpus fingerprint. Used to flag
/// regressions (a case that used to pass now failing) — gated total, not aggregate. Local-only.
struct Baseline: Codable {
    var fingerprint: String
    var passed: [String: Bool]
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
    .appendingPathComponent("scripta-eval-\(UUID().uuidString).db")
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

// Config + corpus fingerprint: a baseline/gate only compares runs at the SAME fingerprint. Corpus
// growth or an engine-config change is a deliberate event that resets the regression baseline.
let mode = legacy ? "legacyOr" : "andFirst"
let fingerprint = "mode=\(mode);corpus=\(indexed);gold=\(gold.cases.count);k=\(topK)"

var recall1 = 0.0, recall5 = 0.0, mrrSum = 0.0
var rows: [String] = []
var latencies: [Double] = []
var nowPassed: [String: Bool] = [:]
var bySlice: [String: (n: Int, r5: Int)] = [:]
for c in gold.cases {
    let t0 = Date()
    let hits = store.search(c.query, participant: c.participant, tag: c.tag, since: c.since, limit: max(topK, 10))
    latencies.append(Date().timeIntervalSince(t0) * 1000)
    let rank = hits.firstIndex(where: { relevant($0.path, c.expect) }).map { $0 + 1 }
    let inTop1 = (rank ?? 99) <= 1
    let inTopK = (rank ?? 99) <= topK
    if inTop1 { recall1 += 1 }
    if inTopK { recall5 += 1 }
    if let r = rank { mrrSum += 1.0 / Double(r) }
    nowPassed[c.id] = inTopK
    let slice = c.slice ?? "lexical"
    bySlice[slice, default: (0, 0)].n += 1
    if inTopK { bySlice[slice]!.r5 += 1 }
    let mark = inTopK ? "ok " : "MISS"
    let rankStr = rank.map { "#\($0)" } ?? "—"
    rows.append(String(format: "  [%@] %-26@ rank %@", mark, c.id as NSString, rankStr as NSString))
}

let n = Double(gold.cases.count)
let r1 = recall1 / n, r5 = recall5 / n, mrr = mrrSum / n
latencies.sort()
func pct(_ p: Double) -> Double { latencies.isEmpty ? 0 : latencies[min(latencies.count - 1, Int(p * Double(latencies.count)))] }

print("Retrieval eval — \(legacy ? "LEGACY (OR-of-all-terms)" : "current (AND-first + stopwords)")")
print("  fingerprint: \(fingerprint)\n")
print(rows.joined(separator: "\n"))
print(String(format: "\n  recall@1 %.2f   recall@%d %.2f   MRR %.3f", r1, topK, r5, mrr))
print(String(format: "  latency: p50 %.2f ms · p95 %.2f ms", pct(0.5), pct(0.95)))
for (slice, s) in bySlice.sorted(by: { $0.key < $1.key }) {
    print(String(format: "  slice %-12@ recall@%d %.2f (%d cases)", slice as NSString, topK, Double(s.r5) / Double(s.n), s.n))
}

// Per-case regression check against the frozen baseline (same fingerprint only).
let baselineURL = URL(fileURLWithPath: "Eval/.eval-baseline.json")
var regressions: [String] = []
if let data = try? Data(contentsOf: baselineURL),
   let base = try? JSONDecoder().decode(Baseline.self, from: data), base.fingerprint == fingerprint {
    regressions = nowPassed.filter { id, pass in base.passed[id] == true && !pass }.keys.sorted()
    if regressions.isEmpty { print("  regression check: no previously-passing case regressed") }
    else { print("  regression check: FAIL — regressed: \(regressions.joined(separator: ", "))") }
} else {
    print("  regression check: new fingerprint — establishing baseline (no comparison)")
}

let aggregatePass = r5 >= gold.gates.recallAt5 && r1 >= gold.gates.recallAt1 && mrr >= gold.gates.mrr
let retrievalPass = aggregatePass && regressions.isEmpty
print(String(format: "  gates: recall@5≥%.2f recall@1≥%.2f MRR≥%.2f + no-regression  →  %@",
             gold.gates.recallAt5, gold.gates.recallAt1, gold.gates.mrr, (retrievalPass ? "PASS" : "FAIL") as NSString))

// Update the baseline only on a clean pass (a regression stays flagged until fixed).
if retrievalPass, let data = try? JSONEncoder().encode(Baseline(fingerprint: fingerprint, passed: nowPassed)) {
    try? data.write(to: baselineURL)
}

// MARK: - Leak-check invariant (the Phase 1 gate)
// The real corpus is ungrouped (""). Inject grouped fixtures with IDENTICAL content across two
// groups, then assert as a TOTAL invariant (every result of every scoped query, not a sample):
// a query scoped to a workspace NEVER returns a call from another. Also test the ungrouped bucket.

print("\nPrivacy-wall leak check")
var pathGroup: [String: String] = [:]   // real corpus paths default to "" via lookup fallback
func fixture(_ path: String, _ group: String, _ text: String) {
    let t = IndexedTranscript(path: path, title: "Fixture", date: "2026-07-16", time: "10:00",
        duration: "1:00", participants: ["Sam"], tags: ["call"], summary: "shared budget project deal",
        mtime: 0, mode: "", group: group)
    store.upsert(t, chunks: [IndexedChunk(startMs: 0, endMs: 1000, speaker: nil, text: text)])
    pathGroup[path] = group
}
let sharedText = "we discussed the budget and the baseball project and the acme deal pricing"
fixture("/fx-alpha-1.md", "Alpha", sharedText)
fixture("/fx-alpha-2.md", "Alpha", "alpha only vacation plans and the family reunion")
fixture("/fx-beta-1.md",  "Beta",  sharedText)
fixture("/fx-beta-2.md",  "Beta",  "beta only quarterly targets and the hiring plan")

let probes = gold.cases.map(\.query) + ["budget", "baseball", "project", "deal", "vacation", "hiring", "the"]
var checks = 0, leaks = 0
for g in ["Alpha", "Beta", ""] {
    for q in probes {
        for hit in store.search(q, group: g, limit: 40) {
            checks += 1
            let actual = pathGroup[hit.path] ?? ""   // real (ungrouped) corpus → ""
            if actual != g {
                leaks += 1
                print("  LEAK: query \"\(q)\" scoped \"\(g)\" returned a \"\(actual)\" call (\(hit.path))")
            }
        }
    }
}
// Ungrouped-behavior: a grouped fixture must never surface in the "" bucket, and the all-groups
// override must reach every group.
let ungroupedShared = Set(store.search("budget baseball project", group: "", limit: 40).map(\.path))
let ungroupedLeak = ungroupedShared.contains { pathGroup[$0] != nil }   // any fixture in "" = leak
if ungroupedLeak { leaks += 1; print("  LEAK: a grouped fixture surfaced in the ungrouped bucket") }
let allGroups = Set(store.search(sharedText, group: nil, limit: 40).map(\.path))
let overrideReaches = allGroups.contains("/fx-alpha-1.md") && allGroups.contains("/fx-beta-1.md")

let leakPass = leaks == 0 && overrideReaches
print("  \(checks) scoped results checked across Alpha/Beta/ungrouped · all-groups override reaches both: \(overrideReaches)")
print("  → \(leakPass ? "PASS — the wall holds" : "FAIL — cross-group leak")")

// Vocabulary alias expansion: a synthetic call says the expansion, never the acronym; seeding
// the term must make the acronym query find it, scoped like everything else.
print("\nVocabulary alias expansion")
store.upsert(IndexedTranscript(
    path: "/fx-alias-1.md", title: "Sublease requirements", date: "2026-07-17", time: "09:00",
    duration: "1:00", participants: [], tags: [], summary: "", mtime: 0, mode: "", group: "AliasG"),
    chunks: [IndexedChunk(startMs: 0, endMs: 1000, speaker: nil,
                          text: "two tenants in the market are circling the sublease")])
let beforeTerm = store.search("TIM", group: "AliasG", limit: 10)
store.setTerms([IndexStore.TermRow(id: "t-eval", canonical: "TIM",
                                   aliases: ["tenants in the market"], gloss: "", group: "")])
let afterTerm = store.search("TIM", group: "AliasG", limit: 10)
let aliasPass = beforeTerm.isEmpty && afterTerm.contains { $0.path == "/fx-alias-1.md" }
print("  acronym query without term: \(beforeTerm.count) hits · with term seeded: \(afterTerm.count) hits")
print("  → \(aliasPass ? "PASS — \"TIM\" reaches \"tenants in the market\"" : "FAIL — expansion did not fire")")

let pass = retrievalPass && leakPass && aliasPass
print("\nOVERALL: \(pass ? "PASS" : "FAIL")")
exit(pass ? 0 : 1)
