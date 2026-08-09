import Foundation

struct LiveDiskHealthProvider: DiskHealthProvider {
    init() {}

    func collectVolumes(at date: Date) async -> ProviderResult<[VolumeCapacity]> {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsLocalKey,
            .volumeIsInternalKey
        ]

        guard let mountedURLs = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) else {
            return .unavailable(reason: "macOS did not return a mounted-volume list.")
        }

        var volumes: [VolumeCapacity] = []
        do {
            for url in mountedURLs {
                let values = try url.resourceValues(forKeys: keys)
                guard values.volumeIsLocal == true,
                      let total = values.volumeTotalCapacity else {
                    continue
                }

                guard let basicAvailable = values.volumeAvailableCapacity else {
                    continue
                }
                let available = Int64(basicAvailable)

                let mountPath = url.standardizedFileURL.path
                volumes.append(VolumeCapacity(
                    id: mountPath,
                    name: values.volumeName ?? url.lastPathComponent.ifEmpty("Macintosh HD"),
                    mountPath: mountPath,
                    totalBytes: Int64(total),
                    availableBytes: max(0, available),
                    isLocal: true,
                    isInternal: values.volumeIsInternal ?? false
                ))
            }
        } catch {
            return .unavailable(reason: ProviderFailureReason.readFailure(error, source: "mounted-volume capacity information"))
        }

        return .available(volumes.sorted { $0.mountPath.localizedStandardCompare($1.mountPath) == .orderedAscending })
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
