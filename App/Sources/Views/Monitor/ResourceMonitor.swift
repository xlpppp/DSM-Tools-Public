import Foundation
import Observation
import DSMKit

/// Polls SYNO.Core.System.Utilization and keeps a short history for the charts.
/// The home card and the detail page share one instance, so the curves keep
/// their history when the page opens; whichever view started polling last owns the loop.
@MainActor
@Observable
final class ResourceMonitor {
    struct Sample: Identifiable {
        let date: Date
        let value: Utilization
        var id: Date { date }
    }

    /// 60 samples at 3 s = the last 3 minutes.
    static let capacity = 60

    private(set) var samples: [Sample] = []
    private(set) var lastError: String?

    @ObservationIgnored private var owner = UUID()
    @ObservationIgnored private var clientID: ObjectIdentifier?

    var latest: Utilization? { samples.last?.value }

    func run(_ client: DSMClient, interval: Duration = .seconds(3)) async {
        let me = UUID()
        owner = me
        if clientID != ObjectIdentifier(client) {
            clientID = ObjectIdentifier(client)
            samples = []
        }
        while !Task.isCancelled, owner == me {
            do {
                let value = try await client.utilization()
                guard owner == me else { return }
                samples.append(Sample(date: .now, value: value))
                if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
                lastError = nil
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled, owner == me { lastError = error.userMessage }
            }
            try? await Task.sleep(for: interval)
        }
    }

    func series(_ metric: (Utilization) -> Double) -> [ChartPoint] {
        samples.map { ChartPoint(date: $0.date, value: metric($0.value)) }
    }
}

struct ChartPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

extension Format {
    static func kilobytes(_ kb: Int) -> String { bytes(Int64(kb) * 1024) }

    static func load(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "—" }

    static func percent(_ value: Double) -> String {
        value < 10 && value != value.rounded() ? String(format: "%.1f", value) : String(Int(value.rounded()))
    }

    /// CPU seconds as "H:MM:SS" (hours keep growing past 24, as in DSM).
    static func cpuTime(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
