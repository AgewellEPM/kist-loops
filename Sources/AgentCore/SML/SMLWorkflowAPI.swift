import Foundation

public enum SMLWorkflowAPIMethod: String, Sendable, Codable, Equatable {
    case get = "GET"
    case post = "POST"
}

public struct SMLWorkflowAPIEndpoint: Sendable, Codable, Equatable {
    public let method: SMLWorkflowAPIMethod
    public let pathTemplate: String
    public let operationID: String
    public let action: SMLWorkflowControlAction
    public let summary: String
    public let bodyFields: [SMLWorkflowFieldDescriptor]

    public init(
        method: SMLWorkflowAPIMethod,
        pathTemplate: String,
        operationID: String,
        action: SMLWorkflowControlAction,
        summary: String,
        bodyFields: [SMLWorkflowFieldDescriptor] = []
    ) {
        self.method = method
        self.pathTemplate = pathTemplate
        self.operationID = operationID
        self.action = action
        self.summary = summary
        self.bodyFields = bodyFields
    }
}

public struct SMLWorkflowAPICatalog: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let basePath: String
    public let endpoints: [SMLWorkflowAPIEndpoint]

    public init(surface: SMLWorkflowSurface, basePath: String = "/v1") {
        let normalizedBase = basePath.hasSuffix("/")
            ? String(basePath.dropLast())
            : basePath
        self.workflowID = surface.workflowID
        self.workflowVersion = surface.workflowVersion
        self.basePath = normalizedBase
        let workflowPath = "\(normalizedBase)/workflows/\(surface.workflowID)"
        let taskPath = "\(workflowPath)/tasks/{task_id}"
        endpoints = [
            .init(method: .get, pathTemplate: workflowPath,
                  operationID: "describe_workflow", action: .describe,
                  summary: "Describe the exact admitted workflow surface"),
            .init(method: .post, pathTemplate: "\(workflowPath)/tasks",
                  operationID: "start_workflow_task", action: .start,
                  summary: "Start a task; body requires task_id and accepts input",
                  bodyFields: surface.inputs),
            .init(method: .get, pathTemplate: taskPath,
                  operationID: "watch_workflow_task", action: .watch,
                  summary: "Read a task projection"),
            .init(method: .post, pathTemplate: "\(taskPath)/approve",
                  operationID: "approve_workflow_task", action: .approve,
                  summary: "Approve the current task gate"),
            .init(method: .post, pathTemplate: "\(taskPath)/refuse",
                  operationID: "refuse_workflow_task", action: .refuse,
                  summary: "Refuse the current task gate"),
            .init(method: .post, pathTemplate: "\(taskPath)/rollback",
                  operationID: "rollback_workflow_task", action: .rollback,
                  summary: "Request terminal operator rollback"),
            .init(method: .get, pathTemplate: "\(taskPath)/receipts",
                  operationID: "list_workflow_task_receipts", action: .receipts,
                  summary: "List task receipts"),
        ]
    }
}

public struct SMLWorkflowAPIRequest: Sendable, Equatable {
    public let method: SMLWorkflowAPIMethod
    public let path: String
    public let body: SMLObject
    public let scope: SMLObject
    public let expectedState: SMLObject

    public init(
        method: SMLWorkflowAPIMethod,
        path: String,
        body: SMLObject = [:],
        scope: SMLObject = [:],
        expectedState: SMLObject = [:]
    ) {
        self.method = method
        self.path = path
        self.body = body
        self.scope = scope
        self.expectedState = expectedState
    }
}

public enum SMLWorkflowAPIError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidBasePath
    case invalidPath(String)
    case routeNotFound(method: String, path: String)
    case bodyNotAllowed
    case unknownBodyField(String)
    case missingBodyField(String)
    case invalidBodyField(String)

    public var description: String {
        switch self {
        case .invalidBasePath: return "workflow API base path must be an absolute literal path"
        case .invalidPath(let path): return "invalid workflow API path: \(path)"
        case .routeNotFound(let method, let path): return "workflow API route not found: \(method) \(path)"
        case .bodyNotAllowed: return "this workflow API endpoint does not accept a body"
        case .unknownBodyField(let field): return "unknown workflow API body field: \(field)"
        case .missingBodyField(let field): return "missing workflow API body field: \(field)"
        case .invalidBodyField(let field): return "invalid workflow API body field: \(field)"
        }
    }
}

/// Executable, transport-neutral router for one workflow. An HTTP host only has to authenticate the
/// request, decode bounded JSON into `SMLObject`, and provide authority; route logic remains shared.
public struct SMLWorkflowAPICompiler: Sendable {
    public let surface: SMLWorkflowSurface
    public let catalog: SMLWorkflowAPICatalog
    private let compiler: SMLWorkflowCommandCompiler

    public init(
        surface: SMLWorkflowSurface,
        actor: String,
        basePath: String = "/v1",
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) throws {
        guard Self.validBasePath(basePath) else { throw SMLWorkflowAPIError.invalidBasePath }
        self.surface = surface
        catalog = SMLWorkflowAPICatalog(surface: surface, basePath: basePath)
        compiler = SMLWorkflowCommandCompiler(
            surface: surface,
            actor: actor,
            commandID: commandID
        )
    }

