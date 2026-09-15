import XCTest
import Foundation
@testable import Kist
@testable import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class KistOperatorActionTests: XCTestCase {
    func testExclusiveArgumentsCannotEnableGenericAuthorityOrEscapeJSONMode() {
        let valid = KistOptions.parse(["--operator-action"])
        XCTAssertTrue(valid.operatorAction)
        XCTAssertTrue(valid.operatorActionArgumentsValid)
        for extra in [["--help"], ["--version"], ["--operator-action"], ["--auto"],
                      ["--enable-computer-use"], ["--project", "/"], ["--provider", "other"],
                      ["--list-learning-sync"], ["do something"], ["--unknown-flag"]] {
            let options = KistOptions.parse(["--operator-action"] + extra)
            XCTAssertTrue(options.operatorAction)
            XCTAssertFalse(options.operatorActionArgumentsValid, "\(extra)")
            XCTAssertFalse(options.showHelp)
            XCTAssertFalse(options.auto)
            XCTAssertFalse(options.allowShell)
            XCTAssertFalse(options.enableComputerUse)
            XCTAssertNil(options.goal)
            XCTAssertNil(options.providerId)
            XCTAssertTrue(options.optionErrors.isEmpty, "The broker must render its own JSON error")
        }
    }

    func testInvalidArgumentsDoNotReadInputOrLookUpAuthority() async throws {
        var touchedInput = false
        var touchedAuthority = false
        let response = await KistOperatorActionProtocol.response(
            options: KistOptions.parse(["--operator-action", "--auto"]),
            readInput: { touchedInput = true; return Data("{}".utf8) },
            authorityDirectory: { touchedAuthority = true; return URL(fileURLWithPath: "/") })
        XCTAssertFalse(touchedInput)
        XCTAssertFalse(touchedAuthority)
        let wire = KistOperatorActionProtocol.wireResponse(response)
        XCTAssertEqual(wire.exitCode, 2)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: wire.data) as? [String: Any])
        XCTAssertEqual(body["accepted"] as? Bool, false)
        XCTAssertEqual(body["schema_version"] as? Int, 1)
        XCTAssertEqual(body["disposition"] as? String, "denied")
    }

    func testInputErrorsRemainFixedJSONAndDoNotReadAuthority() async throws {
        var touchedAuthority = false
        let response = await KistOperatorActionProtocol.response(
            options: KistOptions.parse(["--operator-action"]),
            readInput: { throw KistOperatorActionProtocol.InputFailure.timedOut },
            authorityDirectory: { touchedAuthority = true; return URL(fileURLWithPath: "/") })
        XCTAssertFalse(touchedAuthority)
        XCTAssertEqual(response.exitCode, 2)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: KistOperatorActionProtocol.wireResponse(response).data) as? [String: Any])
        XCTAssertEqual(body["accepted"] as? Bool, false)
        XCTAssertEqual(body["disposition"] as? String, "denied")
    }

    func testReaderAcceptsAnExactLimitOnlyAfterEOF() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        let expected = Data(repeating: 0x20, count: 64)
        try pipe.fileHandleForWriting.write(contentsOf: expected)
        try pipe.fileHandleForWriting.close()
        let received = try KistOperatorActionProtocol.readInput(
            descriptor: pipe.fileHandleForReading.fileDescriptor, maximumBytes: 64,
            timeoutMilliseconds: 100)
        XCTAssertEqual(received, expected)
    }

    func testReaderRefusesOversizeBeforeCallerClosesPipe() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 0x20, count: 65))
        XCTAssertThrowsError(try KistOperatorActionProtocol.readInput(
            descriptor: pipe.fileHandleForReading.fileDescriptor, maximumBytes: 64,
            timeoutMilliseconds: 100)) {
                XCTAssertEqual($0 as? KistOperatorActionProtocol.InputFailure, .oversized)
            }
    }

    func testPartialInputWithOpenWriterHasARealDeadline() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("{}".utf8))
        let start = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try KistOperatorActionProtocol.readInput(
            descriptor: pipe.fileHandleForReading.fileDescriptor, timeoutMilliseconds: 30)) {
                XCTAssertEqual($0 as? KistOperatorActionProtocol.InputFailure, .timedOut)
            }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        XCTAssertLessThan(elapsed, 1)
    }

    func testEmptyEOFAndInvalidDescriptorFailClosed() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        try pipe.fileHandleForWriting.close()
        XCTAssertThrowsError(try KistOperatorActionProtocol.readInput(
            descriptor: pipe.fileHandleForReading.fileDescriptor, timeoutMilliseconds: 100)) {
                XCTAssertEqual($0 as? KistOperatorActionProtocol.InputFailure, .empty)
            }
        XCTAssertThrowsError(try KistOperatorActionProtocol.readInput(descriptor: -1)) {
            XCTAssertEqual($0 as? KistOperatorActionProtocol.InputFailure, .invalidDescriptor)
        }
    }

    func testMalformedRequestDoesNotCreateAuthorityDirectory() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kist-operator-action-" + UUID().uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let response = await KistOperatorActionProtocol.response(
            options: KistOptions.parse(["--operator-action"]),
            readInput: { Data("{malformed".utf8) },
            authorityDirectory: { root })
        XCTAssertEqual(response.exitCode, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testAuthorityRootHasNoProjectOrRequestSelection() throws {
        let directory = try KistOperatorActionProtocol.authorityDirectory()
        XCTAssertTrue(directory.path.hasSuffix("/Library/Application Support/BuildRoulette/Worker/authorities"))
        XCTAssertTrue(directory.path.hasPrefix("/"))
        XCTAssertFalse(directory.path.contains("/../"))
    }

    func testOversizedResponseBecomesDecodableUnknownWithoutReplayingOrClaimingAcceptance() throws {
        let oversized = OperatorActionResponse.make(.observed, code: "observation", message: "Observed",
            now: Date(), content: String(repeating: "x", count: KistOperatorActionProtocol.maximumResponseBytes))
        let wire = KistOperatorActionProtocol.wireResponse(oversized)
        XCTAssertEqual(wire.exitCode, 3)
        XCTAssertLessThanOrEqual(wire.data.count, KistOperatorActionProtocol.maximumResponseBytes)
        let result = try JSONDecoder().decode(OperatorActionResponse.self, from: wire.data)
        XCTAssertEqual(result.disposition, .unknown)
        XCTAssertFalse(result.accepted)
        XCTAssertNil(result.content)
        XCTAssertTrue(result.message.contains("do not replay automatically"))
    }

    func testExecutableDirectProtocolAndMixedFlagsReturnOneDeniedJSONEnvelope() throws {
        // Select the product beside this test runner, including a caller-selected scratch path.
        // Falling back to the source tree's older executable could falsely qualify stale code.
        var candidates: [URL] = []
        for start in [Bundle(for: KistOperatorActionTests.self).bundleURL,
                      URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()] {
            var directory = start
            for _ in 0..<6 {
                candidates.append(directory.appendingPathComponent("kist"))
                directory.deleteLastPathComponent()
            }
        }
        let executable = try XCTUnwrap(candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }, "The current Swift test build must include its matching Kist executable")
        // The sole option reaches the bounded input gate; companions are refused
        // before input or any generic runtime/provider path can run.
        let cases: [(arguments: [String], expectedCode: String)] = [
            (["--operator-action"], "stdin_empty"),
            (["--operator-action", "--version"], "exclusive_option_required"),
            (["--operator-action", "--help"], "exclusive_option_required"),
            (["--operator-action", "--auto", "--enable-computer-use"], "exclusive_option_required"),
            (["--operator-action", "--provider", "missing-provider", "do something"], "exclusive_option_required"),
        ]
        for fixture in cases {
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            // Use an actual EOF-terminated pipe: Darwin polling of the null-device
            // handle does not exercise the protocol's readable pipe EOF branch.
            try input.fileHandleForWriting.close()
            defer { try? input.fileHandleForReading.close() }
            process.executableURL = executable
            process.arguments = fixture.arguments
            process.standardInput = input.fileHandleForReading
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning {
                process.terminate()
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                XCTFail("Deterministic broker invocation timed out")
                return
            }
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 2)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(
                with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
            XCTAssertEqual(body["accepted"] as? Bool, false)
            XCTAssertEqual(body["disposition"] as? String, "denied")
            XCTAssertEqual(body["code"] as? String, fixture.expectedCode)
            XCTAssertTrue(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }
    }
}
