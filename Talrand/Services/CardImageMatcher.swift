import UIKit
import Vision

struct CardReferenceData {
    let scryfallId: String
    let name: String
    let localFrontImagePath: String?
}

struct MatchResult {
    let scryfallId: String
    let distance: Float
    let runnerUpDistance: Float
    let isStrong: Bool
}

class CardImageMatcher {
    private var references: [(scryfallId: String, featurePrint: VNFeaturePrintObservation)] = []
    private(set) var isReady = false
    private let imageCache = ImageCacheService()
    // Measured on-device: a correct match is BOTH close and clearly ahead of the
    // runner-up. A wrong card (different printing → nearest is some other blue
    // instant) lands ~0.85 with a thin gap (~0.05). Keeping the gap wide is what
    // separates a real borderline match (An Offer, gap ~0.11) from a false one
    // (Counterspell→Negate, gap ~0.05). Cards that can't clear this fall back to
    // the collector-code path rather than risk a wrong auto-match.
    private let strongThreshold: Float = 0.80
    private let nearThreshold: Float = 1.1
    private let minRunnerUpGap: Float = 0.07

    func loadReferences(_ cards: [CardReferenceData]) {
        var prints: [(scryfallId: String, featurePrint: VNFeaturePrintObservation)] = []
        prints.reserveCapacity(cards.count)

        for card in cards {
            guard let storedPath = card.localFrontImagePath,
                  let resolvedPath = imageCache.resolvedPath(storedPath),
                  let image = UIImage(contentsOfFile: resolvedPath)?.cgImage,
                  let art = cropToArt(image) else {
                continue
            }

            if let fp = generateFeaturePrint(from: art) {
                prints.append((scryfallId: card.scryfallId, featurePrint: fp))
            }
        }

        references = prints
        isReady = true
    }

    func findMatch(in image: CGImage) -> MatchResult? {
        guard isReady, !references.isEmpty else { return nil }
        guard let art = cropToArt(image) else { return nil }
        guard let queryPrint = generateFeaturePrint(from: art) else { return nil }

        var bestId: String?
        var bestDist: Float = .greatestFiniteMagnitude
        var runnerUpDist: Float = .greatestFiniteMagnitude

        for ref in references {
            var d: Float = 0
            do {
                try ref.featurePrint.computeDistance(&d, to: queryPrint)
            } catch {
                continue
            }
            if d < bestDist {
                // Only count a *different* card as the runner-up; multiple
                // printings of the same card would otherwise mask the margin.
                if ref.scryfallId != bestId {
                    runnerUpDist = bestDist
                }
                bestDist = d
                bestId = ref.scryfallId
            } else if d < runnerUpDist, ref.scryfallId != bestId {
                runnerUpDist = d
            }
        }

        guard let id = bestId, bestDist < nearThreshold else { return nil }
        let strong = bestDist < strongThreshold && (runnerUpDist - bestDist) > minRunnerUpGap
        return MatchResult(scryfallId: id, distance: bestDist, runnerUpDistance: runnerUpDist, isStrong: strong)
    }

    // MARK: - Private

    /// MTG card art occupies roughly 8–48% from the top of a standard frame.
    private func cropToArt(_ image: CGImage) -> CGImage? {
        let h = image.height
        let top = Int(Double(h) * 0.08)
        let artHeight = Int(Double(h) * 0.40)
        let rect = CGRect(x: 0, y: top, width: image.width, height: artHeight)
        return image.cropping(to: rect)
    }

    private func generateFeaturePrint(from cgImage: CGImage) -> VNFeaturePrintObservation? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNGenerateImageFeaturePrintRequest()
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }
}
