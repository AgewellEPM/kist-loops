import XCTest
@testable import Kist
@testable import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class KistSMLOpenAPIImportTests: XCTestCase {
    func testOptionsExposeDedicatedImportModeAndKeepItMutuallyExclusive() {
        let options = KistOptions.parse([
            "--sml-import-openapi", "specs/inventory.openapi.json",
            "--sml-api-id", "inventory",
            "--sml-out", "staging",
        ])
        XCTAssertEqual(options.smlOpenAPIImport, "specs/inventory.openapi.json")
        XCTAssertEqual(options.smlOpenAPIID, "inventory")
        XCTAssertEqual(options.smlRuntimeOutputDirectory, "staging")
        XCTAssertTrue(options.optionErrors.isEmpty)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-import-openapi <openapi.json>"))

        let alias = KistOptions.parse([
            "--sml-openapi-import", "specs/inventory.openapi.json",
        ])
        XCTAssertEqual(alias.smlOpenAPIImport, "specs/inventory.openapi.json")

        let conflict = KistOptions.parse([
            "--sml-import-openapi", "spec.json",
            "--sml-runtime-serve", "runtime.json",
        ])
        XCTAssertTrue(conflict.optionErrors.contains {
            $0.contains("--sml-import-openapi conflicts with --sml-runtime-serve")
        })
        XCTAssertTrue(KistOptions.parse(["--sml-api-id", "inventory"]).optionErrors.contains {
            $0.contains("--sml-api-id requires --sml-import-openapi")
        })
    }

    func testImportCreatesOwnerOnlyInertArtifactsAndRunnableSourceSet() async throws {
        let root = try makeProject(with: Self.inventory)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try KistRunner.importSMLOpenAPI(
            sourcePath: "specs/inventory.openapi.json",
            projectRoot: root.path
        )

        XCTAssertEqual(manifest.apiID, "inventory")
        XCTAssertEqual(manifest.capabilities, ["inventory.get"])
        XCTAssertEqual(manifest.requiredCredentialIDs, ["inventory.serviceToken"])
        XCTAssertTrue(manifest.reviewRequired)
        XCTAssertFalse(manifest.catalogModified)
        XCTAssertTrue(manifest.durableApprovalGating)
        XCTAssertTrue(manifest.files.allSatisfy(\.created))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".kist/sml/catalog.json").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".kist/sml/http-auth.json").path))

        for file in manifest.files {
            let url = root.appendingPathComponent(file.relativePath)
            var status = stat()
            XCTAssertEqual(lstat(url.path, &status), 0)
            XCTAssertEqual(status.st_mode & mode_t(0o777), mode_t(0o600))
            XCTAssertEqual(status.st_nlink, 1)
            XCTAssertEqual(Int(status.st_size), file.byteCount)
        }
        let registry = try SMLHTTPEndpointRegistry.load(projectRoot: root.path)
        XCTAssertEqual(Set(registry.endpoints.keys), ["inventory.get"])

        let export = try await KistRunner.makeSMLRuntimeHostExport(
            sourcePath: manifest.workflowSourceSet,
            projectRoot: root.path
        )
        XCTAssertEqual(export.sourceFormat, .runtimeSourceSet)
        XCTAssertEqual(export.runtimePackage.normalizedWorkflows.map(\.source.kind), [.openAPI])
    }

    func testRunnerDispatchesOpenAPIImportWithoutConstructingAnAgentHost() async throws {
        let root = try makeProject(with: Self.inventory)
        defer { try? FileManager.default.removeItem(at: root) }
        let options = KistOptions.parse([
            "--project", root.path,
            "--sml-import-openapi", "specs/inventory.openapi.json",
            "--sml-api-id", "inventory",
        ])
        XCTAssertTrue(options.optionErrors.isEmpty)

        let exitCode = await KistRunner.run(options)
        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                ".kist/sml/http-workflows/inventory.sources.json").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".kist/sml/catalog.json").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".kist/sml/http-auth.json").path))
    }

    func testImportIsIdempotentAndNeverOverwritesDifferentArtifacts() throws {
        let root = try makeProject(with: Self.inventory)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try KistRunner.importSMLOpenAPI(
            sourcePath: "specs/inventory.openapi.json", projectRoot: root.path)
        let endpoint = root.appendingPathComponent(first.endpointBundle)
        let original = try Data(contentsOf: endpoint)

        let second = try KistRunner.importSMLOpenAPI(
            sourcePath: "specs/inventory.openapi.json", projectRoot: root.path)
        XCTAssertTrue(second.files.allSatisfy { !$0.created })

        let changed = Self.inventory.replacingOccurrences(
            of: "Inventory API", with: "Different Inventory API")
        try Data(changed.utf8).write(
            to: root.appendingPathComponent("specs/inventory.openapi.json"),
            options: .atomic)
        XCTAssertThrowsError(try KistRunner.importSMLOpenAPI(
            sourcePath: "specs/inventory.openapi.json", projectRoot: root.path))
        XCTAssertEqual(try Data(contentsOf: endpoint), original)
    }

    func testImportRefusesSourceSymlinkAndOutputEscapeWithoutWritingArtifacts() throws {
        let root = try makeProject(with: Self.inventory)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-openapi-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: external) }
        try Data(Self.inventory.utf8).write(to: external)
        let symlink = root.appendingPathComponent("specs/link.json")
        try FileManager.default.createSymbolicLink(
            at: symlink, withDestinationURL: external)

        XCTAssertThrowsError(try KistRunner.importSMLOpenAPI(
            sourcePath: "specs/link.json", projectRoot: root.path))
        XCTAssertThrowsError(try KistRunner.importSMLOpenAPI(
            sourcePath: "specs/inventory.openapi.json",
            outputDirectory: "../outside",
            projectRoot: root.path
        )) { error in
            guard case SMLOpenAPIImportCLIError.invalidOutputDirectory = error else {
                return XCTFail("expected output confinement error, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".kist").path))
    }

    func testImportedHTTPWorkflowRequiresApprovalAndDispatchesExactlyOnce() async throws {
        let listener = try makeOpenAPIHTTPListener()
        defer { close(listener.fd) }
        let document = Self.inventory.replacingOccurrences(
            of: "https://inventory.example.test/v1",
            with: "http://127.0.0.1:\(listener.port)/v1")
        let root = try makeProject(with: document)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try KistRunner.importSMLOpenAPI(
            sourcePath: "specs/inventory.openapi.json", projectRoot: root.path)
        try writeDurableHTTPHostConfiguration(root: root)

        try await KistRunner.withSMLRuntimeHostLaunch(
            sourcePath: manifest.workflowSourceSet,
            projectRoot: root.path,
            mode: .durable,
            actor: "sml-runtime-exporter"
        ) { host in
            let stack = try await KistRunner.makeSMLRuntimeCapabilityStack(
                host: host, projectRoot: root.path, actor: "sml-runtime-exporter")
            let workflowID = try XCTUnwrap(host.runtimePackage.workflowIDs.first)
            let session = try host.launch.app.replSession(workflowID: workflowID)

            let started = try await session.submit(
                #"start TASK-HTTP-IMPORT {"path_itemId":"sku-1"}"#)
            XCTAssertEqual(started.result?.task?.status, .waitingApproval)
            let parked = await stack.pump.drain()
            XCTAssertTrue(parked.dispatched.isEmpty)
            XCTAssertFalse(
                openAPIHTTPListenerHasPendingConnection(
                    listener.fd, timeoutMilliseconds: 100),
                "an imported HTTP operation must send zero bytes before human approval")

            let beforeApproval = try await host.durableEnvironment?.store.load()
            let task = try XCTUnwrap(beforeApproval?.tasks["TASK-HTTP-IMPORT"])
            let approved = try await session.submit(
                "approve TASK-HTTP-IMPORT {\"task_revision\":\(task.revision)}")
            XCTAssertEqual(approved.result?.task?.status, .waitingCapability)

            let response = Data(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    .appending("Content-Length: 15\r\nConnection: close\r\n\r\n")
                    .appending(#"{"stock":"yes"}"#).utf8)
            let serverTask = serveOneOpenAPIHTTPRequest(
                listener: listener.fd, response: response)
            let drained = await stack.pump.drain()
            let wireRequest = try await serverTask.value

            XCTAssertEqual(drained.dispatched, ["TASK-HTTP-IMPORT"])
            XCTAssertTrue(wireRequest.hasPrefix("GET /v1/inventory/sku-1 HTTP/1.1\r\n"))
            XCTAssertTrue(wireRequest.contains("Authorization: Bearer test-token"))
            let finished = try await host.durableEnvironment?.store.load()
            XCTAssertEqual(finished?.tasks["TASK-HTTP-IMPORT"]?.status, .completed)
            XCTAssertEqual(
                finished?.tasks["TASK-HTTP-IMPORT"]?.state["response_body"],
                .string(#"{"stock":"yes"}"#))

            let secondDrain = await stack.pump.drain()
            XCTAssertTrue(secondDrain.dispatched.isEmpty)
            XCTAssertFalse(
                openAPIHTTPListenerHasPendingConnection(
                    listener.fd, timeoutMilliseconds: 100),
                "a completed durable claim must never replay the HTTP request")
        }
    }

    private func writeDurableHTTPHostConfiguration(root: URL) throws {
        let sml = root.appendingPathComponent(".kist/sml", isDirectory: true)
        try FileManager.default.createDirectory(at: sml, withIntermediateDirectories: true)
        let catalog = sml.appendingPathComponent("catalog.json")
        try Data(#"{"schema_version":1,"tool_capabilities":["inventory.get"],"approval_authorities":["host-operator"]}"#.utf8)
            .write(to: catalog)
        XCTAssertEqual(chmod(catalog.path, 0o600), 0)

        let authority = sml.appendingPathComponent("authority.json")
        try Data(#"{"schema_version":1,"actors":[{"id":"sml-runtime-exporter","roles":["workflow-agent"],"operations":["workflow.run","task.approve_request","task.claim_capability","task.record_step","task.watch","receipts.list","workflow.inspect"],"approval_authorities":["host-operator"]}]}"#.utf8)
            .write(to: authority)
        XCTAssertEqual(chmod(authority.path, 0o600), 0)

        let authentication = sml.appendingPathComponent("http-auth.json")
        try Data(#"{"schema_version":1,"credentials":{"inventory.serviceToken":{"value":"test-token"}}}"#.utf8)
            .write(to: authentication)
        XCTAssertEqual(chmod(authentication.path, 0o600), 0)
    }

    private func makeProject(with document: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-openapi-cli-\(UUID().uuidString)", isDirectory: true)
        let specs = root.appendingPathComponent("specs", isDirectory: true)
        try FileManager.default.createDirectory(at: specs, withIntermediateDirectories: true)
        try Data(document.utf8).write(
            to: specs.appendingPathComponent("inventory.openapi.json"))
        return root
    }

    private static let inventory = """
    {
      "openapi": "3.1.0",
      "info": {"title": "Inventory API", "version": "1.0.0"},
      "servers": [{"url": "https://inventory.example.test/v1"}],
      "security": [{"serviceToken": []}],
      "paths": {
        "/inventory/{itemId}": {
          "get": {
            "operationId": "inventory.get",
            "parameters": [{
              "name": "itemId",
              "in": "path",
              "required": true,
              "schema": {"type": "string"}
            }],
            "responses": {"200": {"description": "ok"}}
          }
        }
      },
      "components": {
        "securitySchemes": {
          "serviceToken": {"type": "http", "scheme": "bearer"}
        }
      }
    }
    """
}

private enum OpenAPIHTTPTestFailure: Error {
    case socket
    case bind
    case timeout
    case accept
    case read
    case write
}

private var openAPIHTTPSocketType: Int32 {
    #if canImport(Darwin)
    return SOCK_STREAM
    #else
    return Int32(SOCK_STREAM.rawValue)
    #endif
}

private func makeOpenAPIHTTPListener() throws -> (fd: Int32, port: UInt16) {
    let descriptor = socket(AF_INET, openAPIHTTPSocketType, 0)
    guard descriptor >= 0 else { throw OpenAPIHTTPTestFailure.socket }
    var address = sockaddr_in()
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(descriptor, 1) == 0 else {
        close(descriptor)
        throw OpenAPIHTTPTestFailure.bind
    }
    var result = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &result) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard named == 0 else {
        close(descriptor)
        throw OpenAPIHTTPTestFailure.bind
    }
    return (descriptor, UInt16(bigEndian: result.sin_port))
}

private func serveOneOpenAPIHTTPRequest(
    listener: Int32,
    response: Data
) -> Task<String, Error> {
    Task.detached {
        guard openAPIHTTPListenerHasPendingConnection(
            listener, timeoutMilliseconds: 5_000) else {
            throw OpenAPIHTTPTestFailure.timeout
        }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { throw OpenAPIHTTPTestFailure.accept }
        defer { close(client) }
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 2_048)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { throw OpenAPIHTTPTestFailure.read }
            request.append(contentsOf: buffer.prefix(Int(count)))
            guard request.count <= 64 * 1_024 else { throw OpenAPIHTTPTestFailure.read }
        }
        var offset = 0
        while offset < response.count {
            let written = response.withUnsafeBytes { bytes in
                write(client, bytes.baseAddress!.advanced(by: offset), response.count - offset)
            }
            guard written > 0 else { throw OpenAPIHTTPTestFailure.write }
            offset += written
        }
        guard let text = String(data: request, encoding: .utf8) else {
            throw OpenAPIHTTPTestFailure.read
        }
        return text
    }
}

private func openAPIHTTPListenerHasPendingConnection(
    _ listener: Int32,
    timeoutMilliseconds: Int32
) -> Bool {
    var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    return poll(&descriptor, 1, timeoutMilliseconds) > 0
}
