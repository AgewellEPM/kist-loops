import Foundation
import XCTest
@testable import AgentCore

#if os(macOS)
import Darwin

/// Real kernel checks for the operator wrapper's self-inspection exception. These fixtures
/// never create worker permits, call models, inspect user files, or contact a network peer.
final class OperatorActionSandboxRuntimeTests: XCTestCase {
    func testActualGitDiffCheckInHomeWorkspace() async throws {
        try await assertGitDiffCheck(homeWorkspace: true)
    }

    func testActualGitDiffCheckOutsideHomeWorkspace() async throws {
        try await assertGitDiffCheck(homeWorkspace: false)
    }

    func testSelfInspectionWorksAndOtherBoundariesHoldInHomeWorkspace() async throws {
        try await assertProcessAndFileBoundaries(homeWorkspace: true)
    }

    func testSelfInspectionWorksAndOtherBoundariesHoldOutsideHomeWorkspace() async throws {
        try await assertProcessAndFileBoundaries(homeWorkspace: false)
    }

    func testFoundationAtomicReplacementStaysInHomeWorkspace() async throws {
        try await assertFoundationReplacement(homeWorkspace: true)
    }

    func testFoundationAtomicReplacementStaysInOutsideHomeWorkspace() async throws {
        try await assertFoundationReplacement(homeWorkspace: false)
    }

