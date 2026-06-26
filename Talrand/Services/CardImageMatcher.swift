import UIKit
import Vision

class CardImageMatcher {
    private var references: [(scryfallId: String, featurePrint: VNFeaturePrintObservation)] = []
    private(set) var isReady = false
    private let imageCache = ImageCacheService()
    private let strongThreshold: Float = 18.0
    private let nearThreshold: Float = 25.0

    func loadReferences(_ cards: [Card]) {
        var prints: [(scryfallId: String, featurePrint: VNFeaturePrintObservation)] = []
        prints.reserveCapacity(cards.count)

        for card in cards {
            guard let storedPath = card.localFrontImagePath,
                  let resolvedPath = imageCache.resolvedPath(storedPath),
                  let image = UIImage(contentsOfFile: resolvedPath)?.cgImage else {
                continue
            }

            if let fp = generateFeaturePrint(from: image) {
                prints.append((scryfallId: card.scryfallId, featurePrint: fp))
            }
        }

        references = prints
        isReady = true
    }

    func findBestMatch(in pixelBuffer: CVPixelBuffer) -> (scryfallId: String, distance: Float)? {
        guard isReady, !references.isEmpty else { return nil }
        guard let queryPrint = generateFeaturePrint(from: pixelBuffer) else { return nil }
        return closestMatch(to: queryPrint, threshold: strongThreshold)
    }

    func findNearMatch(in pixelBuffer: CVPixelBuffer) -> (scryfallId: String, distance: Float)? {
        guard isReady, !references.isEmpty else { return nil }
        guard let queryPrint = generateFeaturePrint(from: pixelBuffer) else { return nil }
        return closestMatch(to: queryPrint, threshold: nearThreshold)
    }

    // MARK: - Private

    private func closestMatch(
        to query: VNFeaturePrintObservation,
        threshold: Float
    ) -> (scryfallId: String, distance: Float)? {
        var bestId: String?
        var bestDist: Float = .greatestFiniteMagnitude

        for ref in references {
            var d: Float = 0
            do {
                try ref.featurePrint.computeDistance(&d, to: query)
            } catch {
                continue
            }
            if d < bestDist {
                bestDist = d
                bestId = ref.scryfallId
            }
        }

        guard let id = bestId, bestDist < threshold else { return nil }
        return (scryfallId: id, distance: bestDist)
    }

    private func generateFeaturePrint(from cgImage: CGImage) -> VNFeaturePrintObservation? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNGenerateImageFeaturePrintRequest()
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }

    private func generateFeaturePrint(from pixelBuffer: CVPixelBuffer) -> VNFeaturePrintObservation? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        let request = VNGenerateImageFeaturePrintRequest()
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }
}
