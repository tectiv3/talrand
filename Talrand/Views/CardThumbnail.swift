import SwiftUI

struct CardThumbnail: View {
    let card: Card
    let size: CGSize
    var face: CardFace = .front

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.blue.opacity(0.3))
                    .overlay {
                        Image(systemName: "rectangle.portrait")
                            .foregroundStyle(.blue)
                    }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: pathForFace) {
            image = await loadImage()
        }
    }

    private var pathForFace: String? {
        switch face {
        case .front: card.localFrontImagePath
        case .back: card.localBackImagePath
        }
    }

    private func loadImage() async -> UIImage? {
        let storedPath: String?
        switch face {
        case .front: storedPath = card.localFrontImagePath
        case .back: storedPath = card.localBackImagePath
        }
        guard let storedPath, !storedPath.isEmpty else { return nil }
        return await Task.detached {
            let cache = ImageCacheService()
            guard let resolved = cache.resolvedPath(storedPath) else { return nil as UIImage? }
            return UIImage(contentsOfFile: resolved)
        }.value
    }
}
