import Foundation
import AgentCore
#if os(macOS)
import Darwin
import CoreGraphics
import ApplicationServices
#endif

// kist-control — the privileged desktop broker. The ONLY binary the user grants Accessibility/Screen-Recording.
// It performs discrete desktop actions on behalf of an AUTHENTICATED `kist` client over a Unix-domain socket.
// It runs NO shell / python / MCP / build tools. See docs/kist/KIST_CONTROL_SPLIT_IDENTITY_PLAN.md.
//
// NOTE: the TCC-separation security property is only REAL once this binary is separately code-signed with its
// own bundle id, launched independently (LaunchAgent), and granted TCC — verified on hardware. Until then this
// is the buildable/logic-tested broker; run `kist-control --status` to see the grant state.

func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ n: String) -> Bool { args.contains(n) }
func value(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

let socketPath = value("--socket") ?? UnixSocketTransport.defaultSocketPath()
let requirement = value("--requirement")               // pinned client code requirement (production)
let devTrust = flag("--dev-trust-same-uid")            // dev-only escape hatch (unsigned binaries)

// --status: report the broker's own TCC grant state (what actually gates actuation).
if flag("--status") {
    #if os(macOS)
    print("kist-control status")
    print("  Accessibility  : \(AXIsProcessTrusted() ? "GRANTED" : "not granted")")
    print("  Screen Record. : \(CGPreflightScreenCaptureAccess() ? "GRANTED" : "not granted")")
    print("  socket         : \(socketPath)")
    #else
    print("kist-control requires macOS.")
    #endif
    exit(0)
}

// --self-test: exercise the actuator locally (read-only screen_size) to prove wiring, no injection.
if flag("--self-test") {
    let resp = RealDesktopActuator().perform(DesktopActionRequest(id: "selftest", kind: .screenSize))
    print(resp.ok ? "self-test OK: screen \(resp.width ?? 0)x\(resp.height ?? 0)" : "self-test FAILED: \(resp.message)")
    exit(resp.ok ? 0 : 1)
}

// --send <kind>: act as a CLIENT — connect to a running broker + send one action, print the reply. Used to
// dogfood the full IPC path end-to-end (client → UDS → auth → BrokerCore → actuator → response).
if let kindRaw = value("--send") {
    guard let kind = DesktopActionKind(rawValue: kindRaw) else {
        stderr("--send: unknown action '\(kindRaw)'. Valid: \(DesktopActionKind.allCases.map(\.rawValue).joined(separator: ", "))"); exit(2)
    }
    let req = DesktopActionRequest(id: UUID().uuidString, kind: kind,
                                   x: value("--x").flatMap(Int.init), y: value("--y").flatMap(Int.init))
    do {
        let resp = try UnixSocketTransport.request(req, socketPath: socketPath)
        print(resp.ok ? "OK: \(resp.message)\(resp.width.map { " (\($0)x\(resp.height ?? 0))" } ?? "")"
                      : "DENIED[\(resp.code?.rawValue ?? "?")]: \(resp.message)")
        exit(resp.ok ? 0 : 1)
    } catch {
        stderr("--send failed to reach the broker at \(socketPath): \(error)"); exit(1)
    }
}

#if os(macOS)
if requirement == nil && !devTrust {
    stderr("⚠ kist-control: no --requirement pinned and --dev-trust-same-uid off → every peer will be REJECTED. " +
           "Pass a pinned client code requirement (production) or --dev-trust-same-uid (unsigned dev only).")
}
if devTrust { stderr("⚠ kist-control: --dev-trust-same-uid ON — trusting ANY same-uid process. NOT for production.") }

let auth = PeerAuthenticator(requirement: requirement, devTrustSameUID: devTrust)
let broker = BrokerCore(actuator: RealDesktopActuator(), expectedUID: getuid())

// Socket dir 0700, socket 0600. Remove a stale socket first.
let dir = (socketPath as NSString).deletingLastPathComponent
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
unlink(socketPath)

let listenFD = socket(AF_UNIX, UnixSocketTransport.sockStreamType, 0)
guard listenFD >= 0 else { stderr("socket() failed: \(errno)"); exit(1) }
var addr = try UnixSocketTransport.makeSockaddr(path: socketPath)
let bindRC = withUnsafePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard bindRC == 0 else { stderr("bind() failed: \(errno)"); exit(1) }
chmod(socketPath, 0o600)
guard listen(listenFD, 16) == 0 else { stderr("listen() failed: \(errno)"); exit(1) }
stderr("kist-control listening on \(socketPath)")

while true {
    let clientFD = accept(listenFD, nil, nil)
    if clientFD < 0 {
        if errno == EINTR { continue }
        // A transient accept() error (ECONNABORTED/EMFILE/ENFILE/ENOBUFS/…) must NOT kill a long-lived broker
        // (kist-review finding). Log + brief backoff (avoid a tight spin on fd exhaustion) + keep serving.
        stderr("accept() error \(errno) — continuing"); usleep(10_000); continue
    }
    // DoS guard (kist-review finding): a client that connects but never sends must not hang the single-threaded
    // loop. A 5s recv timeout ⇒ read() returns EAGAIN ⇒ readFrame throws ⇒ the connection is dropped below.
    // (auth.resolve is point-in-time but a CONNECTED UDS peer cannot change for the connection's lifetime, so
    // the deferred read carries no auth TOCTOU — the earlier "TOCTOU" review note is not exploitable here.)
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let peer = auth.resolve(fd: clientFD)
    do {
        let request = try UnixSocketTransport.readFrame(DesktopActionRequest.self, from: clientFD)
        let response = broker.handle(request, from: peer)   // auth + gates enforced HERE (tested)
        try UnixSocketTransport.writeFrame(response, to: clientFD)
    } catch {
        // best-effort error frame; ignore write failures on a dying connection
        let resp = DesktopActionResponse.failure(id: "-", .invalidRequest, "broker read/write error: \(error)")
        try? UnixSocketTransport.writeFrame(resp, to: clientFD)
    }
    shutdown(clientFD, SHUT_RDWR)   // flush the write side so the peer receives the reply before close (review #4)
    close(clientFD)
}
#else
stderr("kist-control requires macOS.")
exit(1)
#endif
