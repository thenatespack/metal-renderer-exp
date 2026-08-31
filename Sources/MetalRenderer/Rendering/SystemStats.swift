import Darwin

/// Process-level CPU/memory sampling for the H debug overlay — plain Darwin
/// syscalls, no private APIs. GPU usage isn't here: there's no public API
/// for system-wide GPU utilization, so Renderer measures its own GPU time
/// directly instead, via MTLCommandBuffer's gpuStartTime/gpuEndTime.
enum SystemStats {
    /// Cumulative user+sys CPU seconds this process has consumed so far.
    /// Compare two samples a known wall-clock interval apart (see Renderer's
    /// once-a-second logBenchmark window) to get a CPU% for that window —
    /// can exceed 100% across multiple cores, same as Activity Monitor.
    static func cpuTimeSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + sys
    }

    /// Physical memory footprint in bytes — matches what Activity Monitor
    /// shows in its Memory column more closely than resident_size does.
    static func memoryFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }
}
