import SwiftData
import XCTest

/// Pins the collector-number index logic that the setup and pull-to-refresh
/// paths share (`CollectorIndex.replace`). The bug this guards against: refresh
/// re-runs the populate step, so it must not accumulate duplicate rows.
final class CollectorIndexTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: CollectorNumberEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func rows(_ ctx: ModelContext, cardName: String) throws -> [CollectorNumberEntry] {
        try ctx.fetch(FetchDescriptor<CollectorNumberEntry>(predicate: #Predicate { $0.cardName == cardName }))
    }

    func testReplaceInsertsEntries() throws {
        let ctx = try makeContext()
        CollectorIndex.replace(cardName: "Pongify", with: [
            CollectorNumberEntry(setCode: "soa", collectorNumber: "20", cardName: "Pongify"),
            CollectorNumberEntry(setCode: "plc", collectorNumber: "44", cardName: "Pongify"),
        ], in: ctx)
        XCTAssertEqual(try rows(ctx, cardName: "Pongify").count, 2)
    }

    func testReplaceIsIdempotent() throws {
        let ctx = try makeContext()
        func entries() -> [CollectorNumberEntry] {
            [CollectorNumberEntry(setCode: "soa", collectorNumber: "20", cardName: "Pongify")]
        }
        CollectorIndex.replace(cardName: "Pongify", with: entries(), in: ctx)
        CollectorIndex.replace(cardName: "Pongify", with: entries(), in: ctx)
        XCTAssertEqual(try rows(ctx, cardName: "Pongify").count, 1, "repeat refresh duplicated rows")
    }

    func testReplaceOnlyAffectsNamedCard() throws {
        let ctx = try makeContext()
        ctx.insert(CollectorNumberEntry(setCode: "mmq", collectorNumber: "69", cardName: "Counterspell"))
        CollectorIndex.replace(cardName: "Pongify", with: [
            CollectorNumberEntry(setCode: "soa", collectorNumber: "20", cardName: "Pongify"),
        ], in: ctx)
        XCTAssertEqual(try rows(ctx, cardName: "Counterspell").count, 1, "replacing Pongify wiped another card")
        XCTAssertEqual(try rows(ctx, cardName: "Pongify").count, 1)
    }
}
