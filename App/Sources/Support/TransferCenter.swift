import Foundation
import Observation

/// Uploads and downloads started in this app session, for the transfer list on the home screen.
/// In memory only; DSMKit transfers report no byte progress, so a task is running, done or failed.
@MainActor
@Observable
final class TransferCenter {
    static let shared = TransferCenter()

    enum Direction { case upload, download }

    enum State: Equatable {
        case running
        case done
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let name: String
        let direction: Direction
        let deviceID: UUID?
        let started = Date()
        var finished: Date?
        var state: State = .running
    }

    private(set) var items: [Item] = []

    private init() {}

    func items(for device: UUID?) -> [Item] { items.filter { $0.deviceID == device } }

    func running(_ direction: Direction, device: UUID?) -> Int {
        items.filter { $0.deviceID == device && $0.direction == direction && $0.state == .running }.count
    }

    func begin(_ name: String, _ direction: Direction, device: UUID?) -> UUID {
        let item = Item(name: name, direction: direction, deviceID: device)
        items.insert(item, at: 0)
        return item.id
    }

    func finish(_ id: UUID, error: Error? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].finished = Date()
        items[i].state = error.map { State.failed($0.userMessage) } ?? .done
    }

    func clearFinished(device: UUID?) {
        items.removeAll { $0.deviceID == device && $0.state != .running }
    }
}
