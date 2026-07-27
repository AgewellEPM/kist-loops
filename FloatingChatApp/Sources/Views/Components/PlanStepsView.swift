import SwiftUI

/// Shows the plan steps with checkmarks/progress indicators
struct PlanStepsView: View {
    let steps: [PlanStep]
    let currentActionIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "list.bullet")
                    .foregroundColor(.secondary)
                Text("Plan")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                Spacer()

                // Progress indicator
                Text("\(completedCount)/\(steps.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.neonCyan)
            }

            // Steps list
            ForEach(steps) { step in
                PlanStepRow(
                    step: step,
                    isCurrentAction: step.actionIndices.contains(currentActionIndex)
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.cardBackground.opacity(0.5))
        )
    }

    private var completedCount: Int {
        steps.filter { $0.status == .completed }.count
    }
}

/// Individual step row with status indicator
struct PlanStepRow: View {
    let step: PlanStep
    let isCurrentAction: Bool

    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 10) {
            // Status icon
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 22, height: 22)

                Image(systemName: step.status.icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(statusColor)
            }
            .scaleEffect(isPulsing ? 1.1 : 1.0)
            .animation(
                isCurrentAction ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default,
                value: isPulsing
            )

            // Step description
            Text(step.description)
                .font(.system(size: 12))
                .foregroundColor(step.status == .completed ? .secondary : .primary)
                .strikethrough(step.status == .skipped)

            Spacer()

            // Step number
            Text("#\(step.index + 1)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .onAppear {
            if isCurrentAction {
                isPulsing = true
            }
        }
        .onChange(of: isCurrentAction) { _, newValue in
            isPulsing = newValue
        }
    }

    private var statusColor: Color {
        switch step.status {
        case .pending:
            return .gray
        case .inProgress:
            return .neonCyan
        case .completed:
            return .green
        case .failed:
            return .red
        case .skipped:
            return .orange
        }
    }
}

#Preview {
    PlanStepsView(
        steps: [
            PlanStep(index: 0, description: "Analyze project structure", actionIndices: [0], status: .completed),
            PlanStep(index: 1, description: "Create AuthService.swift", actionIndices: [1], status: .inProgress),
            PlanStep(index: 2, description: "Build and verify", actionIndices: [2], status: .pending)
        ],
        currentActionIndex: 1
    )
    .padding()
    .background(Color.black)
}
