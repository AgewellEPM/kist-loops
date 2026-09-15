import Foundation

public enum SMLWorkflowAPIMethod: String, Sendable, Codable, Equatable {
    case get = "GET"
    case post = "POST"
}

public enum SMLWorkflowAPIRequestBodyKind: String, Sendable, Codable, Equatable {
    case none
    case startTask = "start_task"
    case expectedState = "expected_state"
}

public struct SMLWorkflowAPIRequestExample: Sendable, Codable, Equatable {
    public let method: SMLWorkflowAPIMethod
    public let path: String
    public let body: SMLObject
    public let summary: String

    public init(
        method: SMLWorkflowAPIMethod,
        path: String,
        body: SMLObject = [:],
        summary: String
    ) {
        self.method = method
        self.path = path
        self.body = body
        self.summary = summary
    }
}

public struct SMLWorkflowAPIEndpoint: Sendable, Codable, Equatable {
    public let method: SMLWorkflowAPIMethod
    public let pathTemplate: String
    public let operationID: String
    public let action: SMLWorkflowControlAction
    public let summary: String
    public let bodyKind: SMLWorkflowAPIRequestBodyKind
    public let bodyFields: [SMLWorkflowFieldDescriptor]
    public let examples: [SMLWorkflowAPIRequestExample]

    public init(
        method: SMLWorkflowAPIMethod,
        pathTemplate: String,
        operationID: String,
        action: SMLWorkflowControlAction,
        summary: String,
        bodyKind: SMLWorkflowAPIRequestBodyKind = .none,
        bodyFields: [SMLWorkflowFieldDescriptor] = [],
        examples: [SMLWorkflowAPIRequestExample] = []
    ) {
        self.method = method
        self.pathTemplate = pathTemplate
        self.operationID = operationID
        self.action = action
        self.summary = summary
        self.bodyKind = bodyKind
        self.bodyFields = bodyFields
        self.examples = examples.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.method.rawValue != $1.method.rawValue {
                return $0.method.rawValue < $1.method.rawValue
            }
            return $0.summary < $1.summary
        }
    }

    enum CodingKeys: String, CodingKey {
        case method, pathTemplate, operationID, action, summary, bodyKind, bodyFields, examples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            method: try container.decode(SMLWorkflowAPIMethod.self, forKey: .method),
            pathTemplate: try container.decode(String.self, forKey: .pathTemplate),
            operationID: try container.decode(String.self, forKey: .operationID),
            action: try container.decode(SMLWorkflowControlAction.self, forKey: .action),
            summary: try container.decode(String.self, forKey: .summary),
            bodyKind: try container.decodeIfPresent(
                SMLWorkflowAPIRequestBodyKind.self,
                forKey: .bodyKind
            ) ?? .none,
            bodyFields: try container.decodeIfPresent(
                [SMLWorkflowFieldDescriptor].self,
                forKey: .bodyFields
            ) ?? [],
            examples: try container.decodeIfPresent(
                [SMLWorkflowAPIRequestExample].self,
                forKey: .examples
            ) ?? []
        )
    }
}

