import Foundation
import Darwin

/// Whether the process an approval was tied to is still the same running process.
///
/// yyt 2026-09-14: "always" was the only way to stop being asked again for the same agent doing
/// the same job, and "always" means forever. "While it runs" needs a process identity that a
/// reused pid cannot inherit: pid plus the kernel's start time for it.
public enum ProcessLiveness {
    /// The kernel's start time for `pid`, or nil when there is no such process.
    public static func startTime(pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard got == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// True while the process that started at `startedAt` is still running under `pid`.
    public static func isAlive(pid: Int32, startedAt: Date) -> Bool {
        guard let start = startTime(pid: pid) else { return false }
        return abs(start.timeIntervalSince(startedAt)) < 1
    }
}
