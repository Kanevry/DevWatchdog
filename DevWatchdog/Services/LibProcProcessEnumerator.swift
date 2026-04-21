import Foundation
import Darwin

/// libproc-based equivalent of `PSParser.parseProcessList(excludedApps:inclusionPatterns:timeout:)`.
///
/// Wired in behind `WatchdogConfig.useLibprocEnumerator` (other agents handle the flag).
///
/// **G2 (cwd project detection):** When `useCwdProjectDetection` is true, each process's
/// working directory is resolved via `ProcPIDInfo.cwd(pid:)` and the nearest project root is
/// detected via `ProjectRootResolver.projectName(for:)`. Results populate `DevProcess.workingDirectory`
/// and `DevProcess.detectedProject`. Both fields remain nil when the flag is false (default).
///
/// **G1 (signal classifier):** When `useSignalClassifier` is true, `DevProcessClassifier` is
/// consulted before the wordlist inclusion filter. `.dev` → accept; `.notDev` → skip; `.unknown`
/// → fall through to the existing wordlist filter (backward compatibility).
/// When the flag is false (default), behaviour is identical to pre-G1 (wordlist only).
///
/// **PSParser path:** Both new flags are only consumed in the libproc branch.
/// When `useLibprocEnumerator=false`, these flags are passed but ignored by the PSParser path.
///
/// **Parity status:** MVP — exec-path OR 16-char comm (PSParser returns full argv);
/// cumulative CPU%; UID-filtered to current user.
///
/// **Known divergences from PSParser:**
/// - `command` is the full executable path from `proc_pidpath`, or the 16-char `pbi_comm`
///   as fallback. PSParser returns the full `args=` argv string (binary + all arguments).
///   Dev-tool pattern matching still works because the binary path always contains the
///   tool name, but argument-based patterns (e.g. `"--host-rules"`) will never match here.
/// - CPU% is cumulative since process start, not a recent 1s or 5s delta.
///   Delta-sampling is deferred to Wave 3.
/// - `startTime` is derived from `pbi_start_tvsec` (unix seconds) only — PSParser also
///   attempts to parse the human-readable `STARTED` column which is less precise anyway.
/// - `state` is derived from `pbi_status` integer constants; PSParser maps one-char `ps`
///   state letters. The mapping is equivalent for zombie/stopped/running.
///
/// Addresses: GitLab #34 (G5), #35 (G2), #36 (G1)
enum LibProcProcessEnumerator: Sendable {

    // MARK: - Public API

    /// Enumerate all current-user dev processes via libproc.
    /// Mirrors `PSParser.parseProcessList(excludedApps:inclusionPatterns:)` minus `timeout:`
    /// (libproc calls are synchronous C calls — no subprocess to time out).
    ///
    /// - Parameters:
    ///   - excludedApps: Path substrings whose presence in `command` causes the process to be skipped.
    ///   - inclusionPatterns: Wordlist filter applied when `useSignalClassifier` is false or the
    ///     classifier returns `.unknown`.
    ///   - useCwdProjectDetection: When true, resolves each process's cwd and nearest project root
    ///     (G2). Default false — no cwd lookup, `workingDirectory` and `detectedProject` are nil.
    ///   - useSignalClassifier: When true, consults `DevProcessClassifier` as a pre-filter before
    ///     the wordlist inclusion check (G1). Default false — wordlist-only behaviour preserved.
    static func parseProcessList(
        excludedApps: [String],
        inclusionPatterns: [String],
        useCwdProjectDetection: Bool = false,
        useSignalClassifier: Bool = false
    ) -> [DevProcess] {

        // --- One-time setup (cheap) ---
        let currentUID = getuid()
        let currentUserName = NSUserName()
        let totalPhysicalMemory = ProcessInfo.processInfo.physicalMemory  // UInt64 bytes

        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)

        // --- Step 1: Enumerate PIDs ---
        let pidCount = Self.enumeratePIDs()
        guard !pidCount.isEmpty else { return [] }

