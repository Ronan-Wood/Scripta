import XCTest
@testable import ScriptaCore

/// Vector coverage is COMPLETENESS, not presence.
///
/// `IndexStore.vectorCoverage` replaced a `LIMIT 1` check that answered "are there any vectors".
/// `vectorCandidates` returns whatever it finds rather than raising, so one embedded chunk in a
/// corpus of thousands satisfied that check, sent `Retriever` down the hybrid path, and had RRF —
/// which scores by POSITION — fuse a full lexical list against a one-item vector list. That single
/// chunk arrived at rank 0 and scored as the vector arm's best possible answer, promoting one
/// arbitrarily-embedded passage toward the top of every query in the corpus.
///
/// The same guard exists on the engine side (`substrate/store/index_store.py:785`, asserted by
/// `substrate/tests/test_vector_coverage.py`); these are the Swift store's half of it.
final class VectorCoverageTests: XCTestCase {
    private var dir: URL!
    private var store: IndexStore!

    private static let model = "nomic-embed-text:latest"

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VectorCoverageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try IndexStore(url: dir.appendingPathComponent("index.db"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    /// One transcript carrying `count` chunks, returned as their row ids.
    @discardableResult
    private func seed(path: String, chunks count: Int) -> [Int64] {
        let transcript = IndexedTranscript(
            path: path, title: "Call", date: "2026-08-05", time: "09:00", duration: "10m",
            participants: ["You"], tags: ["sync"], summary: "s", mtime: 1, group: "", body: "b")
        let rows = (0..<count).map {
            IndexedChunk(startMs: $0 * 1000, endMs: ($0 + 1) * 1000, speaker: "You",
                         text: "chunk \($0) about budgets and hiring")
        }
        store.upsert(transcript, chunks: rows)
        return store.chunkRows(path: path).map(\.id)
    }

    private func vector() -> [Float] { (0..<8).map { Float($0) / 8 } }

    func testAnUnembeddedIndexReportsZeroOfItsChunks() {
        seed(path: "/tmp/a.md", chunks: 3)
        let coverage = store.vectorCoverage(model: Self.model)
        XCTAssertEqual(coverage.embedded, 0)
        XCTAssertEqual(coverage.total, 3)
    }

    /// THE BUG, pinned. Under the old `LIMIT 1` check this state answered `true` and turned hybrid
    /// retrieval on for the whole corpus.
    func testOneEmbeddedChunkIsNotCoverage() {
        let ids = seed(path: "/tmp/a.md", chunks: 50)
        store.storeVector(chunkID: ids[0], vector: vector(), model: Self.model)

        let coverage = store.vectorCoverage(model: Self.model)
        XCTAssertEqual(coverage.embedded, 1)
        XCTAssertEqual(coverage.total, 50)
        XCTAssertFalse(coverage.total > 0 && coverage.embedded >= coverage.total,
                       "1 of 50 must not read as fully embedded")
    }

    func testFullyEmbeddedReportsComplete() {
        let ids = seed(path: "/tmp/a.md", chunks: 4)
        for id in ids { store.storeVector(chunkID: id, vector: vector(), model: Self.model) }

        let coverage = store.vectorCoverage(model: Self.model)
        XCTAssertEqual(coverage.embedded, 4)
        XCTAssertEqual(coverage.total, 4)
        XCTAssertTrue(coverage.total > 0 && coverage.embedded >= coverage.total)
    }

    /// An EMPTY index satisfies `embedded >= total` as `0 >= 0`. The caller's `total > 0` is what
    /// stops that reading as fully covered — zero chunks is the absence of coverage, not the
    /// completion of it. Reachable after `clear()`, an interrupted index pass, or a reconcile that
    /// removed every document.
    func testAnEmptyIndexIsNotFullyCovered() {
        let coverage = store.vectorCoverage(model: Self.model)
        XCTAssertEqual(coverage.embedded, 0)
        XCTAssertEqual(coverage.total, 0)
        XCTAssertFalse(coverage.total > 0 && coverage.embedded >= coverage.total,
                       "an empty index must not satisfy the coverage bar")
    }

    /// Coverage is per model. A model change invalidates the whole vector space, and the retriever
    /// asks about the model it is about to embed the QUERY with — so vectors under a previous model
    /// must count for nothing rather than mask an unembedded corpus.
    func testCoverageIsScopedToTheModelAsked() {
        let ids = seed(path: "/tmp/a.md", chunks: 2)
        for id in ids { store.storeVector(chunkID: id, vector: vector(), model: "old-model") }

        XCTAssertEqual(store.vectorCoverage(model: Self.model).embedded, 0)
        XCTAssertEqual(store.vectorCoverage(model: "old-model").embedded, 2)
    }

    /// Partial coverage across PATHS, which is how this actually occurs in the field:
    /// `IndexBuilder.embedPending` skips a path whose embedder call fails and continues the loop, so
    /// one Ollama hiccup mid-batch leaves some transcripts embedded and some not.
    func testAPartlyEmbeddedCorpusIsNotCoverage() {
        let a = seed(path: "/tmp/a.md", chunks: 3)
        seed(path: "/tmp/b.md", chunks: 3)
        for id in a { store.storeVector(chunkID: id, vector: vector(), model: Self.model) }

        let coverage = store.vectorCoverage(model: Self.model)
        XCTAssertEqual(coverage.embedded, 3)
        XCTAssertEqual(coverage.total, 6)
        XCTAssertFalse(coverage.total > 0 && coverage.embedded >= coverage.total)
    }

    /// The numerator JOINs `chunks`, so a vector whose chunk is gone counts for nothing. Today both
    /// delete paths remove vectors, so this cannot arise through the store's own API — the JOIN is
    /// what stops a future delete path that forgets from producing enough orphans to satisfy the
    /// bar on a partly-embedded index, reported as complete.
    func testOrphanedVectorsDoNotInflateTheNumerator() {
        let ids = seed(path: "/tmp/a.md", chunks: 2)
        for id in ids { store.storeVector(chunkID: id, vector: vector(), model: Self.model) }
        XCTAssertEqual(store.vectorCoverage(model: Self.model).embedded, 2)

        store.remove(path: "/tmp/a.md")
        let coverage = store.vectorCoverage(model: Self.model)
        XCTAssertEqual(coverage.total, 0)
        XCTAssertEqual(coverage.embedded, 0, "a vector with no chunk behind it must not count")
    }
}
