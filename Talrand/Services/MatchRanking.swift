import Foundation

/// Picks the closest reference and the closest *different* runner-up from a set
/// of (id, distance) scores.
///
/// Extracted from the live feature-print matcher (`CardImageMatcher`) so the
/// best/runner-up selection — which the strong-match gap guard
/// (`runnerUpDistance - bestDistance > gap`) depends on — can be unit-tested
/// without Vision or any image. The hand-rolled single-pass selection is fast
/// but easy to get subtly wrong, so it gets a pinning test.
enum MatchRanking {
    struct Ranked: Equatable {
        let bestId: String
        let bestDistance: Float
        let runnerUpDistance: Float
        let runnerUpId: String?
    }

    static func rank(_ scored: [(id: String, distance: Float)]) -> Ranked? {
        var bestId: String?
        var bestDist: Float = .greatestFiniteMagnitude
        var runnerUpDist: Float = .greatestFiniteMagnitude
        var runnerUpId: String?

        for s in scored {
            let d = s.distance
            if d < bestDist {
                // Demote the old best to runner-up — but only if it's a
                // different card. Multiple printings of one card must not mask
                // the margin to the true second-best.
                if s.id != bestId {
                    runnerUpDist = bestDist
                    runnerUpId = bestId
                }
                bestDist = d
                bestId = s.id
            } else if d < runnerUpDist, s.id != bestId {
                runnerUpDist = d
                runnerUpId = s.id
            }
        }

        guard let id = bestId else { return nil }
        return Ranked(bestId: id, bestDistance: bestDist, runnerUpDistance: runnerUpDist, runnerUpId: runnerUpId)
    }
}
