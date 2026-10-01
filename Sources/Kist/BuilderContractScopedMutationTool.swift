import Foundation
import AgentCore

/// Execution-time half of the lean-headless capability contract. The surrounding isolated workspace
/// transaction still verifies the complete tree and rolls back undeclared effects; this wrapper denies
/// an out-of-contract file operation before it can touch even that staged workspace.
struct BuilderContractScopedMutationTool: AgentTool, ToolArgumentCanonicalizing {
    let base: any AgentTool
    let authority: [String: BuilderMutationKind]
    let verificationCommands: [KistRunner.BuilderPreflightCommand]
    var createdFiles: BuilderCreatedFileAuthority? = nil
    /// Plan-execute only: its coordinated actions get no in-step repair, so a same-executable near
    /// miss on the sealed verifier canonicalizes to the sealed command. The lean headless lane keeps
    /// exact-match denial — its own repair loop reads the denial and retries.
    var substitutesNearMisses: Bool = false

    var name: String { base.name }
    var description: String {
        if name == "run_command" {
            return "Run a sealed verification command in the staged project root. "
                + "Use one of these exact structured argument objects: "
                + sealedCommandExamples.joined(separator: "; ")
                + ". Omit cwd (or use a single dot). Omit timeout to use its sealed value. "
                + "Shell commands, input redirection and background execution are unavailable in this contract."
        }
        return base.description + " Builder contract paths: "
            + authority.keys.sorted().joined(separator: ", ")
            + (name == "write_file" ? ". After creating a file, revise it with edit_file or replace its full contents with write_file; then rerun the sealed verifier." : "")
            + (name == "edit_file" ? ". A create path can be edited only after this worker successfully wrote its current contents." : "")
    }
    var parameters: [ToolParameter] {
        guard name == "run_command" else { return base.parameters }
        return [
            ToolParameter(name: "executable", type: "string", description: "Exact executable from the sealed argument objects above"),
            ToolParameter(name: "args", type: "array", description: "Exact string argument array from the sealed command"),
            ToolParameter(name: "cwd", type: "string", description: "Omit for the staged project root; only the root is permitted", required: false),
            ToolParameter(name: "timeout", type: "number", description: "Omit to use the sealed command timeout; an explicit value must match exactly", required: false),
            ToolParameter(name: "allowed_exit_codes", type: "array", description: "Omit, or use [0]", required: false),
        ]
    }
    var supportedActions: [String] { base.supportedActions }
    var unsupportedActions: [String] { base.unsupportedActions }
    var capabilityNote: String? { base.capabilityNote }
    var usageExamples: [String] { name == "run_command" ? sealedCommandExamples : base.usageExamples }

