import XCTest

/// Pins the feature-print best/runner-up selection extracted from
/// `CardImageMatcher`. The strong-match gap guard relies on `runnerUpDistance`
/// being the closest *different* card, so the single-pass logic is tested here
/// without needing Vision or any image.
final class MatchRankingTests: XCTestCase {

    func testPicksClosestAndSecondClosest() {
        let r = MatchRanking.rank([("a", 0.5), ("b", 0.6), ("c", 0.3)])
        XCTAssertEqual(r?.bestId, "c")
        XCTAssertEqual(r?.runnerUpId, "a")
        XCTAssertEqual(r?.runnerUpDistance, 0.5)
    }

    /// 'a' appears twice (two printings). The runner-up must be the closest
    /// *different* card 'b', not a's own second printing — otherwise the margin
    /// guard would see a near-zero gap and reject a real strong match.
    func testRunnerUpIgnoresSameCardPrintings() {
        let r = MatchRanking.rank([("a", 0.30), ("a", 0.31), ("b", 0.40)])
        XCTAssertEqual(r?.bestId, "a")
        XCTAssertEqual(r?.runnerUpId, "b")
        XCTAssertEqual(r?.runnerUpDistance, 0.40)
    }

    /// A new best arriving last must demote the old best to runner-up even when a
    /// looser runner was already recorded (old best 0.5 is tighter than b 0.52).
    func testNewBestDemotesOldBest() {
        let r = MatchRanking.rank([("a", 0.5), ("b", 0.52), ("c", 0.3)])
        XCTAssertEqual(r?.bestId, "c")
        XCTAssertEqual(r?.runnerUpId, "a")
        XCTAssertEqual(r?.runnerUpDistance, 0.5)
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(MatchRanking.rank([]))
    }

    func testSingleHasNoRunnerUp() {
        let r = MatchRanking.rank([("a", 0.2)])
        XCTAssertEqual(r?.bestId, "a")
        XCTAssertNil(r?.runnerUpId)
        XCTAssertEqual(r?.runnerUpDistance, .greatestFiniteMagnitude)
    }
}
