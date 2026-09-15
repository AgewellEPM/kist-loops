import Foundation

/// Keep the failing fallback's identity attached to its typed error. A fallback to Ollama must
/// never be displayed or priced as an OpenAI request merely because OpenAI started the chain.
public struct ProviderRouteFailure: Error, CustomStringConvertible, LocalizedError {
    public let requestedProvider: String
    public let provider: String
    public let model: String
    public let underlying: Error

    public var description: String {
        "provider '\(provider)' model '\(model)' failed after fallback from '\(requestedProvider)': \(underlying)"
    }
    public var errorDescription: String? { description }

    static func annotate(_ error: Error, requested: String, provider: String, model: String) -> Error {
        guard provider != requested, !(error is ProviderRequestBudgetError), !(error is CancellationError),
              !(error is ProviderRouteFailure) else { return error }
        return Self(requestedProvider: requested, provider: provider, model: model, underlying: error)
    }

    static func describe(_ error: Error, requested: String) -> String {
        (error as? Self)?.description ?? "provider '\(requested)' error: \(error)"
    }
}
