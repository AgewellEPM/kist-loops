import SwiftUI

struct ErrorBannerView: View {
    let message: String
    let onDismiss: () -> Void
    var onRetry: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    var isRetryable: Bool = false
    var isAuthError: Bool = false

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(isExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)

                    if message.count > 80 && !isExpanded {
                        Button("Show more") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded = true
                            }
                        }
                        .font(.caption2)
                        .foregroundColor(.neonCyan)
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Action buttons
            if isRetryable || isAuthError {
                HStack(spacing: 12) {
                    if isRetryable, let retry = onRetry {
                        Button(action: retry) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text("Retry")
                            }
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.neonCyan.opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }

                    if isAuthError, let openSettings = onOpenSettings {
                        Button(action: openSettings) {
                            HStack(spacing: 4) {
                                Image(systemName: "gear")
                                Text("Settings")
                            }
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.neonPink.opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

// MARK: - Convenience Initializers

extension ErrorBannerView {
    /// Create an error banner from an AIProviderError with automatic retry/settings detection
    static func forProviderError(
        _ error: AIProviderError,
        onDismiss: @escaping () -> Void,
        onRetry: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil
    ) -> ErrorBannerView {
        ErrorBannerView(
            message: error.errorDescription ?? "Unknown error",
            onDismiss: onDismiss,
            onRetry: onRetry,
            onOpenSettings: onOpenSettings,
            isRetryable: error.isRetryable,
            isAuthError: error == .invalidAPIKey
        )
    }
}

// Make AIProviderError Equatable for comparison
extension AIProviderError: Equatable {
    static func == (lhs: AIProviderError, rhs: AIProviderError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidAPIKey, .invalidAPIKey),
             (.rateLimited, .rateLimited),
             (.invalidResponse, .invalidResponse),
             (.modelNotAvailable, .modelNotAvailable),
             (.contextTooLong, .contextTooLong),
             (.serverNotRunning, .serverNotRunning):
            return true
        case (.networkError(let e1), .networkError(let e2)):
            return e1.localizedDescription == e2.localizedDescription
        case (.configurationError(let m1), .configurationError(let m2)):
            return m1 == m2
        case (.unknown(let m1), .unknown(let m2)):
            return m1 == m2
        default:
            return false
        }
    }
}
