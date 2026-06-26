import Foundation

/// Versioned, Foundation-only snapshot of a deck and its referenced cards.
///
/// Deliberately holds only identity fields (printing identity, board, scanned
/// timestamps); everything re-derivable from Scryfall is left out so the
/// document stays tiny and resistant to schema drift. The `version` field gates
/// the decoder so an old export can restore into a newer schema.
struct BackupV1: Codable, Equatable {
    var version: Int
    var exportedAt: Date
    var deck: DeckSnapshot
    var cards: [CardSnapshot]

    struct DeckSnapshot: Codable, Equatable {
        var id: String
        var name: String
        var format: String
        var commanderScryfallId: String?
        var entries: [EntrySnapshot]
    }

    struct EntrySnapshot: Codable, Equatable {
        var scryfallId: String
        var quantity: Int
        var board: String
    }

    struct CardSnapshot: Codable, Equatable {
        var scryfallId: String
        var oracleId: String
        var name: String
        var setCode: String
        var collectorNumber: String
        var typeLine: String
        var printedName: String
        var lastScannedAt: Date?
    }
}

enum BackupCodecError: Error, Equatable {
    case unsupportedVersion(Int)
}

enum BackupCodec {
    static func encode(_ backup: BackupV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Human-readable and diff-stable: prettyPrinted for review, sortedKeys so
        // the same snapshot always serializes byte-for-byte identically.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> BackupV1 {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(BackupV1.self, from: data)
        guard backup.version == 1 else {
            throw BackupCodecError.unsupportedVersion(backup.version)
        }
        return backup
    }
}
