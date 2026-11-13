import AppKit
import Darwin

/// What's running right now — used to skip data that's in use and to ask the
/// user to quit apps before their files are moved.
struct RunningState: Sendable {
    /// Bundle IDs of running apps.
    let bundleIDs: Set<String>
    /// Executable names of all of the user's processes ("cargo", "go", "node").
    let executables: Set<String>

    @MainActor static func current() -> RunningState {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return RunningState(bundleIDs: ids, executables: ProcessProbe.executableNames())
    }
}

enum ProcessProbe {
    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(n, 0)))).filter { $0 > 0 }
    }

    static func executableNames() -> Set<String> {
        var names = Set<String>()
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        for pid in allPIDs() where proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            names.insert(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return names
    }

    /// Paths under `roots` that some process of this user has open, or uses as
    /// its working directory. Other users' processes are not inspectable and are
    /// irrelevant for our own temp items.
    static func pathsInUse(under roots: [String]) -> Set<String> {
        var result = Set<String>()
        func consider(_ path: String) {
            if roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { result.insert(path) }
        }
        let uid = getuid()
        for pid in allPIDs() {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  info.pbi_uid == uid else { continue }

            var vnodes = proc_vnodepathinfo()
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodes, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
                consider(path(of: &vnodes.pvi_cdir.vip_path))
            }

            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            let count = Int(size) / MemoryLayout<proc_fdinfo>.size
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
            for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var vinfo = vnode_fdinfowithpath()
                if proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vinfo,
                                  Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 {
                    consider(path(of: &vinfo.pvip.vip_path))
                }
            }
        }
        return result
    }

    private static func path<T>(of tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }
}
