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
    // Measured on-device: correct matches land ~0.6–0.85, wrong cards / empty
    // table cluster ~0.9–1.0 with the runner-up nearly tied.
    private let strongThreshold: Float = 0.86
    private let nearThreshold: Float = 1.1
    // The nearest neighbour must also clearly beat the runner-up. A ratio test
    // demanded too wide a margin for cards with similar (dark blue) art; an
    // absolute gap accepts those while the table still clusters with ~0 gap.
    private let minRunnerUpGap: Float = 0.05

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
