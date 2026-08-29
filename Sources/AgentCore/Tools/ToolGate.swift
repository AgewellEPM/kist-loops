import Foundation
import CoreFoundation

/// The shared enforcement gate every tool invocation passes through — skill capability scope +
/// the immutable audit record + secret-masking — extracted so that COMPOSITE tools (research_run,
/// visual_verify) route their internal sub-actions through the SAME gate as `ToolRegistry.execute`.
///
/// The council's #1 / Codex's MED: composites called sub-tools' `execute` directly, bypassing the
/// scope check + audit trail. A skill scoped to only `research_run` could implicitly fetch/browse
/// unaudited. Now a sub-action re-enters this gate under its REAL tool name, so it is scope-checked
/// and audited exactly like a top-level call.
public enum ToolGate {

    /// Run `body` (the actual tool execution) under the skill capability scope + audit. `name` is the
    /// tool's real name (top-level or composite sub-action). A scope denial blocks BEFORE `body` runs.
    ///
    /// `precomputedAllowlist` lets a caller that ALREADY read the active allow-list pass it in so the
    /// SAME value drives both the caller's audit and this gate's decision — `ToolRegistry.execute` reads
    /// it once for its unknown-tool audit and forwards it here, so a concurrent skill-load can't make the
    /// two reads disagree (DeepSeek LOW). The outer optional distinguishes "not provided" (`.none` → read
    /// it here) from "provided as nil" (`.some(nil)` → no skill loaded). Composites pass nothing.
    public static func run(name: String, arguments: [String: Any], context: ToolContext,
                           precomputedAllowlist: Set<String>?? = nil,
                           parameters: [ToolParameter]? = nil,
                           body: () async throws -> ToolResult) async -> ToolResult {
        let (argKeys, argsDigest) = AuditLog.digest(arguments)
        // Use the caller's already-read allow-list when provided (.some), else read it here. Not the `??`
        // operator — its RHS is an autoclosure that can't `await` the actor.
        let allowlist: Set<String>?
        if case let .some(provided) = precomputedAllowlist {
            allowlist = provided
        } else {
            allowlist = await context.skillTracker?.activeToolAllowlist()
        }
        func audit(_ outcome: String, _ success: Bool) async {
            await context.auditLog?.record(AuditEntry(at: Date().timeIntervalSince1970, tool: name,
                                                      argKeys: argKeys, argsDigest: argsDigest,
                                                      outcome: outcome, success: success,
                                                      scope: allowlist?.sorted(),
                                                      correlationID: context.correlationID))
        }
        // Authorization scope (action-class gate: plan-only / needs-approval). Enforced HERE, inside the
        // SHARED gate, so a composite sub-action (research_run → fetch/browse/visual) is subject to the
        // SAME plan-only/approval rules as the equivalent top-level call — otherwise a composite could
        // run state-changing fetch/browse in plan-only mode by re-entering only the skill-scope check
        // (Codex HIGH). `ToolRegistry.execute` no longer pre-checks this; this is the one enforcement site.
        if let reason = context.authorizationScope?.toolBlockReason(tool: name, arguments: arguments,
                                                                    scopeApproved: context.scopeOverrideApproved) {
            await audit("blocked_auth", false)
            return SecretMasker.mask(.failure(
                ToolError.permissionDenied("blocked by authorization scope: \(reason)").description))
        }
        // Skill capability scope: a loaded skill's allow-list (always-safe read tools excepted) bounds
        // the blast radius — for sub-actions too, so a composite can't smuggle a disallowed tool.
        if let allowlist, !allowlist.contains(name) {
            await audit("blocked_scope", false)
            return SecretMasker.mask(.failure(
                ToolError.permissionDenied(
                "blocked by skill capability scope: '\(name)' is not in the loaded skill's allowed-tools "
                + "(\(allowlist.sorted().joined(separator: ", "))). A loaded skill restricted this session "
                + "to least-privilege; finish that skill's task or declare the tool in allowed-tools.").description))
        }
        // Validate at the same execution choke point as authorization. Provider JSON schemas are advisory;
        // a caller can invoke the registry directly, so required fields, unknown fields, and runtime types
        // must be checked again immediately before the tool body runs.
        if let parameters, let reason = argumentValidationError(parameters: parameters, arguments: arguments) {
            await audit("invalid_arguments", false)
            return SecretMasker.mask(.failure(ToolError.invalidParameter(reason).description))
        }
        do {
            let invocation = BuilderTrustedToolInvocation.make(
                toolName: name, argumentsDigest: argsDigest)
            let raw = try await BuilderTrustedToolInvocationScope.$current.withValue(invocation) {
                try await body()
            }
            let result = SecretMasker.mask(raw)
            await audit(result.success ? "ok" : "error", result.success)
            return result
        } catch let error as ToolError {
            await audit("error", false)
            return SecretMasker.mask(.failure(error.description))
        } catch {
            await audit("error", false)
            return SecretMasker.mask(.failure(error.localizedDescription))
        }
    }

    static func argumentValidationError(parameters: [ToolParameter], arguments: [String: Any]) -> String? {
        // An empty parameter list is the legacy/dynamic-schema contract, not an explicit
        // `additionalProperties: false` object. The tool body remains responsible for validating it.
        guard !parameters.isEmpty else { return nil }
        var schema: [String: ToolParameter] = [:]
        for parameter in parameters {
            guard schema[parameter.name] == nil else {
                return "tool schema contains duplicate field '\(parameter.name)'"
            }
            schema[parameter.name] = parameter
        }
        if let unknown = arguments.keys.filter({ schema[$0] == nil }).sorted().first {
            return "unknown field '\(unknown)'"
        }
        if let missing = parameters.filter({ $0.required && (arguments[$0.name] == nil || arguments[$0.name] is NSNull) })
            .map(\.name).sorted().first {
            return "missing required field '\(missing)'"
        }
        for key in arguments.keys.sorted() {
            guard let parameter = schema[key], let value = arguments[key], !(value is NSNull) else { continue }
            guard valueMatchesSchema(value, type: parameter.type) else {
                return "field '\(key)' must be \(parameter.type), got \(String(describing: Swift.type(of: value)))"
            }
        }
        return nil
    }

    private static func valueMatchesSchema(_ value: Any, type: String) -> Bool {
        switch type {
        case "string": return value is String
        case "array": return value is [Any]
        case "boolean": return isBooleanValue(value)
        case "integer":
            if isBooleanValue(value) { return false }
            if value is Int { return true }
            if let number = value as? NSNumber {
                let double = number.doubleValue
                return double.isFinite && double.rounded(.towardZero) == double
            }
            return false
        case "number":
            if isBooleanValue(value) { return false }
            return value is NSNumber || value is Int || value is Double || value is Float
        default:
            return false
        }
    }

    /// Swift's Foundation bridge makes some NSNumber values (notably 0 and 1) satisfy `is Bool` on
    /// Darwin. JSON integers must remain integers; only the CFBoolean singleton type is a boolean.
    private static func isBooleanValue(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return value is Bool }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
