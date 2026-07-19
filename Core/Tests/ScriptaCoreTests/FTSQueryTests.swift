import XCTest
@testable import ScriptaCore
@testable import ScriptaShared

/// Covers the FTS5 query builder — the deterministic term extraction + escaping that feeds every
/// search/Ask/MCP MATCH. A regression here silently breaks retrieval (audit L14).
final class FTSQueryTests: XCTestCase {

    // MARK: - terms

    func testTermsDropsStopwordsAndShortTokens() {
        XCTAssertEqual(FTSQuery.terms("the budget review"), ["budget", "review"])
        XCTAssertEqual(FTSQuery.terms("a"), [])                 // < 2 chars → dropped → empty
        XCTAssertEqual(FTSQuery.terms(""), [])
    }

    func testTermsSplitsOnNonAlphanumericAndDedupes() {
        XCTAssertEqual(FTSQuery.terms("budget, budget! review?"), ["budget", "review"])
        XCTAssertEqual(FTSQuery.terms("6\" pipe budget"), ["pipe", "budget"])   // quote/space are separators
    }

    func testTermsKeepsOriginalsWhenAllStopwords() {
        // "what about it" is all stopwords → keep them so the query still returns something.
        XCTAssertEqual(FTSQuery.terms("what about it"), ["what", "about", "it"])
    }

    func testTermsCapsToTenLongest() {
        let many = (1...20).map { "word\($0)longer\($0)" }.joined(separator: " ")
        XCTAssertEqual(FTSQuery.terms(many).count, 10)
    }

    // MARK: - andExpression / orExpression

    func testAndExpressionQuotesPrefixTermsWithExplicitAnd() {
        XCTAssertEqual(FTSQuery.andExpression("budget review"), "\"budget\"* AND \"review\"*")
        XCTAssertNil(FTSQuery.andExpression(""))
        XCTAssertEqual(FTSQuery.andExpression("budget"), "\"budget\"*")   // single term, no dangling AND
    }

    func testOrExpressionUsesExplicitOr() {
        XCTAssertEqual(FTSQuery.orExpression("budget review"), "\"budget\"* OR \"review\"*")
    }

    // MARK: - alias expansion + sanitize

    func testAliasExpansionWrapsGroupInParens() {
        let expr = FTSQuery.andExpression("tim", aliasGroups: [["tim", "timothy"]])
        XCTAssertEqual(expr, "(\"tim\"* OR \"timothy\"*)")
    }

    func testAliasMemberQuoteIsSanitizedNotInjected() {
        // A vocabulary alias containing a double-quote must not break out of the FTS5 phrase.
        let expr = FTSQuery.andExpression("tim", aliasGroups: [["tim", "a\"b"]]) ?? ""
        XCTAssertFalse(expr.contains("a\"b"), "raw quote leaked into the MATCH expression")
        XCTAssertTrue(expr.contains("\"a b\""), "quote should collapse to a space-separated phrase")
        XCTAssertEqual(expr.filter { $0 == "\"" }.count % 2, 0, "unbalanced quotes")
    }

    func testMultiWordAliasMemberIsAnExactPhrase() {
        let expr = FTSQuery.andExpression("tim", aliasGroups: [["tim", "tenants in the market"]]) ?? ""
        XCTAssertTrue(expr.contains("\"tenants in the market\""))
    }
}