    private var sealedCommandExamples: [String] {
        verificationCommands.compactMap { command in
            let object: [String: Any] = ["executable": command.executable, "args": command.arguments,
                                         "timeout": command.timeoutSeconds]
            return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) }
        }
    }

    func canonicalizeToolArguments(_ arguments: [String: Any]) -> [String: Any] {
        contractBoundArguments(arguments)
    }

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let effectiveArguments = canonicalizeToolArguments(arguments)
        var sealedSubstitutionNote: String?
        if name == "run_command", let substitute = sealedSubstitutionApplied(raw: arguments) {
            sealedSubstitutionNote = "[sealed verifier substituted for the requested arguments: "
                + substitute.canonicalStatement + "]\n"
        }
        let path = effectiveArguments["path"] as? String
        let revisingCreatedFile: Bool
        if name == "edit_file", let path, authority[path] == .create, let createdFiles {
            revisingCreatedFile = await createdFiles.matches(path: path, context: context)
        } else {
            revisingCreatedFile = false
        }
        guard authorized(effectiveArguments) || revisingCreatedFile else {
            if name == "run_command" {
                return .failure("The command arguments did not match the sealed verifier. "
                    + "Use exactly one of these argument objects: " + sealedCommandExamples.joined(separator: "; ")
                    + ". Omit cwd; do not switch to shell/command mode.")
            }
            return .failure("builder execution contract denied an undeclared mutation. "
                + "Use the advertised file tool for a sealed path; run_command permits only the exact sealed verifier, including during repair.")
        }
        var result = try await base.execute(arguments: effectiveArguments, context: context)
        if let sealedSubstitutionNote {
            result = result.prefixingOutput(sealedSubstitutionNote)
        }
        if result.success, let path, authority[path] == .create,
           name == "write_file" || name == "edit_file" {
            await createdFiles?.record(path: path, context: context)
        }
        guard name == "run_command", result.success else { return result }
        return result.authorizingBuilderContractVerification(arguments: effectiveArguments)
    }

    /// The sealed command a raw request canonicalizes to, or nil when the request is already exact
    /// (no substitution) or is not a repairable near miss.
    func sealedSubstitutionApplied(raw arguments: [String: Any]) -> KistRunner.BuilderPreflightCommand? {
        guard substitutesNearMisses, name == "run_command", !authorized(arguments) else { return nil }
        return sealedSubstitute(for: arguments)
    }

    /// The one sealed command this request can only have meant: same executable, no shell/stdin/
    /// background/cwd escape, default exit codes — and exactly ONE sealed command for that
    /// executable, so the substitution is unambiguous. Nil keeps the exact-match refusal.
    func sealedSubstitute(for arguments: [String: Any]) -> KistRunner.BuilderPreflightCommand? {
        guard name == "run_command",
              let executable = arguments["executable"] as? String,
              arguments["command"] == nil, arguments["shell"] == nil,
              arguments["stdin"] == nil, arguments["stdin_path"] == nil,
              arguments["background"] == nil,
              arguments["cwd"] == nil || (arguments["cwd"] as? String) == ".",
              exactZeroExitCodes(arguments["allowed_exit_codes"]) else { return nil }
        let candidates = verificationCommands.filter { $0.executable == executable }
        guard candidates.count == 1, let sealed = candidates.first else { return nil }
        // Explicit timeouts are never repaired (same rule as contractBoundArguments): only an omitted
        // timeout, or exactly the sealed one, may ride along with substituted arguments.
        if arguments["timeout"] != nil, exactInteger(arguments["timeout"]) != sealed.timeoutSeconds {
            return nil
        }
        return sealed
    }

    /// `run_command` defaults an omitted timeout to 120 seconds, which could exceed the frozen
    /// verifier's ceiling. For one unambiguous executable+argv match, bind the actual invocation to
    /// the contract's timeout before the command is authorized, audited, executed, and sealed.
    /// Explicit timeouts are never repaired. An empty cwd is the base tool's spelling of the project
    /// root, so canonicalize it to omission before authorization, audit and execution.
    private func contractBoundArguments(_ arguments: [String: Any]) -> [String: Any] {
        var arguments = arguments
        if name == "run_command", arguments["cwd"] as? String == "" {
            arguments.removeValue(forKey: "cwd")
        }
        // A same-executable near miss on the sealed verifier canonicalizes TO the sealed command
        // (different test selection, an extra -v, a discover subcommand): the contract permits only
        // that command, so this is what will actually run. Doing it here, not in execute, means the
        // executor records, durable receipts, replay recipes, and the gate digest all describe the
        // sealed invocation (2026-09-27: substituting at execution time left the recipe holding the
        // near miss and no final receipt could ever be minted).
        if let substitute = sealedSubstitutionApplied(raw: arguments) {
            return ["executable": substitute.executable, "args": substitute.arguments,
                    "timeout": substitute.timeoutSeconds]
        }
        guard name == "run_command", arguments["timeout"] == nil,
              let executable = arguments["executable"] as? String else { return arguments }
        let suppliedArguments = (arguments["args"] as? [String]) ?? []
        let matches = verificationCommands.filter {
            $0.executable == executable && $0.arguments == suppliedArguments
        }
        guard matches.count == 1, let command = matches.first else { return arguments }
        var bound = arguments
        bound["timeout"] = command.timeoutSeconds
        return bound
    }

    private func authorized(_ arguments: [String: Any]) -> Bool {
        switch name {
        case "write_file":
            guard let path = arguments["path"] as? String else { return false }
            return authority[path] == .create
        case "edit_file":
            guard let path = arguments["path"] as? String else { return false }
            return authority[path] == .modify
        case "apply_patch":
            guard let patch = arguments["patch"] as? String,
                  let operations = try? ApplyPatch.parse(patch), !operations.isEmpty else { return false }
            return operations.allSatisfy { operation in
                switch operation {
                case .add(let path, _): return authority[path] == .create
                case .delete(let path): return authority[path] == .delete
                case .update(let path, let moveTo, _):
                    return moveTo == nil && authority[path] == .modify
                }
            }
        case "run_command":
            let allowedKeys: Set<String> = [
                "executable", "args", "cwd", "timeout", "allowed_exit_codes",
            ]
            guard Set(arguments.keys).isSubset(of: allowedKeys),
                  let executable = arguments["executable"] as? String,
                  arguments["command"] == nil, arguments["shell"] == nil,
                  arguments["stdin"] == nil, arguments["stdin_path"] == nil,
                  arguments["background"] == nil else { return false }
            let suppliedArguments: [String]
            if let raw = arguments["args"] {
                guard let values = raw as? [String] else { return false }
                suppliedArguments = values
            } else {
                suppliedArguments = []
            }
            let cwd = arguments["cwd"] as? String
            guard arguments["cwd"] == nil || cwd == ".",
                  exactZeroExitCodes(arguments["allowed_exit_codes"]) else { return false }
            return verificationCommands.contains { command in
                executable == command.executable
                    && suppliedArguments == command.arguments
                    && exactInteger(arguments["timeout"]) == command.timeoutSeconds
            }
        default:
            return false
        }
    }

    private func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let encoding = String(cString: number.objCType)
        guard encoding != "c", encoding != "B" else { return nil }
        let numeric = number.doubleValue
        guard numeric.isFinite, numeric.rounded() == numeric,
              numeric >= Double(Int.min), numeric <= Double(Int.max) else { return nil }
        return Int(numeric)
    }

    private func exactZeroExitCodes(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let values = value as? [Any], values.count == 1 else { return false }
        return exactInteger(values[0]) == 0
    }
}