    func testProductionSwiftRecipeRunsPassingAndFailingTestsInsideMandatorySandbox() async throws {
        let fixture = try RuntimeFixture(homeWorkspace: true)
        defer { fixture.remove() }
        let package = #"""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "OperatorRuntimeFixture", targets: [
            .target(name: "Fixture"),
            .testTarget(name: "FixtureTests", dependencies: ["Fixture"])
        ])
        """#
        let passingTest = #"""
        import XCTest
        @testable import Fixture
        final class FixtureTests: XCTestCase {
            func testHostRecipeActuallyExecutesAssertions() { XCTAssertEqual(answer(), 42) }
        }
        """#
        for relative in ["Sources", "Sources/Fixture", "Tests", "Tests/FixtureTests"] {
            try FileManager.default.createDirectory(atPath: fixture.workspace + "/" + relative,
                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try Data(package.utf8).write(to: URL(fileURLWithPath: fixture.workspace + "/Package.swift"))
        try Data("public func answer() -> Int { 42 }\n".utf8)
            .write(to: URL(fileURLWithPath: fixture.workspace + "/Sources/Fixture/Fixture.swift"))
        let testPath = fixture.workspace + "/Tests/FixtureTests/FixtureTests.swift"
        try Data(passingTest.utf8).write(to: URL(fileURLWithPath: testPath))
        let request = OperatorActionRequest(schema_version: 1, action_id: UUID().uuidString,
            claim_id: UUID().uuidString, mission_id: "runtime-fixture", project_root: fixture.project,
            workspace_root: fixture.workspace, policy_sha256: OperatorActionHost.policySHA256,
            operation: "check", root_scope: "workspace", arguments: ["check_id": .string("swift_test")])
        let invocation = OperatorActionHost.checkInvocation("swift_test", input: request,
            target: fixture.workspace, authorities: fixture.authorities)
        XCTAssertEqual(invocation.executable, "/usr/bin/swift")
        XCTAssertEqual(invocation.arguments.first, "test")
        XCTAssertTrue(invocation.arguments.contains("--disable-sandbox"),
            "SwiftPM must not attempt a nested manifest sandbox inside the mandatory host sandbox")
        for flag in ["--disable-automatic-resolution", "--disable-netrc", "--disable-keychain", "--no-parallel"] {
            XCTAssertTrue(invocation.arguments.contains(flag), "Missing fixed host recipe flag: " + flag)
        }
        try fixture.assertRequiredProfile(invocation)

        let passing = await OperatorActionHost.runSandboxedCheck(invocation)
        try requireObservedCheck(passing)
        XCTAssertEqual(passing.exitCode, 0, passing.output)
        XCTAssertTrue(passing.output.contains("testHostRecipeActuallyExecutesAssertions"), passing.output)
        XCTAssertTrue(passing.output.contains("Executed 1 test, with 0 failures"), passing.output)

        let failingTest = passingTest.replacingOccurrences(of: "XCTAssertEqual(answer(), 42)",
            with: "XCTAssertEqual(answer(), 43, \"intentional-runtime-fixture-failure\")")
        try Data(failingTest.utf8).write(to: URL(fileURLWithPath: testPath))
        let failing = await OperatorActionHost.runSandboxedCheck(invocation)
        try requireObservedCheck(failing)
        XCTAssertNotEqual(failing.exitCode, 0, failing.output)
        XCTAssertTrue(failing.output.contains("intentional-runtime-fixture-failure"), failing.output)
        XCTAssertTrue(failing.output.contains("Executed 1 test, with 1 failure"), failing.output)
    }

    private func assertFoundationReplacement(homeWorkspace: Bool) async throws {
        let fixture = try RuntimeFixture(homeWorkspace: homeWorkspace)
        defer { fixture.remove() }
        let source = fixture.workspace + "/foundation_atomic_probe.m"
        let executable = fixture.workspace + "/foundation_atomic_probe"
        try Data(Self.foundationProbeSource.utf8).write(to: URL(fileURLWithPath: source))
        let compilation = await fixture.run(executable: "/usr/bin/clang",
            arguments: ["-fobjc-arc", source, "-o", executable, "-framework", "Foundation"], timeout: 30)
        try requireSuccess(compilation)
        let invocation = OperatorActionHost.CheckInvocation(executable: executable,
            arguments: [fixture.workspace], workspace: fixture.workspace, authorityRoot: fixture.authorities,
            projectRoot: fixture.project, timeoutSeconds: 15)
        try fixture.assertRequiredProfile(invocation)
        let result = await OperatorActionHost.runSandboxedCheck(invocation)
        try requireObservedCheck(result)
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("atomic_create=observed atomic_replace=observed replacement_sentinel=observed"),
            result.output)
        let replacement = try XCTUnwrap(result.output.components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("replacement=") }))
        let replacementPath = String(replacement.dropFirst("replacement=".count))
        XCTAssertTrue(replacementPath.hasPrefix(fixture.workspace + "/"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacementPath), "Child must remove its returned staging directory")
        XCTAssertEqual(try String(contentsOfFile: fixture.workspace + "/Fixture.build/output-file-map.json", encoding: .utf8),
            "replacement-bytes\n")
    }

    private func requireObservedCheck(_ result: OperatorActionHost.CheckObservation,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(result.sandboxed, result.output, file: file, line: line)
        XCTAssertFalse(result.timedOut, result.output, file: file, line: line)
        XCTAssertFalse(result.cancelled, result.output, file: file, line: line)
        XCTAssertFalse(result.wasSignalled, result.output, file: file, line: line)
        XCTAssertFalse(result.outputTruncated, result.output, file: file, line: line)
        guard result.sandboxed, !result.timedOut, !result.cancelled,
              !result.wasSignalled, !result.outputTruncated else {
            throw NSError(domain: "OperatorActionSandboxRuntimeTests", code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "Production check did not finish ordinarily inside its sandbox: " + result.output])
        }
    }

    private func assertGitDiffCheck(homeWorkspace: Bool) async throws {
        let fixture = try RuntimeFixture(homeWorkspace: homeWorkspace)
        defer { fixture.remove() }
        try Data("baseline\n".utf8).write(to: URL(fileURLWithPath: fixture.workspace + "/tracked.txt"))
        let setupCommands = [["init", "--quiet", "--template=", "--initial-branch=fixture"],
                             ["add", "--", "tracked.txt"]]
        for arguments in setupCommands {
            let result = await fixture.run(executable: "/usr/bin/git",
                arguments: ["-c", "core.hooksPath=/dev/null"] + arguments)
            try requireSuccess(result)
        }
        let arguments = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                         "diff", "--check", "--no-ext-diff", "--no-textconv"]
        let clean = try await fixture.runWrapped(executable: "/usr/bin/git", arguments: arguments)
        try requireSuccess(clean)
        XCTAssertEqual(clean.stdout, "", clean.combined)

        try Data("baseline\nadded trailing whitespace  \n".utf8)
            .write(to: URL(fileURLWithPath: fixture.workspace + "/tracked.txt"))
        let whitespace = try await fixture.runWrapped(executable: "/usr/bin/git", arguments: arguments)
        assertOrdinaryExit(whitespace)
        XCTAssertNotEqual(whitespace.exitCode, 0, whitespace.combined)
        XCTAssertTrue(whitespace.stdout.contains("trailing whitespace"), whitespace.combined)
        XCTAssertTrue(whitespace.stdout.contains("tracked.txt"), whitespace.combined)
    }

    private func assertProcessAndFileBoundaries(homeWorkspace: Bool) async throws {
        let fixture = try RuntimeFixture(homeWorkspace: homeWorkspace)
        defer { fixture.remove() }
        let source = fixture.workspace + "/process_boundary_probe.c"
        let executable = fixture.workspace + "/process_boundary_probe"
        let inside = fixture.workspace + "/inside.txt"
        let sibling = fixture.homeBase + "/sibling.txt"
        let outsideWrite = fixture.outside + "/must-not-exist.txt"
        try Data(Self.probeSource.utf8).write(to: URL(fileURLWithPath: source))
        try Data("inside-sandbox\n".utf8).write(to: URL(fileURLWithPath: inside))
        try Data("disposable-sibling-sentinel\n".utf8).write(to: URL(fileURLWithPath: sibling))
        let compilation = await fixture.run(executable: "/usr/bin/clang",
            arguments: ["-std=c11", "-Wall", "-Wextra", "-Werror", source, "-o", executable, "-lproc"], timeout: 30)
        try requireSuccess(compilation)
        let result = try await fixture.runWrapped(executable: executable,
            arguments: [inside, sibling, outsideWrite])
        try requireSuccess(result)
        XCTAssertEqual(result.stdout,
            "self=observed parent=denied inside=observed sibling=denied outside_write=denied loopback_bind=denied\n",
            result.combined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideWrite))
        XCTAssertEqual(try String(contentsOfFile: sibling, encoding: .utf8), "disposable-sibling-sentinel\n")
    }

    private func assertOrdinaryExit(_ result: ProcessGroupRunner.Outcome,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.timedOut, result.combined, file: file, line: line)
        XCTAssertFalse(result.cancelled, result.combined, file: file, line: line)
        XCTAssertFalse(result.wasSignalled, result.combined, file: file, line: line)
        XCTAssertFalse(result.outputTruncated, result.combined, file: file, line: line)
    }

    private func requireSuccess(_ result: ProcessGroupRunner.Outcome,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        assertOrdinaryExit(result, file: file, line: line)
        XCTAssertEqual(result.exitCode, 0, result.combined, file: file, line: line)
        guard result.exitCode == 0, !result.timedOut, !result.cancelled,
              !result.wasSignalled, !result.outputTruncated else {
            throw NSError(domain: "OperatorActionSandboxRuntimeTests", code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "Fixed local fixture command failed: " + result.combined])
        }
    }

    private final class RuntimeFixture {
        let homeBase: String
        let base: String
        let workspace: String
        let authorities: String
        let project: String
        let outside: String

        init(homeWorkspace: Bool) throws {
            let suffix = ".kist-operator-runtime-" + UUID().uuidString
            let rawHome = NSHomeDirectory() + "/" + suffix
            let rawBase = homeWorkspace ? rawHome : NSTemporaryDirectory() + suffix
            var created: [String] = []
            do {
                try FileManager.default.createDirectory(atPath: rawHome, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                created.append(rawHome)
                if !homeWorkspace {
                    try FileManager.default.createDirectory(atPath: rawBase, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    created.append(rawBase)
                }
                // Use realpath-backed strings throughout; Foundation can collapse /private/var
                // URLs back to the /var symlink, which the production no-follow policy rejects.
                homeBase = try XCTUnwrap(ToolContext.canonicalize(rawHome))
                base = try XCTUnwrap(ToolContext.canonicalize(rawBase))
                workspace = base + "/Workspace"
                authorities = base + "/Authorities"
                project = base + "/Project"
                outside = base + "/Outside"
                for path in [workspace, authorities, project, outside,
                             workspace + "/.operator-action", workspace + "/.operator-action/home",
                             workspace + "/.operator-action/tmp", workspace + "/.operator-action/module-cache"] {
                    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                }
            } catch {
                for path in created.reversed() { try? FileManager.default.removeItem(atPath: path) }
                throw error
            }
        }

        func remove() {
            do { try FileManager.default.removeItem(atPath: base) }
            catch { XCTFail("Could not remove disposable runtime fixture: \(error)") }
            if homeBase != base {
                do { try FileManager.default.removeItem(atPath: homeBase) }
                catch { XCTFail("Could not remove disposable home sentinel fixture: \(error)") }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: base))
            XCTAssertFalse(FileManager.default.fileExists(atPath: homeBase))
        }

        private var environment: [String: String] {
            ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": workspace + "/.operator-action/home",
             "CFFIXED_USER_HOME": workspace + "/.operator-action/home",
             "TMPDIR": workspace + "/.operator-action/tmp/", "LANG": "C", "LC_ALL": "C",
             "CLANG_MODULE_CACHE_PATH": workspace + "/.operator-action/module-cache",
             "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        }

        func run(executable: String, arguments: [String], timeout: Int = 15) async -> ProcessGroupRunner.Outcome {
            await ProcessGroupRunner.runAsync(launchPath: executable, launchArgs: arguments,
                cwd: workspace, env: environment, timeoutSeconds: timeout, capPerStream: 32_768, graceSeconds: 1)
        }

        func runWrapped(executable: String, arguments: [String]) async throws -> ProcessGroupRunner.Outcome {
            let invocation = OperatorActionHost.CheckInvocation(executable: executable, arguments: arguments,
                workspace: workspace, authorityRoot: authorities, projectRoot: project, timeoutSeconds: 15)
            let wrapped = try assertRequiredProfile(invocation)
            return await run(executable: wrapped.launcher, arguments: wrapped.arguments)
        }

        @discardableResult
        func assertRequiredProfile(_ invocation: OperatorActionHost.CheckInvocation) throws -> (launcher: String, arguments: [String]) {
            guard case .wrapped(let launcher, let argv) = OperatorActionHost.wrapped(invocation),
                  launcher == "/usr/bin/sandbox-exec", argv.count >= 3, argv[0] == "-p" else {
                throw NSError(domain: "OperatorActionSandboxRuntimeTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Required operator sandbox was unavailable"])
            }
            XCTAssertTrue(argv[1].contains("(deny process-info*)"))
            XCTAssertTrue(argv[1].contains("(allow process-info* (target self))"))
            XCTAssertTrue(argv[1].contains("(deny network*)"))
            XCTAssertTrue(argv[1].contains("(deny file-write*)"))
            XCTAssertTrue(argv[1].contains("(deny file-link)"))
            var temporary = [CChar](repeating: 0, count: Int(PATH_MAX))
            let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &temporary, temporary.count)
            XCTAssertGreaterThan(length, 0)
            XCTAssertLessThanOrEqual(length, temporary.count)
            let physicalTemporary = try XCTUnwrap(ToolContext.canonicalize(String(cString: temporary)))
            let tempDenial = "(deny file-read* (subpath \(SeatbeltSandbox.quote(physicalTemporary))))"
            let workspaceAllowance = "(allow file-read* (subpath \(SeatbeltSandbox.quote(workspace))))"
            let denied = try XCTUnwrap(argv[1].range(of: tempDenial))
            let allowed = try XCTUnwrap(argv[1].range(of: workspaceAllowance, options: .backwards))
            XCTAssertLessThan(denied.lowerBound, allowed.lowerBound,
                "A workspace inside Darwin temporary storage must retain its exact read grant")
            return (launcher, argv)
        }
    }

    private static let foundationProbeSource = #"""
    #import <Foundation/Foundation.h>
    #include <fcntl.h>
    #include <limits.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/stat.h>
    #include <unistd.h>

    static int fail(int code, NSError *error) {
        fprintf(stderr, "foundation fixture failure %d: %s\n", code,
            error ? [[error description] UTF8String] : "boundary or byte mismatch");
        return code;
    }
    int main(int argc, char **argv) {
        if (argc != 2) return 80;
        @autoreleasepool {
            char root[PATH_MAX] = {0}, replacementPath[PATH_MAX] = {0};
            // realpath on the absolute name inspects deliberately unreadable ancestors.
            // Bind the already-open working directory through its kernel-resolved fd path.
            int rootFD = open(".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (rootFD < 0) return 81;
            int rootPathResult = fcntl(rootFD, F_GETPATH, root);
            close(rootFD);
            if (rootPathResult != 0 || strcmp(root, argv[1]) != 0) return 81;
            NSFileManager *manager = [NSFileManager defaultManager];
            NSURL *directory = [NSURL fileURLWithPath:[NSString stringWithUTF8String:root] isDirectory:YES];
            NSURL *build = [directory URLByAppendingPathComponent:@"Fixture.build" isDirectory:YES];
            NSError *error = nil;
            if (![manager createDirectoryAtURL:build withIntermediateDirectories:NO
                    attributes:@{NSFilePosixPermissions: @0700} error:&error]) return fail(82, error);
            NSURL *destination = [build URLByAppendingPathComponent:@"output-file-map.json"];
            NSData *original = [@"original-bytes\n" dataUsingEncoding:NSUTF8StringEncoding];
            if (![original writeToURL:destination options:NSDataWritingAtomic error:&error]) return fail(83, error);
            if (![[NSData dataWithContentsOfURL:destination] isEqualToData:original]) return fail(84, nil);

            // Resolve the actual replacement location. NSTemporaryDirectory can still name
            // shared storage even when Foundation chooses writable destination-local staging.
            NSURL *replacement = [manager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask
                appropriateForURL:destination create:YES error:&error];
            if (!replacement) return fail(85, error);
            int replacementFD = open([[replacement path] fileSystemRepresentation],
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (replacementFD < 0) return fail(86, nil);
            int replacementPathResult = fcntl(replacementFD, F_GETPATH, replacementPath);
            struct stat attributes = {0};
            int attributesResult = fstat(replacementFD, &attributes);
            close(replacementFD);
            if (replacementPathResult != 0 || attributesResult != 0) return fail(86, nil);
            size_t rootLength = strlen(root);
            if (strncmp(replacementPath, root, rootLength) != 0 || replacementPath[rootLength] != '/') return fail(87, nil);
            if (!S_ISDIR(attributes.st_mode)
                || attributes.st_uid != geteuid()) return fail(88, nil);
            NSURL *sentinel = [replacement URLByAppendingPathComponent:@"disposable-sentinel.txt"];
            if (![original writeToURL:sentinel options:0 error:&error]) return fail(89, error);
            if (![[NSData dataWithContentsOfURL:sentinel] isEqualToData:original]) return fail(90, nil);

            NSData *updated = [@"replacement-bytes\n" dataUsingEncoding:NSUTF8StringEncoding];
            if (![updated writeToURL:destination options:NSDataWritingAtomic error:&error]) return fail(91, error);
            if (![[NSData dataWithContentsOfURL:destination] isEqualToData:updated]) return fail(92, nil);
            if (![manager removeItemAtURL:replacement error:&error]) return fail(93, error);
            if ([manager fileExistsAtPath:[replacement path]]) return fail(94, nil);
            printf("replacement=%s\n", replacementPath);
            puts("atomic_create=observed atomic_replace=observed replacement_sentinel=observed");
            return 0;
        }
    }
    """#

    private static let probeSource = #"""
    #include <arpa/inet.h>
    #include <errno.h>
    #include <fcntl.h>
    #include <libproc.h>
    #include <stdio.h>
    #include <string.h>
    #include <sys/proc_info.h>
    #include <sys/socket.h>
    #include <unistd.h>

    static int permission_denied(int value) { return value == EPERM || value == EACCES; }
    int main(int argc, char **argv) {
        if (argc != 4) return 60;
        struct proc_bsdinfo self_info = {0}, parent_info = {0};
        int count = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &self_info, sizeof(self_info));
        if (count != (int)sizeof(self_info) || self_info.pbi_pid != (unsigned)getpid()) {
            fprintf(stderr, "self metadata unavailable: size=%d errno=%d\n", count, errno); return 61;
        }
        errno = 0;
        count = proc_pidinfo(getppid(), PROC_PIDTBSDINFO, 0, &parent_info, sizeof(parent_info));
        int parent_error = errno;
        if (count > 0 || !permission_denied(parent_error)) {
            fprintf(stderr, "parent metadata was not denied: size=%d errno=%d\n", count, parent_error); return 62;
        }
        const char expected[] = "inside-sandbox\n";
        char contents[64] = {0};
        int fd = open(argv[1], O_RDONLY);
        if (fd < 0) return 63;
        ssize_t bytes = read(fd, contents, sizeof(contents));
        close(fd);
        if (bytes != (ssize_t)(sizeof(expected) - 1) || memcmp(contents, expected, sizeof(expected) - 1) != 0) return 64;
        errno = 0;
        fd = open(argv[2], O_RDONLY);
        int read_error = errno;
        if (fd >= 0) { close(fd); return 65; }
        if (!permission_denied(read_error)) return 66;
        errno = 0;
        fd = open(argv[3], O_WRONLY | O_CREAT | O_EXCL, 0600);
        int write_error = errno;
        if (fd >= 0) { close(fd); return 67; }
        if (!permission_denied(write_error)) return 68;
        // A local ephemeral bind sends no packets and never listens or contacts a peer.
        errno = 0;
        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            if (!permission_denied(errno)) return 69;
        } else {
            struct sockaddr_in address = {0};
            address.sin_len = sizeof(address);
            address.sin_family = AF_INET;
            address.sin_port = 0;
            address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            errno = 0;
            int result = bind(fd, (struct sockaddr *)&address, sizeof(address));
            int network_error = errno;
            close(fd);
            if (result != -1 || !permission_denied(network_error)) return 70;
        }
        puts("self=observed parent=denied inside=observed sibling=denied outside_write=denied loopback_bind=denied");
        return 0;
    }
    """#
}
#endif
