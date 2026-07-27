import SwiftUI

/// Shows the detected intent at the top of agent execution
/// Displays: Icon + Intent Type + Description + Confidence badge
struct IntentBanner: View {
    let intent: AgentIntent

    var body: some View {
        HStack(spacing: 8) {
            // Intent icon - compact
            Image(systemName: intentIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(intentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(intent.type.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(intentColor)

                Text(intent.description)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Confidence badge - compact
            ConfidenceBadge(confidence: intent.confidence)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(intentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(intentColor.opacity(0.2), lineWidth: 1)
        )
    }

    private var intentIcon: String {
        switch intent.type {
        case .coding:
            return "chevron.left.forwardslash.chevron.right"
        case .desktopControl:
            return "cursorarrow.click.2"
        case .systemControl:
            return "gearshape.fill"
        case .search:
            return "magnifyingglass"
        case .vision:
            return "eye.fill"
        case .conversation:
            return "bubble.left.and.bubble.right.fill"
        }
    }

    private var intentColor: Color {
        switch intent.type {
        case .coding:
            return .neonCyan
        case .desktopControl:
            return .neonPurple
        case .systemControl:
            return .neonOrange
        case .search:
            return .neonBlue
        case .vision:
            return .neonPink
        case .conversation:
            return .neonGreen
        }
    }
}

/// Small badge showing confidence percentage
struct ConfidenceBadge: View {
    let confidence: Double

    var body: some View {
        Text("\(Int(confidence * 100))%")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(badgeColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(badgeColor.opacity(0.12))
            )
    }

    private var badgeColor: Color {
        if confidence >= 0.8 {
            return .green
        } else if confidence >= 0.5 {
            return .orange
        } else {
            return .red
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        IntentBanner(intent: AgentIntent(
            type: .coding,
            description: "Create authentication service",
            confidence: 0.92,
            rawMessage: ""
        ))

        IntentBanner(intent: AgentIntent(
            type: .desktopControl,
            description: "Open Xcode and build project",
            confidence: 0.85,
            rawMessage: ""
        ))

        IntentBanner(intent: AgentIntent(
            type: .systemControl,
            description: "Set volume to 50%",
            confidence: 0.95,
            rawMessage: ""
        ))
    }
    .padding()
    .background(Color.black)
}
