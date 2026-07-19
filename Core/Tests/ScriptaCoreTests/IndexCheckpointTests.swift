import XCTest
@testable import ScriptaCore
@testable import ScriptaShared
import SQLite3

/// WAL checkpointing — operational robustness for the retrieval index. In WAL mode every write is
/// deferred into the -wal file; without a checkpoint it grows unbounded, bloating on disk and slowing
/// the read-only opener the bundled MCP uses. `IndexStore.checkpoint()` (run at the end of an indexing
/// pass) must fold those writes back into index.db and truncate the -wal — while a concurrent read-only
/// connection (exactly what the MCP is: `SQLITE_OPEN_READONLY`, per-request) still sees every committed
/// row before AND after the checkpoint. Drives the real `IndexStore` against a temp DB.
final class IndexCheckpointTests: XCTestCase {
    private var dir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IndexCheckpointTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("index.db")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var walURL: URL { URL(fileURLWithPath: dbURL.path + "-wal") }
    private func walSize() -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: walURL.path))?[.size] as? Int) ?? 0
    }

    func testCheckpointTruncatesWALWhileReadOnlyStillReads() throws {
        // Keep the writer alive for the whole test: while it's open it maintains the -shm the read-only
        // openers attach through — the live-writer invariant the app upholds (the MCP even refuses on a
        // stale heartbeat), and what lets a read-only connection read a WAL database at all.
        let store = try IndexStore(url: dbURL)

        // A corpus large enough to push real bytes into the WAL, but well under the 1000-page default
        // auto-checkpoint threshold so nothing checkpoints until we ask — making `walBefore` deterministic.
        let longText = String(repeating: "budgets, hiring, and roadmap planning; ", count: 6)
        for i in 0..<30 {
            let t = IndexedTranscript(
                path: "/tmp/call-\(i).md", title: "Call \(i)", date: "2026-07-18", time: "09:00",
                duration: "10m", participants: ["You", "Them"], tags: ["sync"],
                summary: "summary for call \(i)", mtime: Double(i), group: "")
            let chunks = (0..<4).map { j in
                IndexedChunk(startMs: j * 1000, endMs: j * 1000 + 900, speaker: "You",
                             text: "passage \(i)-\(j): \(longText)")
            }
            store.upsert(t, chunks: chunks)
        }

        // WAL mode holds the writes in the -wal file, not index.db, until a checkpoint.
        let walBefore = walSize()
        XCTAssertGreaterThan(walBefore, 20_000, "the WAL should hold the pass's writes before the checkpoint")

        // A concurrent read-only opener — exactly how the MCP opens the DB — sees the committed rows
        // through the WAL. Opened before the checkpoint and kept open across it.
        let ro = try openReadOnly()
        defer { sqlite3_close(ro) }
        XCTAssertEqual(count(ro, "SELECT COUNT(*) FROM transcripts"), 30, "read-only sees rows before checkpoint")
        XCTAssertEqual(count(ro, "SELECT COUNT(*) FROM chunks"), 120, "read-only sees chunks before checkpoint")

        // The pass ends: fold the WAL back into index.db and truncate it.
        store.checkpoint()

        XCTAssertLessThan(walSize(), 4_096, "wal_checkpoint(TRUNCATE) must shrink the -wal file to ~0 bytes")
        XCTAssertLessThan(walSize(), walBefore, "the checkpoint must reclaim the WAL's space")

        // The connection opened BEFORE the checkpoint still reads every row (now served from index.db;
        // SQLite re-syncs the reader after the WAL reset) — no data lost across the truncation...
        XCTAssertEqual(count(ro, "SELECT COUNT(*) FROM transcripts"), 30, "pre-checkpoint reader still reads after")
        XCTAssertEqual(count(ro, "SELECT COUNT(*) FROM chunks"), 120, "chunks intact for the pre-checkpoint reader")

        // ...and a freshly-opened read-only connection sees them too.
        let ro2 = try openReadOnly()
        defer { sqlite3_close(ro2) }
        XCTAssertEqual(count(ro2, "SELECT COUNT(*) FROM transcripts"), 30, "fresh read-only reader sees rows after")

        // Writing again after a TRUNCATE checkpoint still works and stays readable (the WAL re-grows
        // cleanly, the checkpoint didn't wedge the writer).
        store.upsert(IndexedTranscript(path: "/tmp/call-late.md", title: "Late", date: "2026-07-18",
                                       time: "10:00", duration: "5m", participants: ["You"], tags: [],
                                       summary: "added after checkpoint", mtime: 999, group: ""), chunks: [])
        XCTAssertEqual(count(ro2, "SELECT COUNT(*) FROM transcripts"), 31, "post-checkpoint write is visible read-only")

        withExtendedLifetime(store) {}
    }

    // MARK: - Raw read-only SQLite helpers (the MCP opens the DB exactly this way)

    private func openReadOnly() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw XCTSkip("could not open the index read-only")
        }
        sqlite3_busy_timeout(db, 3000)
        return db
    }

    private func count(_ db: OpaquePointer, _ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : -1
    }
}
