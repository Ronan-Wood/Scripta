import XCTest
@testable import ScriptaCore

/// Covers `EntityExtractor.mentions` against note/doc-shaped input — a single untimestamped
/// paragraph, not a call's speaker-turn chunks — since M20 is the first caller to feed it that
/// shape. The extractor itself has no chunk-source dependency (just `.text`/`.startMs`), but
/// nothing exercised that until notes/docs joined the entity graph.
final class EntityExtractorTests: XCTestCase {
    private func chunk(_ text: String) -> IndexedChunk {
        IndexedChunk(startMs: 0, endMs: 0, speaker: nil, text: text)
    }

    func testExtractsPersonFromNoteShapedText() {
        let mentions = EntityExtractor.mentions(chunks: [chunk("Talked to Bob Chen about the CPA deal.")], attendees: [])
        XCTAssertTrue(mentions.contains { $0.surface == "Bob Chen" && $0.kind == "person" })
    }

    func testExtractsOrgFromNoteShapedText() {
        let mentions = EntityExtractor.mentions(chunks: [chunk("Following up with Acme Corp on pricing.")], attendees: [])
        XCTAssertTrue(mentions.contains { $0.surface == "Acme Corp" && $0.kind == "org" })
    }

    func testAttendeesStillSeedAlongsideChunkMentions() {
        let mentions = EntityExtractor.mentions(chunks: [chunk("Quick note to self.")], attendees: ["Dana Whitfield"])
        XCTAssertTrue(mentions.contains { $0.surface == "Dana Whitfield" && $0.kind == "person" && $0.startMs == 0 })
    }

    func testJunkGateStillDropsLowercaseSingleTokens() {
        // A single-word, all-lowercase span is the ASR-noise shape the junk gate exists to drop
        // (EntityExtractor.swift's own comment) — still holds for note-shaped input, not just ASR.
        let mentions = EntityExtractor.mentions(chunks: [chunk("just some lowercase words here")], attendees: [])
        XCTAssertTrue(mentions.isEmpty)
    }

    func testEmptyNoteProducesNoMentions() {
        XCTAssertTrue(EntityExtractor.mentions(chunks: [], attendees: []).isEmpty)
    }
}
