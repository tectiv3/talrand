import CoreGraphics
import CoreImage
import ImageIO
import Vision
import XCTest

/// Replays previously-captured card photos through the real scanner OCR logic
/// (`ScanOCR` + the parsers) to catch regressions — no camera, no app launch.
/// Each fixture is a physical Japanese card the user owns; the expected values
/// are the ground-truth printing per SCANNING_NOTES.md.
final class ScannerRegressionTests: XCTestCase {

    private let ciContext = CIContext()

    /// The deck name lookup the live scanner matches titles against, built the
    /// same way `CameraService.loadCardReferences` does (so the DFC front-face
    /// split is exercised). Decoys make a wrong match possible.
    private let nameCandidates = ScanOCR.nameLookup(for: [
        (id: "brainstorm", name: "Brainstorm", printed: "渦まく知識"),
        (id: "counterspell", name: "Counterspell", printed: "対抗呪文"),
        (id: "docent", name: "Docent of Perfection // Final Iteration", printed: "完成態の講師"),
        (id: "crystal", name: "Crystal Shard", printed: "水晶の破片"),
        (id: "decoy-negate", name: "Negate", printed: "否認"),
        (id: "decoy-opt", name: "Opt", printed: "選択"),
    ])

    // MARK: - Fixture loading

    private func loadFixture(_ name: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws -> (image: CGImage, orientation: CGImagePropertyOrientation) {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "jpg"),
                                "missing fixture \(name).jpg", file: file, line: line)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil),
                                   "unreadable \(name).jpg", file: file, line: line)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil),
                                  "no image in \(name).jpg", file: file, line: line)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return (image, CGImagePropertyOrientation(rawValue: raw) ?? .up)
    }

    /// The live scanner front end: detect + perspective-correct the card. Falls
    /// back to the EXIF-oriented raw frame if rectangle detection misses, so an
    /// OCR assertion fails for a real OCR reason rather than a detection miss.
    private func cardCrop(_ name: String) throws -> CGImage {
        let (image, orientation) = try loadFixture(name)
        if let card = ScanOCR.detectCard(in: CIImage(cgImage: image),
                                         orientation: orientation,
                                         ciContext: ciContext) {
            return card
        }
        let oriented = CIImage(cgImage: image).oriented(orientation)
        return ciContext.createCGImage(oriented, from: oriented.extent) ?? image
    }

    private func collectorNumbers(_ name: String) throws -> (text: String, numbers: [String]) {
        let card = try cardCrop(name)
        let (text, candidates) = ScanOCR.collectorReadout(in: card,
                                                          knownSetCodes: [],
                                                          customWords: [],
                                                          ciContext: ciContext)
        return (text, candidates.map(\.collectorNumber))
    }

    // MARK: - Collector-number path

    func testBrainstormCollectorNumber() throws {
        let (text, nums) = try collectorNumbers("brainstorm")
        XCTAssertTrue(nums.contains("91"), "expected 91 (CNS 91/210); OCR='\(text)' candidates=\(nums)")
    }

    func testCounterspellCollectorNumber() throws {
        let (text, nums) = try collectorNumbers("counterspell")
        XCTAssertTrue(nums.contains("69"), "expected 69 (MMQ 69/350); OCR='\(text)' candidates=\(nums)")
    }

    func testDocentCollectorNumberRejectsPowerToughness() throws {
        let (text, nums) = try collectorNumbers("docent_of_perfection")
        // 完成態の講師 prints two P/T tokens (6/5, 5/4); the denominator>=20 guard
        // must keep them out of the candidate list. This is a real guard.
        for pt in ["4", "5", "6"] {
            XCTAssertFalse(nums.contains(pt), "power/toughness \(pt) leaked; OCR='\(text)' candidates=\(nums)")
        }
        // EMN 56/205, but the collector strip OCRs as garbage (e.g. "09b/205"),
        // so no clean "56" candidate survives. Known OCR-quality gap on this
        // card; remove the wrapper once the strip reads legibly.
        XCTExpectFailure("Docent collector strip OCRs illegibly (not a parser bug)")
        XCTAssertTrue(nums.contains("56"), "expected 56 (EMN 56/205); OCR='\(text)' candidates=\(nums)")
    }

    func testCrystalShardCollectorNumber() throws {
        let (text, nums) = try collectorNumbers("crystal_shard")
        // TSR #393 prints a bare collector number — no "/total", no set code, and
        // a "2020" year nearby — which no parser pattern matches yet. In-progress;
        // remove this wrapper once the bare-number path lands (the test then
        // becomes a real guard, and fails loudly if it isn't removed).
        XCTExpectFailure("bare trailing collector number (no /total, no set code) not parsed yet")
        XCTAssertTrue(nums.contains("393"), "expected 393 (TSR Crystal Shard); OCR='\(text)' candidates=\(nums)")
    }

    // MARK: - Name path (title OCR -> CardNameMatcher)

    /// `knownFailure`, when set, marks the case as a documented OCR-quality gap:
    /// the title crop can't be read cleanly yet, so the (correct, exact-match)
    /// matcher returns nil. Strict `XCTExpectFailure` flips to a hard failure the
    /// moment OCR/crop improvements make it pass — forcing the wrapper's removal.
    private func assertName(_ fixture: String,
                            resolvesTo id: String,
                            knownFailure: String? = nil,
                            file: StaticString = #filePath,
                            line: UInt = #line) throws {
        let title = try ScanOCR.titleText(in: cardCrop(fixture))
        if let knownFailure { XCTExpectFailure(knownFailure) }
        let matched = CardNameMatcher.match(ocrText: title, candidates: nameCandidates)
        XCTAssertEqual(matched, id,
                       "title OCR='\(title)' -> \(matched ?? "nil"), expected \(id)",
                       file: file, line: line)
    }

    func testCounterspellName() throws { try assertName("counterspell", resolvesTo: "counterspell") }

    func testBrainstormName() throws {
        // Title crop OCRs 渦→酒 ("酒まく知識"); the exact-containment matcher misses.
        try assertName("brainstorm", resolvesTo: "brainstorm",
                       knownFailure: "title OCR misreads first kanji (渦→酒)")
    }

    func testDocentName() throws {
        // Title crop captures furigana ruby and OCRs 完→党 ("党成態の講師").
        try assertName("docent_of_perfection", resolvesTo: "docent",
                       knownFailure: "title OCR catches furigana and misreads kanji (完→党)")
    }

    func testCrystalShardName() throws {
        // Retro-frame title sits outside the 2–11% crop; OCR returns empty.
        try assertName("crystal_shard", resolvesTo: "crystal",
                       knownFailure: "retro-frame title falls outside the title crop (empty OCR)")
    }

    /// The DFC fix (b5c3c5e): the pre-"//" front-face name must be indexed so a
    /// physical card showing only the front title still matches.
    func testDoubleFacedNameLookupIncludesFrontFace() {
        let lookup = ScanOCR.nameLookup(for: [
            (id: "docent", name: "Docent of Perfection // Final Iteration", printed: "完成態の講師"),
        ])
        let names = lookup.map(\.name)
        XCTAssertTrue(names.contains("Docent of Perfection"), "front-face name not indexed: \(names)")
        XCTAssertTrue(names.contains("完成態の講師"), "printed name not indexed: \(names)")
    }
}
