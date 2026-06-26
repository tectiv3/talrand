import XCTest

/// Pins the pure backup codec: a round-trip must preserve the snapshot exactly,
/// and the `version` gate must reject anything that isn't v1 (so an old or
/// future export can't be silently mis-decoded).
final class BackupCodecTests: XCTestCase {

    private func makeSnapshot() -> BackupV1 {
        BackupV1(
            version: 1,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deck: BackupV1.DeckSnapshot(
                id: "deck-1",
                name: "Talrand, Sky Summoner",
                format: "commander",
                commanderScryfallId: "commander-scryfall-id",
                entries: [
                    BackupV1.EntrySnapshot(scryfallId: "card-a", quantity: 1, board: "mainboard"),
                    BackupV1.EntrySnapshot(scryfallId: "card-b", quantity: 2, board: "sideboard"),
                ]
            ),
            cards: [
                BackupV1.CardSnapshot(
                    scryfallId: "card-a",
                    oracleId: "oracle-a",
                    name: "Talrand, Sky Summoner",
                    setCode: "m13",
                    collectorNumber: "62",
                    typeLine: "Legendary Creature — Merfolk Wizard",
                    printedName: "ターランド、空召喚士",
                    lastScannedAt: Date(timeIntervalSince1970: 1_699_000_000)
                ),
                BackupV1.CardSnapshot(
                    scryfallId: "card-b",
                    oracleId: "oracle-b",
                    name: "Counterspell",
                    setCode: "mh2",
                    collectorNumber: "267",
                    typeLine: "Instant",
                    printedName: "対抗呪文",
                    lastScannedAt: nil
                ),
            ]
        )
    }

    func testRoundTripPreservesSnapshot() throws {
        let original = makeSnapshot()
        let data = try BackupCodec.encode(original)
        let decoded = try BackupCodec.decode(data)
        XCTAssertEqual(decoded, original)
    }

    func testRejectsUnsupportedVersion() throws {
        let data = try BackupCodec.encode(makeSnapshot())
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        json["version"] = 2
        let mutated = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try BackupCodec.decode(mutated)) { error in
            XCTAssertEqual(error as? BackupCodecError, .unsupportedVersion(2))
        }
    }

    func testMalformedInputThrows() {
        XCTAssertThrowsError(try BackupCodec.decode(Data()))
        XCTAssertThrowsError(try BackupCodec.decode(Data("not json".utf8)))
    }
}
