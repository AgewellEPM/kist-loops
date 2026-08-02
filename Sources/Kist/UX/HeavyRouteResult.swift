import Foundation
import AgentCore

/// The small result boundary between the existing REPL and its long-running execution routes.
///
/// Heavy routes used to return `Void`, which forced replay to record a synthetic hand-off with an
/// unknown result.  Keep execution in the existing runners; this value only carries the facts the
/// runner already knows back to the REPL so one turn can be finalized honestly.
struct HeavyRouteResult: Equatable, Sendable {
    enum Review: Equatable, Sendable {
        case notApplicable(String)
        case handledInternally(String)

        var proofText: String {
            switch self {
            case .notApplicable(let detail):
                return "not applicable — \(detail)"
            case .handledInternally(let detail):
                return "handled internally — \(detail)"
            }
        }
    }

    enum Verification: Equatable, Sendable {
        case passed(String)
        case failed(String)
        case unavailable(String)

        var proofSuccess: Bool? {
            switch self {
            case .passed: return true
            case .failed: return false
            case .unavailable: return nil
            }
        }

        var proofText: String {
            switch self {
            case .passed(let detail):
                return "passed — \(detail)"
            case .failed(let detail):
                return "failed — \(detail)"
            case .unavailable(let detail):
                return "unavailable — \(detail)"
            }
        }
    }

    let exitCode: Int32
    let interruption: InterruptibleTurn.InterruptReason?
    let review: Review
    let verification: Verification

    var succeeded: Bool { interruption == nil && exitCode == 0 }

    var finalText: String {
        if let interruption {
            let reason = interruption == .cancel ? "cancelled" : "interrupted"
            return "\(reason) — heavy route stopped before completion"
        }
        return exitCode == 0
            ? "completed — heavy route exited 0"
            : "failed — heavy route exited \(exitCode)"
    }
}

/// Typed proof entries for a heavy route. Splitting the pre-execution route fact from the three
/// post-execution facts preserves event order while making the one-of-each invariant testable.
enum HeavyRouteProof {
    static func routeEntry(intent: TaskBrief.Intent,
                           mode: PromptCompiler.Mode,
                           execution: String) -> TurnProofStore.Entry {
        let expected = PromptCompiler.expectedOutcome(intent: intent, mode: mode)
        return .init(kind: .routeSelected, tool: nil, success: nil,
                     text: "intent=\(intent.rawValue) outcome=\(expected.rawValue) execution=\(execution)")
    }

    static func completionEntries(result: HeavyRouteResult,
                                  intent: TaskBrief.Intent,
                                  mode: PromptCompiler.Mode,
                                  execution: String) -> [TurnProofStore.Entry] {
        let expected = PromptCompiler.expectedOutcome(intent: intent, mode: mode)
        // A mutation route cannot be finalized successful when its deterministic oracle was unavailable.
        // Advisory answer/evidence/plan routes may complete without an execution oracle, but a promised
        // state change needs an explicit passing verification fact.
        let verificationSatisfied = expected == .mutation
            ? result.verification.proofSuccess == true
            : result.verification.proofSuccess != false
        let finalSuccess = result.succeeded && verificationSatisfied
        return [
            .init(kind: .reviewAssessment, tool: nil, success: nil,
                  text: result.review.proofText),
            .init(kind: .verificationAssessment, tool: nil,
                  success: result.verification.proofSuccess,
                  text: result.verification.proofText),
            .init(kind: .turnFinalized, tool: nil, success: finalSuccess,
                  text: "intent=\(intent.rawValue) expected=\(expected.rawValue) execution=\(execution) result=\(result.finalText)"),
        ]
    }
}