        // --- Step 2+: Per-PID processing ---
        var results: [DevProcess] = []
        results.reserveCapacity(min(pidCount.count, 256))

        for pid in pidCount {
            guard pid > 0 else { continue }

            // Step 5a: PROC_PIDTASKALLINFO lookup
            var info = proc_taskallinfo()
            let stride = Int32(MemoryLayout<proc_taskallinfo>.stride)
            let ret = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
                proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, ptr, stride)
            }
            guard ret == stride else { continue }  // process exited, EPERM, etc.

            // Step 5b: UID filter
            guard info.pbsd.pbi_uid == currentUID else { continue }

            // Step 5c: Build command string
            let command = Self.resolveCommand(pid: pid, pbsd: info.pbsd)

            // Step 5c-G2: cwd lookup (only when flag is enabled; pure C call, no actor hop needed)
            let cwd: String? = useCwdProjectDetection ? ProcPIDInfo.cwd(pid: pid) : nil

            // Step 5d: Inclusion / classifier filter
            // When useSignalClassifier is true, ask DevProcessClassifier first:
            //   .dev     → accept (skip wordlist)
            //   .notDev  → reject immediately
            //   .unknown → fall through to wordlist filter (backward-compat)
            // When useSignalClassifier is false, wordlist-only path is taken (identical to pre-G1).
            if useSignalClassifier {
                let classifierInput = DevProcessClassifier.Input(
                    executablePath: command,
                    workingDirectory: cwd,
                    parentProcessName: nil,   // not cheaply available in the per-PID loop
                    bundleIdentifier: nil     // out of scope for this wave
                )
                switch DevProcessClassifier.classify(classifierInput) {
                case .notDev:
                    continue
                case .dev:
                    break   // accepted — skip wordlist, continue to step 5e
                case .unknown:
                    // Fall through to wordlist filter below
                    let cmdLower = command.lowercased()
                    let isDevProcess = inclusionPatterns.contains { pattern in
                        cmdLower.contains(pattern.lowercased())
                    }
                    guard isDevProcess else { continue }
                }
            } else {
                // Wordlist-only (pre-G1 behaviour, unchanged)
                let cmdLower = command.lowercased()
                let isDevProcess = inclusionPatterns.contains { pattern in
                    cmdLower.contains(pattern.lowercased())
                }
                guard isDevProcess else { continue }
            }

            // Step 5e: Playwright exemption
            let isPlaywrightBrowser = command.contains("ms-playwright")

            // Step 5f: Excluded apps filter (unless Playwright browser)
            if !isPlaywrightBrowser {
                let isExcludedApp = excludedApps.contains { command.contains($0) }
                guard !isExcludedApp else { continue }
            }

            // Step 5g: /Applications/ heuristic
            if !isPlaywrightBrowser && command.contains("/Applications/") {
                let isDevApp = command.contains("Visual Studio Code") ||
                    command.contains("Cursor") ||
                    command.contains("iTerm") ||
                    command.contains("Terminal") ||
                    command.contains("Warp")
                guard isDevApp else { continue }
            }

            // Step 5h: CPU% — cumulative since process start
            let cpuMachTime = info.ptinfo.pti_total_user &+ info.ptinfo.pti_total_system
            let cpuNanos = Double(cpuMachTime)
                * Double(timebaseInfo.numer)
                / Double(timebaseInfo.denom)
            let startTvSec = Int64(info.pbsd.pbi_start_tvsec)
            let startDate = startTvSec > 0
                ? Date(timeIntervalSince1970: TimeInterval(startTvSec))
                : nil
            let elapsed: TimeInterval
            if let startDate {
                elapsed = Date().timeIntervalSince(startDate)
            } else {
                elapsed = 0
            }
            let cpuPercent: Double = elapsed > 0
                ? (cpuNanos / 1_000_000_000.0) / elapsed * 100.0
                : 0.0

            // Step 5h: Memory%
            let residentSize = info.ptinfo.pti_resident_size
            let memPercent: Double = totalPhysicalMemory > 0
                ? Double(residentSize) / Double(totalPhysicalMemory) * 100.0
                : 0.0

            // Step 5h: RSS in KB
            let rss = Int(residentSize / 1024)

            // Step 5h: parentPID + isOrphan
            let parentPID = Int32(bitPattern: info.pbsd.pbi_ppid)
            let isOrphan = parentPID == 1

            // Step 5h: ProcessState from pbi_status
            let state = Self.processState(from: info.pbsd.pbi_status)

            // Step 5h-G2: Resolve project root from cwd (only when flag is enabled and cwd is available)
            let detectedProject: String? = (useCwdProjectDetection && cwd != nil)
                ? ProjectRootResolver.projectName(for: cwd!)
                : nil

            // Step 5h: Build DevProcess
            let devProcess = DevProcess(
                id: pid,
                user: currentUserName,
                cpuPercent: cpuPercent,
                memPercent: memPercent,
                rss: rss,
                command: command,
                startTime: startDate,
                parentPID: parentPID,
                isOrphan: isOrphan,
                state: state,
                startTimestamp: startTvSec > 0 ? startTvSec : nil,
                workingDirectory: cwd,
                detectedProject: detectedProject
                // orphanConfidence and signals use their defaults (.none / .empty)
                // — ProcessMonitor.scan() post-pass sets the real values, identical
                // to how it enriches PSParser output.
            )
            results.append(devProcess)
        }

        return results
    }

    // MARK: - Private helpers

    /// Returns a buffer of PIDs for all processes, using a two-call pattern.
    private static func enumeratePIDs() -> [pid_t] {
        // First call: size the buffer
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }

        // Allocate with a small headroom in case new processes spawn between the two calls
        let capacity = Int(needed) + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let ret = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listpids(
                UInt32(PROC_ALL_PIDS), 0,
                buf.baseAddress,
                Int32(buf.count * MemoryLayout<pid_t>.stride)
            )
        }
        guard ret > 0 else { return [] }
        let count = Int(ret) / MemoryLayout<pid_t>.stride
        return Array(pids.prefix(count))
    }

    /// Build the command string for a PID: tries `proc_pidpath` first, falls back to `pbi_comm`.
    private static func resolveCommand(pid: pid_t, pbsd: proc_bsdinfo) -> String {
        // Full executable path via proc_pidpath (preferred).
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN = 4 * 1024 = 4096.
        // The macro is unavailable in Swift (uses structure not supported), so we inline the value.
        let pidPathMaxSize: Int = 4096
        var pathBuffer = [CChar](repeating: 0, count: pidPathMaxSize)
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pidPathMaxSize))
        if pathLen > 0 {
            return String(cString: pathBuffer)
        }

        // Fallback: extract the 16-char pbi_comm tuple (same pattern as ProcPIDInfo.swift:29-36)
        var bsd = pbsd  // local mutable copy so we can take UnsafeBytes of field
        return withUnsafeBytes(of: &bsd.pbi_comm) { rawBuf -> String in
            let bytes = rawBuf.bindMemory(to: CChar.self)
            if let termIdx = bytes.firstIndex(of: 0) {
                return String(bytes: rawBuf[..<termIdx], encoding: .utf8) ?? ""
            }
            return String(bytes: rawBuf, encoding: .utf8) ?? ""
        }
    }

    /// Map `pbi_status` (BSD proc status integer) to ``ProcessState``.
    ///
    /// BSD constants (sys/proc.h): SIDL=1, SRUN=2, SSLEEP=3, SSTOP=4, SZOMB=5, SWAIT=6.
    private static func processState(from pbiStatus: UInt32) -> ProcessState {
        switch pbiStatus {
        case 5:  return .zombie   // SZOMB
        case 4:  return .stopped  // SSTOP
        case 1, 2, 3, 6: return .running  // SIDL, SRUN, SSLEEP, SWAIT
        default: return .unknown
        }
    }
}
