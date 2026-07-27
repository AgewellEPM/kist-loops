import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Minimal length-prefixed Unix-domain-socket transport shared by the `kist` client and the `kist-control`
/// broker. Framing is `KistControlFraming` (4-byte big-endian length + JSON). Blocking I/O, one request per
/// connection (the broker's actions are discrete + serialized). The socket path lives in a 0700 per-user dir.
public enum UnixSocketTransport {

    /// Canonical broker socket path: `~/Library/Application Support/kist/control.sock` (dir 0700, socket 0600).
    public static func defaultSocketPath() -> String {
        let base = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/kist")
        return (base as NSString).appendingPathComponent("control.sock")
    }

    public enum TransportError: Error, Equatable {
        case socketCreateFailed(Int32), bindFailed(Int32), connectFailed(Int32), pathTooLong
        case peerClosed, ioFailed(Int32), badFrame
    }

    // MARK: - low-level framed read/write over an fd

    public static func writeFrame<T: Encodable>(_ value: T, to fd: Int32) throws {
        let data = try KistControlFraming.encode(value)
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < data.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), data.count - off)
                if n > 0 { off += n; continue }
                if n < 0 && errno == EINTR { continue }   // interrupted by a signal → retry, don't fail the frame
                throw TransportError.ioFailed(errno)      // real error (or a stuck 0-progress write)
            }
        }
    }

    public static func readFrame<T: Decodable>(_ type: T.Type, from fd: Int32, maxBytes: Int = 64 * 1024 * 1024) throws -> T {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            if let (value, _) = try KistControlFraming.decode(T.self, from: buffer, maxBytes: maxBytes) {
                return value
            }
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n == 0 { throw TransportError.peerClosed }               // EOF: peer closed
            if n < 0 {
                if errno == EINTR { continue }                          // interrupted by a signal → retry
                throw TransportError.ioFailed(errno)
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    public static func makeSockaddr(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < maxLen else { throw TransportError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    // MARK: - client

    /// Connect, send one request, read one response, close.
    public static func request(_ req: DesktopActionRequest, socketPath: String) throws -> DesktopActionResponse {
        let fd = socket(AF_UNIX, sockStreamType, 0)
        if fd < 0 { throw TransportError.socketCreateFailed(errno) }
        defer { close(fd) }
        var addr = try makeSockaddr(path: socketPath)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 { throw TransportError.connectFailed(errno) }
        try writeFrame(req, to: fd)
        return try readFrame(DesktopActionResponse.self, from: fd)
    }

    #if os(Linux)
    public static let sockStreamType = Int32(SOCK_STREAM.rawValue)
    #else
    public static let sockStreamType = SOCK_STREAM
    #endif
}
