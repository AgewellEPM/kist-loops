import XCTest
@testable import AgentCore

final class SMLWorkflowOpenAPIImporterTests: XCTestCase {
    func testImportProducesExactCapabilityProposalPinnedEndpointsAndValidWrappers() throws {
        let result = try SMLWorkflowOpenAPIImporter.importDocument(
            Data(Self.petstore.utf8),
            apiID: "petstore",
            sourceReference: "petstore.openapi.json")

        XCTAssertEqual(
            result.proposedCatalog.toolCapabilities,
            ["getPet", "updatePet"])
        XCTAssertTrue(result.proposedCatalog.reviewRequired)
        XCTAssertEqual(
            result.endpointBundle.endpoints.map(\.capability),
            ["getPet", "updatePet"])
        XCTAssertEqual(result.endpointBundle.sourceDigest.count, 64)

        let get = try XCTUnwrap(result.endpointBundle.endpoints.first {
            $0.capability == "getPet"
        })
        XCTAssertEqual(get.method, .get)
        XCTAssertEqual(get.servers, [
            SMLHTTPServerSpec(
                scheme: "https", host: "api.example.test", basePath: "/v1"),
        ])
        XCTAssertEqual(get.pathTemplate, "/pets/{petId}")
        XCTAssertEqual(
            get.parameters.map { "\($0.location.rawValue):\($0.name)" },
            ["path:petId", "query:tags"])
        XCTAssertNil(get.requestBody)
        XCTAssertEqual(
            get.authentication.first?.schemes.first?.credentialID,
            "petstore.apiKey")

        let update = try XCTUnwrap(result.endpointBundle.endpoints.first {
            $0.capability == "updatePet"
        })
        XCTAssertEqual(update.method, .post)
        XCTAssertEqual(update.requestBody?.valueType, .object)
        XCTAssertEqual(update.requestBody?.required, true)
        XCTAssertEqual(update.timeoutSeconds, 12)
        XCTAssertEqual(update.maximumResponseBytes, 65_536)

        XCTAssertEqual(result.wrapperWorkflows.count, 2)
        for workflow in result.wrapperWorkflows {
            XCTAssertTrue(SMLWorkflowValidator.validate(workflow).isValid)
            XCTAssertEqual(workflow.source.kind, .openAPI)
            let request = try XCTUnwrap(workflow.instructions.first)
            XCTAssertEqual(request.op, .callTool)
            XCTAssertTrue(result.proposedCatalog.toolCapabilities.contains(
                try XCTUnwrap(request.capability)))
            XCTAssertFalse(
                workflow.instructions.contains { $0.op == .waitApproval },
                "durable launch owns the policy-specific, idempotent P1 gate transform")
        }
    }

    func testUnresolvedReferenceFailsClosedBeforeAnyPartialImport() {
        let source = Self.petstore.replacingOccurrences(
            of: "#/components/parameters/PetID",
            with: "#/components/parameters/DoesNotExist")

        XCTAssertThrowsError(try SMLWorkflowOpenAPIImporter.importDocument(
            Data(source.utf8), apiID: "petstore", sourceReference: "petstore.json"
        )) { error in
            guard case SMLWorkflowOpenAPIImportError.unresolvedReference = error else {
                return XCTFail("expected unresolved reference, got \(error)")
            }
        }
    }

    func testExternalReferenceAndRemotePlaintextServerFailClosed() {
        let external = Self.petstore.replacingOccurrences(
            of: "#/components/parameters/PetID",
            with: "https://schemas.example.test/parameters.json#/PetID")
        XCTAssertThrowsError(try SMLWorkflowOpenAPIImporter.importDocument(
            Data(external.utf8), apiID: "petstore", sourceReference: "petstore.json"
        )) { error in
            guard case SMLWorkflowOpenAPIImportError.unsupportedReference = error else {
                return XCTFail("expected unsupported reference, got \(error)")
            }
        }

        let plaintext = Self.petstore.replacingOccurrences(
            of: "https://api.example.test/v1",
            with: "http://api.example.test/v1")
        XCTAssertThrowsError(try SMLWorkflowOpenAPIImporter.importDocument(
            Data(plaintext.utf8), apiID: "petstore", sourceReference: "petstore.json"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("remote HTTP is refused"))
        }
    }

