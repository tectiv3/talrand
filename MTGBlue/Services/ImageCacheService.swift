import Foundation

struct ImageCacheService {
    private let fileManager = FileManager.default

    private func cacheDirectory() -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("CardImages")
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
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
        return destination.path
    }

    func cachedImagePath(filename: String) -> String? {
        let path = cacheDirectory().appendingPathComponent(filename).path
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    func deleteImage(filename: String) {
        let path = cacheDirectory().appendingPathComponent(filename)
        try? fileManager.removeItem(at: path)
    }
}
