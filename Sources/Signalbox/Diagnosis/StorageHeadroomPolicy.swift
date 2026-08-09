import Foundation

enum StorageHeadroomLevel: Int, Codable, Comparable, Sendable {
    case adequate
    case limited
    case low
    case criticallyLow

    static func < (lhs: StorageHeadroomLevel, rhs: StorageHeadroomLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A deliberately simple, auditable heuristic. Byte thresholds are primary;
/// percentage checks are capped so a very large volume is not called unhealthy
/// merely because a small percentage is free.
struct StorageHeadroomPolicy: Sendable {
    static let gibibyte: Int64 = 1_073_741_824

    let criticalAvailableBytes: Int64
    let lowAvailableBytes: Int64
    let limitedAvailableBytes: Int64
    let lowFraction: Double
    let limitedFraction: Double
    let percentageCheckCapBytes: Int64

    init(
        criticalAvailableBytes: Int64 = 5 * gibibyte,
        lowAvailableBytes: Int64 = 15 * gibibyte,
        limitedAvailableBytes: Int64 = 30 * gibibyte,
        lowFraction: Double = 0.05,
        limitedFraction: Double = 0.10,
        percentageCheckCapBytes: Int64 = 50 * gibibyte
    ) {
        self.criticalAvailableBytes = criticalAvailableBytes
        self.lowAvailableBytes = lowAvailableBytes
        self.limitedAvailableBytes = limitedAvailableBytes
        self.lowFraction = lowFraction
        self.limitedFraction = limitedFraction
        self.percentageCheckCapBytes = percentageCheckCapBytes
    }

    func level(for volume: VolumeCapacity) -> StorageHeadroomLevel {
        let available = max(0, volume.availableBytes)

        if available <= criticalAvailableBytes {
            return .criticallyLow
        }
        if available <= lowAvailableBytes || fractionIsBelow(lowFraction, volume: volume) {
            return .low
        }
        if available <= limitedAvailableBytes || fractionIsBelow(limitedFraction, volume: volume) {
            return .limited
        }
        return .adequate
    }

    var thresholdSummary: String {
        "Storage headroom heuristic thresholds: critical at \(gibibytes(criticalAvailableBytes)) GiB, warning at \(gibibytes(lowAvailableBytes)) GiB, and notice at \(gibibytes(limitedAvailableBytes)) GiB available; capped percentage checks also apply."
    }

    private func fractionIsBelow(_ threshold: Double, volume: VolumeCapacity) -> Bool {
        guard volume.totalBytes > 0,
              volume.availableBytes <= percentageCheckCapBytes else {
            return false
        }
        return Double(max(0, volume.availableBytes)) / Double(volume.totalBytes) < threshold
    }

    private func gibibytes(_ bytes: Int64) -> String {
        let value = Double(bytes) / Double(Self.gibibyte)
        return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
