import Darwin
import Foundation

/// Client of the kernel control `com.apple.network.statistics` (xnu bsd/net/ntstat.h, revision 9): what `nettop`
/// reads. No root and no entitlement; sees the sockets of this user's processes.
/// The ABI is private, so nothing is trusted before `selfTest()` passes.
final class NetStat: @unchecked Sendable {
    /// Bytes a flow moved since the last report.
    struct Delta {
        let pid: Int32
        let process: String
        let remote: RemoteAddress
        let port: UInt16
        let sent: UInt64
        let got: UInt64
    }

    private static let controlName = "com.apple.network.statistics"
    private static let addAllSources: UInt32 = 1002, getUpdate: UInt32 = 1007
    private static let sourceRemoved: UInt32 = 10002, sourceUpdate: UInt32 = 10006, sourceExtUpdate: UInt32 = 10007
    private static let useUpdateForAdd: UInt64 = 0x200000
    private static let tcpKernel: UInt32 = 2, udpKernel: UInt32 = 4

    private struct Flow {
        var sent: UInt64 = 0
        var got: UInt64 = 0
        var seen = false
    }

    private let fd: Int32
    private let lock = NSLock()
    private var flows: [UInt64: Flow] = [:]
    private var initialPhase = true
    private var context: UInt64 = 1
    private var closed = false
    /// Called on the reader thread.
    var onDelta: ((Delta) -> Void)?

