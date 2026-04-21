import Foundation
import Darwin

/// Thin wrapper around Darwin's proc_pidinfo(PROC_PIDTASKALLINFO) for PID identity verification
/// and crash-free start-time lookup. Thread-safe (pure C call, no shared state).
public enum ProcPIDInfo {
    /// Result of a proc_pidinfo lookup.
    public struct Info: Sendable, Hashable {
        /// Unix seconds since 1970 when the process was started (from pbsd.pbi_start_tvsec).
        public let startTvSec: Int64
        /// Short process name (up to 16 chars, from pbsd.pbi_comm).
        public let comm: String
    }

    /// Fetch current start-time + comm for a PID. Returns nil if proc not found or lookup fails.
    public static func lookup(pid: Int32) -> Info? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.stride)
        let ret = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, ptr, size)
        }
        guard ret == size else { return nil }

        // pbi_comm is a char[16] C array. Extract by rebinding a pointer to the pbsd field
        // and advancing past pbi_start_tvsec / pbi_start_tvnsec to reach pbi_comm.
        // Safer: use the layout-stable tuple representation produced by Swift for C arrays.
        // We read pbi_comm as a tuple of 16 Int8 values and convert to String.
        let startTvSec = Int64(info.pbsd.pbi_start_tvsec)
        let comm = withUnsafeBytes(of: info.pbsd.pbi_comm) { rawBuf -> String in
            // rawBuf is a view of the char[16] field; find the null terminator.
            let bytes = rawBuf.bindMemory(to: CChar.self)
            if let termIdx = bytes.firstIndex(of: 0) {
                return String(bytes: rawBuf[..<termIdx], encoding: .utf8) ?? ""
            }
            return String(bytes: rawBuf, encoding: .utf8) ?? ""
        }
        return Info(startTvSec: startTvSec, comm: comm)
    }

    /// Check whether the live process at `pid` matches the expected (startTvSec, comm).
    /// Returns true when either: the lookup succeeds AND both fields match,
    /// or falls back to true if `expectedStart` is 0 (meaning: we never captured a start timestamp,
    /// so we can't verify — don't block the kill).
    public static func verifyIdentity(pid: Int32, expectedStart: Int64, expectedComm: String?) -> Bool {
        guard expectedStart > 0 else { return true }  // no baseline → don't block
        guard let info = lookup(pid: pid) else { return false }  // process gone → abort kill
        guard info.startTvSec == expectedStart else { return false }
        // Compare comm only if we have a baseline; comm may be truncated (16 chars)
        if let expectedComm, !expectedComm.isEmpty {
            let baseline = String(expectedComm.prefix(15))  // pbi_comm is 16 inc null
            if !info.comm.hasPrefix(baseline) && !baseline.hasPrefix(info.comm) {
                return false
            }
        }
        return true
    }
}
