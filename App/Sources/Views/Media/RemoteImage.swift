import SwiftUI
import DSMKit

/// In-memory image cache shared by thumbnails, covers and posters. Keys include the session id,
/// so nothing outlives the login.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.totalCostLimit = 150 * 1024 * 1024
        return c
    }()

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func store(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

/// Loads an image through the DSM client (so trusted self-signed certificates work), unlike AsyncImage.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    let contentMode: ContentMode
    let placeholder: () -> Placeholder
    /// Custom loader for servers other than the NAS (e.g. Immich needs its API key header).
    let fetcher: (@Sendable (URL) async throws -> Data)?

    @Environment(SessionManager.self) private var session
    @State private var image: UIImage?

    init(url: URL?, contentMode: ContentMode = .fill, fetcher: (@Sendable (URL) async throws -> Data)? = nil,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.contentMode = contentMode
        self.fetcher = fetcher
        self.placeholder = placeholder
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        let data: Data?
        if let fetcher {
            data = try? await fetcher(url)
        } else {
            data = try? await session.client?.fetch(url)
        }
        guard let data else { return }
        // Decode off the main thread; large HEIC thumbnails are slow to decode.
        let decoded = await Task.detached(priority: .userInitiated) { UIImage(data: data)?.preparingForDisplay() }.value
        guard let decoded, !Task.isCancelled else { return }
        ImageCache.shared.store(decoded, for: url)
        image = decoded
    }
}

extension RemoteImage where Placeholder == Color {
    init(url: URL?, contentMode: ContentMode = .fill, fetcher: (@Sendable (URL) async throws -> Data)? = nil) {
        self.init(url: url, contentMode: contentMode, fetcher: fetcher) { Theme.subtle }
    }
}