    init?() {
        fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard fd >= 0 else { return nil }
        var info = ctl_info()
        withUnsafeMutableBytes(of: &info.ctl_name) { p in
            for (i, c) in Self.controlName.utf8.enumerated() { p[i] = c }
        }
        // CTLIOCGINFO = _IOWR('N', 3, struct ctl_info)
        let request: UInt = 0xC000_0000 | (UInt(MemoryLayout<ctl_info>.size & 0x1FFF) << 16) | (UInt(UInt8(ascii: "N")) << 8) | 3
        guard ioctl(fd, request, &info) == 0 else { close(fd); return nil }
        var addr = sockaddr_ctl()
        addr.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        addr.sc_family = UInt8(AF_SYSTEM)
        addr.ss_sysaddr = UInt16(AF_SYS_CONTROL)
        addr.sc_id = info.ctl_id
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_ctl>.size)) }
        }
        guard r == 0 else { close(fd); return nil }
        var big: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, socklen_t(4))
    }

    deinit { if !closed { close(fd) } }

    func stop() {
        lock.lock()
        if !closed { closed = true; close(fd) }
        lock.unlock()
    }

    private func message(_ type: UInt32, _ length: Int) -> [UInt8] {
        context += 1
        var b = [UInt8](repeating: 0, count: length)
        b.withUnsafeMutableBytes { p in
            p.storeBytes(of: context, toByteOffset: 0, as: UInt64.self)
            p.storeBytes(of: type, toByteOffset: 8, as: UInt32.self)
            p.storeBytes(of: UInt16(length), toByteOffset: 12, as: UInt16.self)
            p.storeBytes(of: UInt16(1), toByteOffset: 14, as: UInt16.self) // aggregate
        }
        return b
    }

    private func send(_ b: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        _ = b.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    }

    /// Every source of a provider, existing and future, as updates: a closing flow sends its last counters.
    private func subscribe(_ provider: UInt32) {
        var b = message(Self.addAllSources, 56)
        b.withUnsafeMutableBytes { p in
            p.storeBytes(of: Self.useUpdateForAdd, toByteOffset: 16, as: UInt64.self)
            p.storeBytes(of: provider, toByteOffset: 32, as: UInt32.self)
        }
        send(b)
    }

    /// Fresh counters of every live flow.
    func refresh() {
        var b = message(Self.getUpdate, 24)
        b.withUnsafeMutableBytes { $0.storeBytes(of: UInt64.max, toByteOffset: 16, as: UInt64.self) }
        send(b)
    }

    func start() {
        let t = Thread { [self] in readLoop() }
        t.name = "redakciya.netstat"
        t.stackSize = 1 << 20
        t.start()
        subscribe(Self.tcpKernel)
        subscribe(Self.udpKernel)
        refresh()
        // What is announced in the first half second existed before: its earlier bytes are not counted.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in
            lock.lock(); initialPhase = false; lock.unlock()
        }
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 1 << 17)
        while true {
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return
            }
            var deltas: [Delta] = []
            lock.lock()
            buf.withUnsafeBytes { p in
                var o = 0
                while o + 16 <= n {
                    let len = Int(p.loadUnaligned(fromByteOffset: o + 12, as: UInt16.self))
                    guard len >= 16, o + len <= n else { break }
                    if let d = handle(UnsafeRawBufferPointer(rebasing: p[o..<(o + len)])) { deltas.append(d) }
                    o += (len + 7) & ~7
                }
            }
            lock.unlock()
            for d in deltas { onDelta?(d) }
        }
    }

    private func handle(_ m: UnsafeRawBufferPointer) -> Delta? {
        func u32(_ o: Int) -> UInt32 { m.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
        func u64(_ o: Int) -> UInt64 { m.loadUnaligned(fromByteOffset: o, as: UInt64.self) }
        let type = u32(8)
        if type == Self.sourceRemoved, m.count >= 24 {
            flows.removeValue(forKey: u64(16))
            return nil
        }
        guard type == Self.sourceUpdate || type == Self.sourceExtUpdate, m.count >= 152 else { return nil }
        let ref = u64(16), provider = u32(144)
        // nstat_counts at 32: rx packets, rx bytes, tx packets, tx bytes.
        let got = u64(40), sent = u64(56)
        var flow = flows[ref] ?? Flow()
        defer { flows[ref] = flow }
        if !flow.seen {
            flow.seen = true
            if initialPhase {
                flow.sent = sent; flow.got = got
                return nil
            }
        }
        let dSent = sent >= flow.sent ? sent - flow.sent : 0, dGot = got >= flow.got ? got - flow.got : 0
        flow.sent = sent; flow.got = got
        guard dSent > 0 || dGot > 0 else { return nil }
        // Descriptors after the 152-byte update header: nstat_tcp_descriptor / nstat_udp_descriptor.
        let d = 152, size = m.count - d
        let pidAt: Int, remoteAt: Int, nameAt: Int
        switch provider {
        case Self.tcpKernel where size >= 348: (pidAt, remoteAt, nameAt) = (d + 116, d + 152, d + 196)
        case Self.udpKernel where size >= 272: (pidAt, remoteAt, nameAt) = (d + 128, d + 84, d + 132)
        default: return nil
        }
        guard let (remote, port) = Self.address(m, at: remoteAt) else { return nil }
        var name: [UInt8] = []
        for i in 0..<64 {
            let c = m[nameAt + i]
            if c == 0 { break }
            name.append(c)
        }
        return Delta(pid: Int32(bitPattern: u32(pidAt)), process: String(decoding: name, as: UTF8.self),
                     remote: remote, port: port, sent: dSent, got: dGot)
    }

    /// sockaddr_in / sockaddr_in6 as raw bytes; IPv4-mapped IPv6 becomes IPv4; «any» is no address.
    private static func address(_ m: UnsafeRawBufferPointer, at o: Int) -> (RemoteAddress, UInt16)? {
        let family = m[o + 1]
        let port = UInt16(m[o + 2]) << 8 | UInt16(m[o + 3])
        if family == UInt8(AF_INET) {
            let x = (4..<8).reduce(UInt32(0)) { $0 << 8 | UInt32(m[o + $1]) }
            return x == 0 ? nil : (.v4(x), port)
        }
        if family == UInt8(AF_INET6) {
            let b = (8..<24).map { m[o + $0] }
            if b.allSatisfy({ $0 == 0 }) { return nil }
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
                return (.v4(b[12..<16].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }), port)
            }
            return (.v6(b), port)
        }
        return nil
    }

    /// Our own connection on the loopback, 64 KB one way: the flow must show up with our pid, our process
    /// name and exactly these bytes. Blocks for up to three seconds; call off the main thread, after `start()`.
    func selfTest() -> Bool {
        let bytes = 65536
        Thread.sleep(forTimeInterval: 0.6) // past the start, when flows count as old
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { return false }
        defer { close(listener) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
                bind(listener, p, len) == 0 && listen(listener, 1) == 0 && getsockname(listener, p, &len) == 0
            }
        }
        guard bound else { return false }
        let port = UInt16(bigEndian: addr.sin_port)

        let me = getpid()
        var nameBuf = [CChar](repeating: 0, count: 256)
        proc_name(me, &nameBuf, UInt32(nameBuf.count))
        let myName = String(cString: nameBuf)
        let seen = NSLock()
        var total: UInt64 = 0, nameOK = true
        let previous = onDelta
        onDelta = { d in
            if d.pid == me, d.port == port, d.remote == .v4(0x7F00_0001) {
                seen.lock(); total += d.sent; if d.process != myName { nameOK = false }; seen.unlock()
            }
            previous?(d)
        }
        defer { onDelta = previous }

        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { return false }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        let server = connected ? accept(listener, nil, nil) : -1
        guard server >= 0 else { close(client); return false }
        let payload = [UInt8](repeating: 0x52, count: bytes)
        let wrote = payload.withUnsafeBytes { write(client, $0.baseAddress, bytes) }
        var readBuf = [UInt8](repeating: 0, count: bytes), got = 0
        while got < wrote {
            let n = readBuf.withUnsafeMutableBytes { read(server, $0.baseAddress, bytes) }
            if n <= 0 { break }
            got += n
        }
        close(client)
        close(server)
        guard wrote == bytes, got == bytes else { return false }
        for _ in 0..<30 {
            refresh()
            Thread.sleep(forTimeInterval: 0.1)
            seen.lock(); let t = total, ok = nameOK; seen.unlock()
            if t == UInt64(bytes) { return ok }
            if t > UInt64(bytes) { return false }
        }
        return false
    }
}