public struct SMLWorkflowAPICatalog: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let basePath: String
    public let workflowPath: String
    public let endpoints: [SMLWorkflowAPIEndpoint]

    public init(surface: SMLWorkflowSurface, basePath: String = "/v1") {
        self.init(
            surface: surface,
            basePath: basePath,
            workflowPath: Self.defaultWorkflowPath(workflowID: surface.workflowID)
        )
    }

    init(
        surface: SMLWorkflowSurface,
        basePath: String = "/v1",
        workflowPath: String
    ) {
        let normalizedBase = basePath.hasSuffix("/")
            ? String(basePath.dropLast())
            : basePath
        let normalizedWorkflowPath = workflowPath.hasSuffix("/")
            ? String(workflowPath.dropLast())
            : workflowPath
        self.workflowID = surface.workflowID
        self.workflowVersion = surface.workflowVersion
        self.basePath = normalizedBase
        self.workflowPath = normalizedWorkflowPath
        let workflowRoutePath = "\(normalizedBase)\(normalizedWorkflowPath)"
        let taskPath = "\(workflowRoutePath)/tasks/{task_id}"
        let exampleTaskPath = "\(workflowRoutePath)/tasks/TASK-ID"
        let sampleInput = surface.sampleInputObject()
        let startBody: SMLObject = sampleInput.isEmpty
            ? ["task_id": .string("TASK-ID")]
            : [
                "task_id": .string("TASK-ID"),
                "input": .object(sampleInput),
            ]
        let expectedStateBody: SMLObject = ["task_revision": .number(0)]
        endpoints = [
            .init(method: .get, pathTemplate: workflowRoutePath,
                  operationID: "describe_workflow", action: .describe,
                  summary: "Describe the exact admitted workflow surface",
                  examples: [
                    .init(
                        method: .get,
                        path: workflowRoutePath,
                        summary: "Describe the exact admitted workflow revision."
                    ),
                  ]),
            .init(method: .post, pathTemplate: "\(workflowRoutePath)/tasks",
                  operationID: "start_workflow_task", action: .start,
                  summary: "Start a task; body requires task_id and accepts input",
                  bodyKind: .startTask,
                  bodyFields: surface.inputs,
                  examples: [
                    .init(
                        method: .post,
                        path: "\(workflowRoutePath)/tasks",
                        body: startBody,
                        summary: "Start a workflow task with declared input fields."
                    ),
                  ]),
            .init(method: .get, pathTemplate: taskPath,
                  operationID: "watch_workflow_task", action: .watch,
                  summary: "Read a task projection",
                  examples: [
                    .init(
                        method: .get,
                        path: exampleTaskPath,
                        summary: "Read the latest task projection."
                    ),
                  ]),
            .init(method: .post, pathTemplate: "\(taskPath)/approve",
                  operationID: "approve_workflow_task", action: .approve,
                  summary: "Approve the current task gate",
                  bodyKind: .expectedState,
                  examples: [
                    .init(
                        method: .post,
                        path: "\(exampleTaskPath)/approve",
                        body: expectedStateBody,
                        summary: "Approve the current gate using the latest task revision."
                    ),
                  ]),
            .init(method: .post, pathTemplate: "\(taskPath)/refuse",
                  operationID: "refuse_workflow_task", action: .refuse,
                  summary: "Refuse the current task gate",
                  bodyKind: .expectedState,
                  examples: [
                    .init(
                        method: .post,
                        path: "\(exampleTaskPath)/refuse",
                        body: expectedStateBody,
                        summary: "Refuse the current gate using the latest task revision."
                    ),
                  ]),
            .init(method: .post, pathTemplate: "\(taskPath)/rollback",
                  operationID: "rollback_workflow_task", action: .rollback,
                  summary: "Request terminal operator rollback",
                  bodyKind: .expectedState,
                  examples: [
                    .init(
                        method: .post,
                        path: "\(exampleTaskPath)/rollback",
                        body: expectedStateBody,
                        summary: "Roll the task back using the latest task revision."
                    ),
                  ]),
            .init(method: .post, pathTemplate: "\(taskPath)/reconcile",
                  operationID: "reconcile_workflow_task", action: .reconcile,
                  summary: "Close an interrupted earlier-session dispatch as failed without replay",
                  bodyKind: .expectedState,
                  bodyFields: [
                    .init(.init(name: "task_revision", type: .integer)),
                    .init(.init(name: "dispatch_id", type: .string)),
                    .init(.init(name: "note", type: .string)),
                  ],
                  examples: [
                    .init(method: .post, path: "\(exampleTaskPath)/reconcile", body: [
                        "task_revision": .number(2), "dispatch_id": .string("DISPATCH-ID"),
                        "note": .string("Stopped previous host; retiring interrupted task"),
                    ], summary: "After restarting the host, retire a claim with its outcome still unknown."),
                  ]),
            .init(method: .get, pathTemplate: "\(taskPath)/receipts",
                  operationID: "list_workflow_task_receipts", action: .receipts,
                  summary: "List task receipts",
                  examples: [
                    .init(
                        method: .get,
                        path: "\(exampleTaskPath)/receipts",
                        summary: "List accepted or sealed receipts for the task."
                    ),
                  ]),
        ]
    }

    enum CodingKeys: String, CodingKey {
        case workflowID
        case workflowVersion
        case basePath
        case workflowPath
        case endpoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workflowID = try container.decode(String.self, forKey: .workflowID)
        workflowVersion = try container.decode(String.self, forKey: .workflowVersion)
        basePath = try container.decode(String.self, forKey: .basePath)
        workflowPath = try container.decodeIfPresent(
            String.self,
            forKey: .workflowPath
        ) ?? Self.defaultWorkflowPath(workflowID: workflowID)
        endpoints = try container.decode([SMLWorkflowAPIEndpoint].self, forKey: .endpoints)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workflowID, forKey: .workflowID)
        try container.encode(workflowVersion, forKey: .workflowVersion)
        try container.encode(basePath, forKey: .basePath)
        try container.encode(workflowPath, forKey: .workflowPath)
        try container.encode(endpoints, forKey: .endpoints)
    }

    static func defaultWorkflowPath(workflowID: String) -> String {
        "/workflows/\(workflowID)"
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
        workflowPath: String? = nil,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) throws {
        guard Self.validBasePath(basePath) else { throw SMLWorkflowAPIError.invalidBasePath }
        let workflowPath = workflowPath ?? SMLWorkflowAPICatalog.defaultWorkflowPath(
            workflowID: surface.workflowID
        )
        guard Self.validWorkflowPath(workflowPath) else { throw SMLWorkflowAPIError.invalidPath(workflowPath) }
        self.surface = surface
        catalog = SMLWorkflowAPICatalog(
            surface: surface,
            basePath: basePath,
            workflowPath: workflowPath
        )
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
        let workflowSegments = catalog.workflowPath.split(separator: "/").map(String.init)
        guard !workflowSegments.isEmpty,
              tail.starts(with: workflowSegments) else {
            throw SMLWorkflowAPIError.routeNotFound(
                method: request.method.rawValue, path: request.path
            )
        }
        let workflowTail = Array(tail.dropFirst(workflowSegments.count))

        if request.method == .get, workflowTail.isEmpty {
            try requireEmptyBody(request.body)
            return try compiler.compile(
                action: .describe,
                scope: request.scope,
                expectedState: request.expectedState,
                issuedAtEpoch: issuedAtEpoch
            )
        }
        if request.method == .post, workflowTail == ["tasks"] {
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
        guard workflowTail.count >= 2, workflowTail[0] == "tasks" else {
            throw SMLWorkflowAPIError.routeNotFound(
                method: request.method.rawValue, path: request.path
            )
        }
        let task = workflowTail[1]
        let action: SMLWorkflowControlAction
        switch (request.method, Array(workflowTail.dropFirst(2))) {
        case (.get, []):
            try requireEmptyBody(request.body)
            action = .watch
        case (.post, ["approve"]):
            action = .approve
        case (.post, ["refuse"]):
            action = .refuse
        case (.post, ["rollback"]):
            action = .rollback
        case (.post, ["reconcile"]):
            action = .reconcile
        case (.get, ["receipts"]):
            try requireEmptyBody(request.body)
            action = .receipts
        default:
            throw SMLWorkflowAPIError.routeNotFound(
                method: request.method.rawValue, path: request.path
            )
        }
        let expectedState: SMLObject
        switch action {
        case .approve, .refuse, .rollback, .reconcile:
            expectedState = try expectedStateObject(
                from: request.body,
                fallback: request.expectedState
            )
        case .describe, .start, .watch, .receipts:
            expectedState = request.expectedState
        }
        return try compiler.compile(
            action: action,
            task: task,
            scope: request.scope,
            expectedState: expectedState,
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

    private func expectedStateObject(
        from body: SMLObject,
        fallback: SMLObject
    ) throws -> SMLObject {
        guard !body.isEmpty else { return fallback }
        guard fallback.isEmpty || fallback == body else {
            throw SMLWorkflowAPIError.invalidBodyField("expected_state")
        }
        return body
    }

    private static func validBasePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && !path.contains("?") && !path.contains("#")
            && !path.contains("//") && !path.contains("%")
            && path.split(separator: "/").allSatisfy {
                SMLValidationSupport.identifierIsValid(String($0), allowDot: false)
            }
    }

    static func validWorkflowPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && !path.contains("?") && !path.contains("#")
            && !path.contains("//") && !path.contains("%")
            && path.split(separator: "/").allSatisfy {
                SMLValidationSupport.identifierIsValid(String($0), allowDot: true)
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
