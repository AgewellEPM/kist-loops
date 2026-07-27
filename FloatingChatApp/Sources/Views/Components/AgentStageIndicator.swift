import SwiftUI

/// Visual indicator showing the current stage of the agent pipeline
struct AgentStageIndicator: View {
    let stage: AgentPipelineManager.AgentStage
    @State private var animatingDots = false

    private let stages: [(name: String, icon: String)] = [
        ("Understanding", "brain.head.profile"),
        ("Planning", "list.clipboard"),
        ("Coding", "chevron.left.forwardslash.chevron.right"),
        ("Building", "hammer")
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<stages.count, id: \.self) { index in
                let stageInfo = stages[index]
                let stageValue = index + 1  // Stage values are 1-indexed

                HStack(spacing: 6) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(backgroundColor(for: stageValue))
                            .frame(width: 28, height: 28)

                        if isActive(stageValue) {
                            Circle()
                                .stroke(Color.accentColor, lineWidth: 2)
                                .frame(width: 28, height: 28)
                                .scaleEffect(animatingDots ? 1.2 : 1.0)
                                .opacity(animatingDots ? 0 : 1)
                        }

                        Image(systemName: stageInfo.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(foregroundColor(for: stageValue))
                    }

                    // Label
                    Text(stageInfo.name)
                        .font(.system(size: 11, weight: isActive(stageValue) ? .semibold : .regular))
                        .foregroundColor(labelColor(for: stageValue))
                }

                // Connector line (except after last item)
                if index < stages.count - 1 {
                    Rectangle()
                        .fill(connectorColor(after: stageValue))
                        .frame(width: 20, height: 2)
                }
            }

            Spacer()

            // Status text
            statusText
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
        .cornerRadius(8)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                animatingDots = true
            }
        }
    }

    // MARK: - Status Text

    @ViewBuilder
    private var statusText: some View {
        switch stage {
        case .idle:
            Label("Ready", systemImage: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

        case .understanding:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Analyzing request...")
                    .font(.system(size: 11))
            }
            .foregroundColor(.accentColor)

        case .requirements:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Generating requirements...")
                    .font(.system(size: 11))
            }
            .foregroundColor(.accentColor)

        case .generating:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Writing code...")
                    .font(.system(size: 11))
            }
            .foregroundColor(.accentColor)

        case .building:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Building project...")
                    .font(.system(size: 11))
            }
            .foregroundColor(.orange)

        case .complete:
            Label("Complete", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.green)

        case .error:
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.red)
        }
    }

    // MARK: - Helpers

    private func isActive(_ stageValue: Int) -> Bool {
        stage.rawValue == stageValue
    }

    private func isComplete(_ stageValue: Int) -> Bool {
        stage.rawValue > stageValue || stage == .complete
    }

    private func backgroundColor(for stageValue: Int) -> Color {
        if isComplete(stageValue) {
            return Color.green.opacity(0.2)
        } else if isActive(stageValue) {
            return Color.accentColor.opacity(0.2)
        } else {
            return Color.secondary.opacity(0.1)
        }
    }

    private func foregroundColor(for stageValue: Int) -> Color {
        if isComplete(stageValue) {
            return .green
        } else if isActive(stageValue) {
            return .accentColor
        } else {
            return .secondary
        }
    }

    private func labelColor(for stageValue: Int) -> Color {
        if isActive(stageValue) {
            return .primary
        } else if isComplete(stageValue) {
            return .green
        } else {
            return .secondary
        }
    }

    private func connectorColor(after stageValue: Int) -> Color {
        if isComplete(stageValue) {
            return .green
        } else {
            return Color.secondary.opacity(0.3)
        }
    }
}

// MARK: - Compact Variant

struct AgentStageIndicatorCompact: View {
    let stage: AgentPipelineManager.AgentStage

    var body: some View {
        HStack(spacing: 6) {
            // Stage dots
            ForEach(1...4, id: \.self) { stageValue in
                Circle()
                    .fill(dotColor(for: stageValue))
                    .frame(width: 8, height: 8)
            }

            // Current stage name
            Text(stageName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private var stageName: String {
        switch stage {
        case .idle: return "Ready"
        case .understanding: return "Understanding"
        case .requirements: return "Planning"
        case .generating: return "Coding"
        case .building: return "Building"
        case .complete: return "Done"
        case .error: return "Error"
        }
    }

    private func dotColor(for stageValue: Int) -> Color {
        if stage.rawValue > stageValue || stage == .complete {
            return .green
        } else if stage.rawValue == stageValue {
            return .accentColor
        } else {
            return Color.secondary.opacity(0.3)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        AgentStageIndicator(stage: .idle)
        AgentStageIndicator(stage: .understanding)
        AgentStageIndicator(stage: .requirements)
        AgentStageIndicator(stage: .generating)
        AgentStageIndicator(stage: .building)
        AgentStageIndicator(stage: .complete)
        AgentStageIndicator(stage: .error)

        Divider()

        HStack(spacing: 20) {
            AgentStageIndicatorCompact(stage: .understanding)
            AgentStageIndicatorCompact(stage: .building)
            AgentStageIndicatorCompact(stage: .complete)
        }
    }
    .padding()
    .frame(width: 600)
}
