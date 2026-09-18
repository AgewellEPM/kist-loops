import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension KistRunner {
    /// This path has no provider registry, tool discovery, memory, or inferred operator grant.
    /// The worker must already have published the exact host authority consumed by AgentCore.
    static func runOperatorAction(_ opts: KistOptions) async -> Int32 {
        let response = await KistOperatorActionProtocol.response(
            options: opts,
            readInput: { try KistOperatorActionProtocol.readInput() },
            authorityDirectory: { try KistOperatorActionProtocol.authorityDirectory() })
        let wire = KistOperatorActionProtocol.wireResponse(response)
        FileHandle.standardOutput.write(wire.data)
        return wire.exitCode
    }
}

enum KistOperatorActionProtocol {
    /// Raw arguments enter the deterministic protocol directly, before the ordinary
    /// runner can initialize providers, MCP discovery, or interactive runtime state.
    static func run(arguments: [String]) async -> Int32 {
        await KistRunner.runOperatorAction(KistOptions.parse(arguments))
    }

    enum InputFailure: String, Error {
        case invalidDescriptor = "stdin_unavailable"
        case interactive = "stdin_requires_pipe"
        case timedOut = "stdin_timeout"
        case oversized = "stdin_too_large"
        case readFailed = "stdin_read_failed"
        case empty = "stdin_empty"
        case accountHomeUnavailable = "account_home_unavailable"
    }

    static let maximumResponseBytes = 256 * 1_024

    /// There is deliberately no command-line or environment override for this root.
    /// Resolve the effective user's account record instead of trusting a child-supplied HOME.
    static func authorityDirectory() throws -> URL {
        guard getuid() == geteuid() else { throw InputFailure.accountHomeUnavailable }
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16 * 1_024)
        let accountHome: String? = buffer.withUnsafeMutableBufferPointer { storage in
            guard getpwuid_r(geteuid(), &record, storage.baseAddress!, storage.count, &result) == 0,
                  result != nil, let home = record.pw_dir else { return nil }
            return String(validatingUTF8: home)
        }
        guard let accountHome, accountHome.hasPrefix("/"), accountHome != "/" else {
            throw InputFailure.accountHomeUnavailable
        }
        return URL(fileURLWithPath: accountHome, isDirectory: true)
            .appendingPathComponent("Library/Application Support/BuildRoulette/Worker/authorities",
                                    isDirectory: true)
    }

    /// Read a single EOF-terminated JSON request with both a byte cap and a monotonic deadline.
    /// Unlike readDataToEndOfFile this cannot hang when a caller leaves its input pipe open.
    static func readInput(
        descriptor: Int32 = STDIN_FILENO,
        maximumBytes: Int = OperatorActionHost.maximumRequestBytes,
        timeoutMilliseconds: Int = 5_000
    ) throws -> Data {
        guard descriptor >= 0, maximumBytes > 0, maximumBytes <= OperatorActionHost.maximumRequestBytes,
              timeoutMilliseconds > 0, timeoutMilliseconds <= 5_000 else {
            throw InputFailure.invalidDescriptor
        }
        guard isatty(descriptor) == 0 else { throw InputFailure.interactive }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw InputFailure.timedOut }
            let remaining = Int32(max(1, (deadline - now + 999_999) / 1_000_000))
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, remaining)
            if ready == 0 { throw InputFailure.timedOut }
            if ready < 0 {
                if errno == EINTR { continue }
                throw InputFailure.readFailed
            }
            guard item.revents & Int16(POLLNVAL | POLLERR) == 0 else {
                throw InputFailure.invalidDescriptor
            }
            guard item.revents & Int16(POLLIN | POLLHUP) != 0 else { continue }
            let count = read(descriptor, &buffer, min(buffer.count, maximumBytes + 1 - data.count))
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw InputFailure.readFailed
            }
            if count == 0 {
                guard !data.isEmpty else { throw InputFailure.empty }
                return data
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw InputFailure.oversized }
        }
    }

    static func response(
        options: KistOptions,
        readInput: () throws -> Data,
        authorityDirectory: () throws -> URL
    ) async -> OperatorActionResponse {
        guard options.operatorAction, options.operatorActionArgumentsValid else {
            return .denied(code: "exclusive_option_required",
                           message: "Use --operator-action alone with one JSON request on stdin.")
        }
        do {
            let data = try readInput()
            guard !data.isEmpty, data.count <= OperatorActionHost.maximumRequestBytes else {
                return .denied(code: "invalid_stdin_size", message: "Request size is outside the protocol limit.")
            }
            let directory = try authorityDirectory()
            return await OperatorActionHost.execute(requestData: data, authorityDirectory: directory)
        } catch let failure as InputFailure {
            return .denied(code: failure.rawValue, message: "Host action input was refused before execution.")
        } catch {
            // Never leak request text, credentials, filesystem details, or a subprocess error.
            return .denied(code: "host_input_unavailable", message: "Host action input is unavailable.")
        }
    }

    static func wireResponse(_ response: OperatorActionResponse) -> (data: Data, exitCode: Int32) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if var data = try? encoder.encode(response), data.count < maximumResponseBytes {
            data.append(0x0a)
            return (data, response.exitCode)
        }
        // An action might already have happened. A failed projection must not look retryable or
        // accepted, and this static envelope itself cannot fail JSON encoding.
        let observedAt = ISO8601DateFormatter().string(from: Date())
        return (Data("{\"accepted\":false,\"code\":\"response_unavailable\",\"disposition\":\"unknown\",\"evidence\":{},\"message\":\"Action outcome is unavailable; do not replay automatically.\",\"observed_at\":\"\(observedAt)\",\"schema_version\":1}\n".utf8), 3)
    }
}
