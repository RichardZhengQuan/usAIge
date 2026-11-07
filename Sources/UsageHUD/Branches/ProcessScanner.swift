import Darwin
import Foundation

struct WorkProcess: Identifiable, Equatable, Sendable {
    let id: Int32
    let name: String
    let folder: String
    /// The figure Activity Monitor calls Memory.
    let memoryBytes: UInt64
    let startedAt: Date?
    let ports: [Int]
    var executablePath: String? = nil
}

/// Lists processes with their working folders and listening TCP ports through
/// libproc, without starting a helper. This app's own children are left out,
/// so its git and du runs never make a folder look busy.
enum ProcessScanner {
    /// Reads details only for the processes `wanted` accepts, given each one's
    /// id, working folder, and executable.
    static func scan(
        includePorts: Bool = true,
        wanted: (pid_t, String, String?) -> Bool = { _, folder, _ in folder != "/" }
    ) -> [WorkProcess] {
        let ownID = getpid()
        var identifiers = [pid_t](repeating: 0, count: 8192)
        let byteCount = proc_listallpids(&identifiers, Int32(identifiers.count * MemoryLayout<pid_t>.size))
        guard byteCount > 0 else { return [] }
        var processes: [WorkProcess] = []
        for pid in identifiers.prefix(Int(byteCount)) where pid > 0 && pid != ownID {
            var paths = proc_vnodepathinfo()
            let pathSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, pathSize) == pathSize else { continue }
            let folder = withUnsafePointer(to: paths.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard !folder.isEmpty else { continue }
            let executable = executablePath(of: pid)
            guard wanted(pid, folder, executable) else { continue }
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let hasInfo = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize
            if hasInfo, info.pbi_ppid == UInt32(ownID) { continue }
            var name = [CChar](repeating: 0, count: 1024)
            proc_name(pid, &name, UInt32(name.count))
            processes.append(WorkProcess(
                id: pid,
                name: String(cString: name),
                folder: folder,
                memoryBytes: memoryBytes(of: pid),
                startedAt: hasInfo ? Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)) : nil,
                ports: includePorts ? listeningPorts(of: pid) : [],
                executablePath: executable
            ))
        }
        return processes
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// Physical footprint, falling back to resident size. Resident size counts
    /// pages shared with other processes, so it reads far higher for a
    /// family of helpers than the memory they really use.
    static func memoryBytes(of pid: pid_t) -> UInt64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        if result == 0 { return usage.ri_phys_footprint }
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size ? task.pti_resident_size : 0
    }

    static func listeningPorts(of pid: pid_t) -> [Int] {
        let byteCount = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard byteCount > 0 else { return [] }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(byteCount) / MemoryLayout<proc_fdinfo>.size)
        let received = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, byteCount)
        guard received > 0 else { return [] }
        var ports: Set<Int> = []
        for descriptor in descriptors.prefix(Int(received) / MemoryLayout<proc_fdinfo>.size)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) > 0,
                  socket.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            ports.insert(Int(UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport).byteSwapped))
        }
        return ports.sorted()
    }
}