    public func compile(
        _ request: SMLWorkflowAPIRequest,
        issuedAtEpoch: Double
    ) throws -> SMLCommandEnvelope {
        let segments = try pathSegments(request.path)
        let baseSegments = catalog.basePath.split(separator: "/").map(String.init)
        guard segments.starts(with: baseSegments) else {
            throw SMLWorkflowAPIError.routeNotFound(
                method: request.method.rawValue, path: request.path
            )
        }
        let tail = Array(segments.dropFirst(baseSegments.count))
        guard tail.count >= 2,
              tail[0] == "workflows",
              tail[1] == surface.workflowID else {
            throw SMLWorkflowAPIError.routeNotFound(
                method: request.method.rawValue, path: request.path
            )
        }

        if request.method == .get, tail.count == 2 {
            try requireEmptyBody(request.body)
            return try compiler.compile(
                action: .describe,
                scope: request.scope,
                expectedState: request.expectedState,
                issuedAtEpoch: issuedAtEpoch
            )
        }
        if request.method == .post, tail.count == 3, tail[2] == "tasks" {
            try requireKeys(request.body, allowed: ["task_id", "input"])
            guard case .string(let task)? = request.body["task_id"] else {
                throw SMLWorkflowAPIError.missingBodyField("task_id")
            }
            let input: SMLObject
            if let value = request.body["input"] {
                guard case .object(let object) = value else {
                    throw SMLWorkflowAPIError.invalidBodyField("input")
                }
                input = object
            } else {
                input = [:]
            }
            return try compiler.compile(
                action: .start,
                task: task,
                initialState: input,
                scope: request.scope,
                expectedState: request.expectedState,
                issuedAtEpoch: issuedAtEpoch
            )
        }
        guard tail.count >= 4, tail[2] == "tasks" else {
            throw SMLWorkflowAPIError.routeNotFound(
                method: request.method.rawValue, path: request.path
            )
        }
        let task = tail[3]
        try requireEmptyBody(request.body)
        let action: SMLWorkflowControlAction
        switch (request.method, Array(tail.dropFirst(4))) {
        case (.get, []): action = .watch
        case (.post, ["approve"]): action = .approve
        case (.post, ["refuse"]): action = .refuse
        case (.post, ["rollback"]): action = .rollback
        case (.get, ["receipts"]): action = .receipts
        default:
            throw SMLWorkflowAPIError.routeNotFound(
                method: request.method.rawValue, path: request.path
            )
        }
        return try compiler.compile(
            action: action,
            task: task,
            scope: request.scope,
            expectedState: request.expectedState,
            issuedAtEpoch: issuedAtEpoch
        )
    }

    private func pathSegments(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"),
              !path.contains("?"),
              !path.contains("#"),
              !path.contains("//"),
              !path.contains("%"),
              !path.split(separator: "/").contains("..") else {
            throw SMLWorkflowAPIError.invalidPath(path)
        }
        return path.split(separator: "/").map(String.init)
    }

    private func requireEmptyBody(_ body: SMLObject) throws {
        if !body.isEmpty { throw SMLWorkflowAPIError.bodyNotAllowed }
    }

    private func requireKeys(_ body: SMLObject, allowed: Set<String>) throws {
        if let unknown = body.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw SMLWorkflowAPIError.unknownBodyField(unknown)
        }
    }

    private static func validBasePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && !path.contains("?") && !path.contains("#")
            && !path.contains("//") && !path.contains("%")
            && path.split(separator: "/").allSatisfy {
                SMLValidationSupport.identifierIsValid(String($0), allowDot: false)
            }
    }
}

public struct SMLWorkflowAPIResponse: Sendable, Equatable {
    public let statusCode: Int
    public let command: SMLCommandEnvelope
    public let result: SMLCommandResult

    public init(statusCode: Int, command: SMLCommandEnvelope, result: SMLCommandResult) {
        self.statusCode = statusCode
        self.command = command
        self.result = result
    }
}

public struct SMLWorkflowAPI: Sendable {
    public typealias AuthorityResolver = @Sendable (
        _ command: SMLCommandEnvelope
    ) async throws -> SMLCommandAuthority

    public let compiler: SMLWorkflowAPICompiler
    private let gateway: SMLCommandGateway
    private let authorityResolver: AuthorityResolver
    private let clock: @Sendable () -> Double

    public init(
        compiler: SMLWorkflowAPICompiler,
        gateway: SMLCommandGateway,
        authorityResolver: @escaping AuthorityResolver,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.compiler = compiler
        self.gateway = gateway
        self.authorityResolver = authorityResolver
        self.clock = clock
    }

    public func handle(_ request: SMLWorkflowAPIRequest) async throws -> SMLWorkflowAPIResponse {
        let now = clock()
        let command = try compiler.compile(request, issuedAtEpoch: now)
        let authority = try await authorityResolver(command)
        let result = try await gateway.submit(command, authority: authority, nowEpoch: now)
        let status = command.op == SMLRuntimeCommandOperation.workflowRun ? 201 : 200
        return SMLWorkflowAPIResponse(statusCode: status, command: command, result: result)
    }
}
