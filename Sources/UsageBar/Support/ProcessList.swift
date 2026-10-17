import Darwin

/// Process details read in-process through libproc and sysctl, the same sources ps and lsof
/// use. Spawning ps and lsof cost about 70 ms of CPU per live-session scan; this costs about 2 ms.
enum ProcessList {
    /// Every readable process with its arguments joined by spaces, like `ps -axo pid=,args=`.
    static func commandLines() -> [(pid: Int32, args: String)] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return [] }

        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.argmax", &argmax, &size, nil, 0) == 0, argmax > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var out: [(pid: Int32, args: String)] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var length = buffer.count
            guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0,
                  let args = arguments(buffer, length: length), !args.isEmpty else { continue }
            out.append((pid, args.joined(separator: " ")))
        }
        return out
    }

    /// KERN_PROCARGS2 is argc, the executable path, NUL padding, then argc NUL-terminated strings.
    static func arguments(_ buffer: [UInt8], length: Int) -> [String]? {
        let size = MemoryLayout<Int32>.size
        guard length > size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = size
        while i < length, buffer[i] != 0 { i += 1 }
        while i < length, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < Int(argc), i < length {
            let start = i
            while i < length, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// The process's working directory.
    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = string(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// Paths of the files the process has open.
    static func openFiles(_ pid: Int32) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = string(info.pvip.vip_path)
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    /// A fixed C char array, read up to its first NUL.
    private static func string<T>(_ chars: T) -> String {
        withUnsafeBytes(of: chars) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
