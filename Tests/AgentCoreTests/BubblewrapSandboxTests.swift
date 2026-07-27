import XCTest
@testable import AgentCore

/// Pins the Linux bubblewrap policy→argv contract. Pure (no bwrap needed) so it runs on macOS CI too;
/// the actual enforcement is proven by the Docker integration test (scripts/linux-sandbox-test.sh).
final class BubblewrapSandboxTests: XCTestCase {

    /// True if `needle` appears as a CONTIGUOUS subsequence of `haystack`.
    private func contains(_ haystack: [String], subsequence needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start+needle.count]) == needle {
            return true
        }
        return false
    }

    func testConfinedPolicyBuildsExpectedArgv() {
        let argv = BubblewrapSandbox.buildArgs(
            root: "/work", cwd: "/work/sub", policy: .confined(),
            launchPath: "/bin/echo", args: ["hello", "world"])

        XCTAssertTrue(argv.contains("--die-with-parent"))
        XCTAssertTrue(argv.contains("--unshare-pid"), "fresh PID ns: no /proc/<pid>/environ of other procs")
        XCTAssertTrue(argv.contains("--new-session"), "detach tty: no TIOCSTI keystroke injection")
        XCTAssertTrue(contains(argv, subsequence: ["--ro-bind", "/", "/"]), "host must be read-only")
        XCTAssertTrue(contains(argv, subsequence: ["--bind", "/work", "/work"]), "project root must be writable")
        XCTAssertTrue(contains(argv, subsequence: ["--tmpfs", "/tmp"]), "scratch /tmp")
        XCTAssertTrue(contains(argv, subsequence: ["--tmpfs", "/run"]), "mask host sockets (docker.sock)")
        XCTAssertTrue(argv.contains("--unshare-net"), "network egress must be denied")
        XCTAssertTrue(contains(argv, subsequence: ["--chdir", "/work/sub"]), "must run in the cwd")
        // The command + args come last, after the `--` separator, in order.
        XCTAssertTrue(contains(argv, subsequence: ["--", "/bin/echo", "hello", "world"]))
    }

    func testDenyNetworkFalseOmitsUnshareNet() {
        let argv = BubblewrapSandbox.buildArgs(
            root: "/work", cwd: "/work", policy: .confined(denyNetwork: false),
            launchPath: "/bin/echo", args: [])
        XCTAssertFalse(argv.contains("--unshare-net"))
        XCTAssertTrue(contains(argv, subsequence: ["--ro-bind", "/", "/"]))   // writes still confined
    }

    func testConfineWritesFalseMakesRootWritable() {
        let argv = BubblewrapSandbox.buildArgs(
            root: "/work", cwd: "/work", policy: .confined(confineWrites: false),
            launchPath: "/bin/echo", args: [])
        XCTAssertTrue(contains(argv, subsequence: ["--bind", "/", "/"]), "no write confinement → / writable")
        XCTAssertFalse(contains(argv, subsequence: ["--ro-bind", "/", "/"]))
        XCTAssertTrue(argv.contains("--unshare-net"), "network still denied by default")
    }

    /// A disabled sandbox is passthrough on every platform (no wrapping).
    func testDisabledPolicyIsPassthrough() {
        let w = SeatbeltSandbox.wrap(launchPath: "/bin/echo", args: ["hi"], root: "/tmp",
                                     policy: .disabled, cwd: "/tmp")
        XCTAssertEqual(w, .passthrough)
    }
}