    func testVersionMustBeAnExactSupportedOpenAPIVersion() {
        for version in ["3.1.", "3.1.preview", "3.2.0", "31.0"] {
            let source = Self.petstore.replacingOccurrences(of: "3.1.0", with: version)
            XCTAssertThrowsError(try SMLWorkflowOpenAPIImporter.importDocument(
                Data(source.utf8), apiID: "petstore", sourceReference: "petstore.json"
            ), "\(version) must not pass as OpenAPI 3.0.x or 3.1.x")
        }
    }

    func testQueryAPIKeyAndTraceAreNeverImported() {
        let querySecret = Self.petstore.replacingOccurrences(
            of: #""in": "header""#,
            with: #""in": "query""#)
        XCTAssertThrowsError(try SMLWorkflowOpenAPIImporter.importDocument(
            Data(querySecret.utf8), apiID: "petstore", sourceReference: "petstore.json"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("query strings or cookies"))
        }

        let trace = """
        {
          "openapi": "3.1.0",
          "info": {"title": "Trace", "version": "1"},
          "servers": [{"url": "https://api.example.test"}],
          "paths": {
            "/debug": {
              "trace": {"operationId": "traceDebug", "responses": {"200": {"description": "ok"}}}
            }
          }
        }
        """
        XCTAssertThrowsError(try SMLWorkflowOpenAPIImporter.importDocument(
            Data(trace.utf8), apiID: "trace", sourceReference: "trace.json"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("TRACE"))
        }
    }

    func testDuplicateOperationIDAndMissingPathParameterAreRejected() {
        let duplicate = Self.petstore.replacingOccurrences(of: "updatePet", with: "getPet")
        XCTAssertThrowsError(try SMLWorkflowOpenAPIImporter.importDocument(
            Data(duplicate.utf8), apiID: "petstore", sourceReference: "petstore.json"
        )) { error in
            XCTAssertEqual(
                error as? SMLWorkflowOpenAPIImportError,
                .duplicateOperationID("getPet"))
        }

        let missingPathParameter = Self.petstore.replacingOccurrences(
            of: ##""parameters": [{"$ref": "#/components/parameters/PetID"}],"##,
            with: #""parameters": [],"#)
        XCTAssertThrowsError(try SMLWorkflowOpenAPIImporter.importDocument(
            Data(missingPathParameter.utf8), apiID: "petstore",
            sourceReference: "petstore.json"
        )) { error in
            XCTAssertTrue(String(describing: error).contains(
                "path placeholders do not exactly match"))
        }
    }

    func testDuplicateJSONKeyAndUnknownOperationMemberAreRejected() {
        let duplicate = Self.petstore.replacingOccurrences(
            of: #""operationId": "getPet""#,
            with: #""operationId": "getPet", "operationId": "shadow""#)
        XCTAssertThrowsError(try SMLWorkflowOpenAPIImporter.importDocument(
            Data(duplicate.utf8), apiID: "petstore", sourceReference: "petstore.json"
        )) { error in
            guard case SMLWireCodecError.duplicateKey = error else {
                return XCTFail("expected strict duplicate-key failure, got \(error)")
            }
        }

        let unknown = Self.petstore.replacingOccurrences(
            of: #""operationId": "getPet""#,
            with: #""operationId": "getPet", "silentMagic": true"#)
        XCTAssertThrowsError(try SMLWorkflowOpenAPIImporter.importDocument(
            Data(unknown.utf8), apiID: "petstore", sourceReference: "petstore.json"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("unknown member"))
        }
    }

    func testOAuthScopesAreDeclaredAndSecuritySchemeShapesAreStrict() throws {
        let imported = try SMLWorkflowOpenAPIImporter.importDocument(
            Data(Self.oauth.utf8), apiID: "oauth", sourceReference: "oauth.json")
        let scheme = try XCTUnwrap(
            imported.endpointBundle.endpoints.first?.authentication.first?.schemes.first)
        XCTAssertEqual(scheme.kind, .oauth2Bearer)
        XCTAssertEqual(scheme.requiredScopes, ["items.read"])

        let undeclared = Self.oauth.replacingOccurrences(
            of: #""items.read": "read items""#,
            with: #""items.write": "write items""#)
        XCTAssertThrowsError(try SMLWorkflowOpenAPIImporter.importDocument(
            Data(undeclared.utf8), apiID: "oauth", sourceReference: "oauth.json"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("undeclared OAuth scope"))
        }

        let unknown = Self.oauth.replacingOccurrences(
            of: #""type": "oauth2", "flows""#,
            with: #""type": "oauth2", "secretShortcut": true, "flows""#)
        XCTAssertThrowsError(try SMLWorkflowOpenAPIImporter.importDocument(
            Data(unknown.utf8), apiID: "oauth", sourceReference: "oauth.json"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("unknown member"))
        }
    }

    func testMissingResponsesAndUnknownRequestMediaMemberFailClosed() {
        let missingResponses = Self.petstore.replacingOccurrences(
            of: #""responses": {"200": {"description": "ok"}}"#,
            with: #""responses_missing": {}"#)
        XCTAssertThrowsError(try SMLWorkflowOpenAPIImporter.importDocument(
            Data(missingResponses.utf8), apiID: "petstore", sourceReference: "petstore.json"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("responses"))
        }

        let unknownMediaMember = Self.petstore.replacingOccurrences(
            of: #"{"schema": {"type": "object"}}"#,
            with: #"{"schema": {"type": "object"}, "execute": true}"#)
        XCTAssertThrowsError(try SMLWorkflowOpenAPIImporter.importDocument(
            Data(unknownMediaMember.utf8), apiID: "petstore", sourceReference: "petstore.json"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("unknown member"))
        }
    }

    private static let petstore = """
    {
      "openapi": "3.1.0",
      "info": {"title": "Pet Store", "version": "2026-09"},
      "servers": [{"url": "https://api.example.test/v1/"}],
      "security": [{"apiKey": []}],
      "paths": {
        "/pets/{petId}": {
          "parameters": [{"$ref": "#/components/parameters/PetID"}],
          "get": {
            "operationId": "getPet",
            "parameters": [
              {
                "name": "tags",
                "in": "query",
                "schema": {"type": "array", "items": {"type": "string"}}
              }
            ],
            "responses": {"200": {"description": "ok"}}
          },
          "post": {
            "operationId": "updatePet",
            "x-kist-timeout-seconds": 12,
            "x-kist-maximum-response-bytes": 65536,
            "requestBody": {
              "required": true,
              "content": {
                "application/json": {"schema": {"type": "object"}}
              }
            },
            "responses": {"200": {"description": "ok"}}
          }
        }
      },
      "components": {
        "parameters": {
          "PetID": {
            "name": "petId",
            "in": "path",
            "required": true,
            "schema": {"type": "string"}
          }
        },
        "securitySchemes": {
          "apiKey": {"type": "apiKey", "in": "header", "name": "X-Pet-Key"}
        }
      }
    }
    """

    private static let oauth = """
    {
      "openapi": "3.1.0",
      "info": {"title": "OAuth API", "version": "1"},
      "servers": [{"url": "https://api.example.test"}],
      "security": [{"oauth": ["items.read"]}],
      "paths": {
        "/items": {
          "get": {
            "operationId": "items.read",
            "responses": {"200": {"description": "ok"}}
          }
        }
      },
      "components": {
        "securitySchemes": {
          "oauth": {
            "type": "oauth2", "flows": {
              "clientCredentials": {
                "tokenUrl": "https://auth.example.test/token",
                "scopes": {"items.read": "read items"}
              }
            }
          }
        }
      }
    }
    """
}
