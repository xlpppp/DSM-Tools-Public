import Foundation
import Observation
import DSMKit

/// Files and photos the user opened recently, per NAS, shown on the home screen.
/// Kept on the phone only (UserDefaults); nothing here is sent anywhere.
@MainActor
@Observable
final class RecentStore {
    static let shared = RecentStore()

    struct RecentFile: Codable, Hashable, Identifiable {
        let path: String
        let name: String
        let size: Int64?
        let viewedAt: Date

        var id: String { path }
        var remote: RemoteFile { RemoteFile(path: path, name: name, isDirectory: false, size: size) }
    }

    struct RecentPhoto: Codable, Hashable, Identifiable {
        let photoID: Int
        let filename: String
        let isVideo: Bool
        let cacheKey: String?
        let space: String
        let viewedAt: Date

        var id: String { "\(space)-\(photoID)" }
        var photoSpace: PhotoSpace { PhotoSpace(rawValue: space) ?? .personal }
        var item: PhotoItem { PhotoItem(id: photoID, filename: filename, isVideo: isVideo, cacheKey: cacheKey) }
    }

    private struct Snapshot: Codable {
        var files: [String: [RecentFile]] = [:]
        var photos: [String: [RecentPhoto]] = [:]
    }

    private static let key = "recents.v1"
    private static let limit = 50

    private var snapshot: Snapshot

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = saved
        } else {
            snapshot = Snapshot()
        }
    }

    func files(for device: UUID?) -> [RecentFile] {
        device.flatMap { snapshot.files[$0.uuidString] } ?? []
    }

    func photos(for device: UUID?) -> [RecentPhoto] {
        device.flatMap { snapshot.photos[$0.uuidString] } ?? []
    }

    func record(_ file: RemoteFile, device: UUID?) {
        guard let device, !file.isDirectory else { return }
        var list = files(for: device).filter { $0.path != file.path }
        list.insert(RecentFile(path: file.path, name: file.name, size: file.size, viewedAt: Date()), at: 0)
        snapshot.files[device.uuidString] = Array(list.prefix(Self.limit))
        persist()
    }

    func record(_ photo: PhotoItem, space: PhotoSpace, device: UUID?) {
        guard let device else { return }
        let entry = RecentPhoto(photoID: photo.id, filename: photo.filename, isVideo: photo.isVideo,
                                cacheKey: photo.cacheKey, space: space.rawValue, viewedAt: Date())
        var list = photos(for: device).filter { $0.id != entry.id }
        list.insert(entry, at: 0)
        snapshot.photos[device.uuidString] = Array(list.prefix(Self.limit))
        persist()
    }

    func removeFiles(_ paths: Set<String>, device: UUID?) {
        guard let device else { return }
        snapshot.files[device.uuidString] = files(for: device).filter { !paths.contains($0.path) }
        persist()
    }

    func removePhotos(_ ids: Set<String>, device: UUID?) {
        guard let device else { return }
        snapshot.photos[device.uuidString] = photos(for: device).filter { !ids.contains($0.id) }
        persist()
    }

    /// Called when a device is deleted.
    func forget(_ device: UUID) {
        snapshot.files[device.uuidString] = nil
        snapshot.photos[device.uuidString] = nil
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
