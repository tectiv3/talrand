import Foundation
import UIKit

struct ImageCacheService {
    private let fileManager = FileManager.default

    private static let cachedDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("CardImages")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    private func cacheDirectory() -> URL {
        Self.cachedDirectory
    }

    func cacheImage(from url: String, filename: String) async throws -> String {
        guard let imageURL = URL(string: url) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: imageURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let destination = cacheDirectory().appendingPathComponent(filename)
        try data.write(to: destination)
        return filename
    }

    func cachedImagePath(filename: String) -> String? {
        let path = cacheDirectory().appendingPathComponent(filename).path
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    func resolvedPath(_ storedPath: String) -> String? {
        let filename = (storedPath as NSString).lastPathComponent
        let resolved = cacheDirectory().appendingPathComponent(filename).path
        return fileManager.fileExists(atPath: resolved) ? resolved : nil
    }

    func deleteImage(filename: String) {
        let path = cacheDirectory().appendingPathComponent(filename)
        try? fileManager.removeItem(at: path)
    }

    func saveCustomImage(_ image: UIImage, for cardId: String) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let filename = "custom_\(cardId).jpg"
        let destination = cacheDirectory().appendingPathComponent(filename)
        do {
            try data.write(to: destination)
            return filename
        } catch {
            return nil
        }
    }

    func deleteCustomImage(for cardId: String) {
        let path = cacheDirectory().appendingPathComponent("custom_\(cardId).jpg")
        try? fileManager.removeItem(at: path)
    }
}
