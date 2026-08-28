import AppKit
import Darwin

/// A top-level application eligible for tapping (the picker lists these).
struct TargetApp: Identifiable, Hashable {
    let pid: pid_t
    let name: String
    let bundleID: String?

    var id: pid_t { pid }
}

/// Discovers running apps and enumerates their child process trees so the
/// tap covers browser audio helper processes (Chrome Helper (Audio),
/// com.apple.WebKit.GPU, ...). Tapping only the parent PID captures silence.
enum ProcessScanner {
    /// All pids on the system with their parent pids.
    private static func processTree() -> [pid_t: [pid_t]] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        sysctl(&mib, 3, nil, &size, nil, 0)
        var procs = [kinfo_proc]()
        procs.reserveCapacity(size / MemoryLayout<kinfo_proc>.stride)
        procs.append(contentsOf: repeatingKInfo(count: size / MemoryLayout<kinfo_proc>.stride))
        if sysctl(&mib, 3, &procs, &size, nil, 0) != 0 {
            return [:]
        }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var tree: [pid_t: [pid_t]] = [:]
        for i in 0..<count {
            let kp = withUnsafeBytes(of: procs[i]) { raw in
                raw.load(as: kinfo_proc.self)
            }
            let pid = kp.kp_proc.p_pid
            let ppid = kp.kp_eproc.e_ppid
            if pid > 0 {
                tree[ppid, default: []].append(pid)
            }
        }
        return tree
    }

    private static func repeatingKInfo(count: Int) -> [kinfo_proc] {
        Array(repeating: kinfo_proc(), count: count)
    }

    /// All descendant pids of `root` (children, grandchildren, ...).
    static func descendants(of root: pid_t, tree: [pid_t: [pid_t]]) -> [pid_t] {
        var result: [pid_t] = []
        var stack = [root]
        var visited = Set<pid_t>()
        while let pid = stack.popLast() {
            guard !visited.contains(pid) else { continue }
            visited.insert(pid)
            for child in tree[pid] ?? [] {
                result.append(child)
                stack.append(child)
            }
        }
        return result
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Candidate apps for the source picker: regular, non-background apps
    /// with a bundle (browsers etc.), excluding Mimi itself.
    static func pickableApps() -> [TargetApp] {
        let workspace = NSWorkspace.shared
        return workspace.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { app -> TargetApp? in
                let name = app.localizedName ?? app.bundleIdentifier ?? "PID \(app.processIdentifier)"
                return TargetApp(
                    pid: pid_t(app.processIdentifier),
                    name: name,
                    bundleID: app.bundleIdentifier
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The pid set to tap for a chosen app: the app itself plus its whole
    /// descendant tree (audio helpers are child processes).
    static func tapPIDs(for app: TargetApp) -> [pid_t] {
        let tree = processTree()
        var pids = descendants(of: app.pid, tree: tree)
        pids.insert(app.pid, at: 0)
        return pids.filter { isAlive($0) }
    }
}
