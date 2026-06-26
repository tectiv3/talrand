import Foundation

/// Writes the deck backup snapshot to the app's iCloud Drive container so it's
/// backed up automatically and visible in Files. Best-effort: when iCloud Drive
/// is unavailable (no account, or the entitlement/container isn't provisioned
/// yet) the container URL is nil and the write is silently skipped.
enum ICloudBackup {
    static let containerIdentifier = "iCloud.com.talrand.app"
    private static let filename = "talrand-backup.json"

    /// Resolve the container's `Documents` directory. This call is slow/blocking,
    /// so it must run off the main thread. Returns nil when iCloud is unavailable.
    private static func documentsURL() -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            return nil
        }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }

    /// Overwrite the single rolling snapshot. Call from a background context.
    static func write(_ data: Data) {
        guard let url = documentsURL()?.appendingPathComponent(filename) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
