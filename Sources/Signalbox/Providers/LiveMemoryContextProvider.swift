import Darwin
import Foundation

struct LiveMemoryContextProvider: MemoryContextProvider {
    func collectMemory(at date: Date) async -> ProviderResult<MemoryStatistics> {
        var pageSize: vm_size_t = 0
        let host = mach_host_self()
        let pageResult = host_page_size(host, &pageSize)
        guard pageResult == KERN_SUCCESS else {
            return .unavailable(reason: "macOS did not provide the virtual-memory page size (kernel result \(pageResult)).")
        }

        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let statisticsResult = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }

        guard statisticsResult == KERN_SUCCESS else {
            return .unavailable(reason: "macOS did not provide virtual-memory statistics (kernel result \(statisticsResult)).")
        }

        let pageBytes = UInt64(pageSize)
        return .available(MemoryStatistics(
            physicalBytes: ProcessInfo.processInfo.physicalMemory,
            activeBytes: multiplied(UInt64(statistics.active_count), by: pageBytes),
            inactiveBytes: multiplied(UInt64(statistics.inactive_count), by: pageBytes),
            wiredBytes: multiplied(UInt64(statistics.wire_count), by: pageBytes),
            compressedBytes: multiplied(UInt64(statistics.compressor_page_count), by: pageBytes),
            freeBytes: multiplied(UInt64(statistics.free_count), by: pageBytes),
            pageSize: pageBytes
        ))
    }

    private func multiplied(_ lhs: UInt64, by rhs: UInt64) -> UInt64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }
}
