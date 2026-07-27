import SwiftUI

/// Horizontal timeline showing the execution flow:
/// Intent → Plan → Action 1 → Action 2 → ... → Done
struct ExecutionTimeline: View {
    let intent: AgentIntent?
    let plan: ExecutionPlan?
    let actionResults: [ActionExecutionResult]
    let executionState: ExecutionState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                // Intent node
                if intent != nil {
                    TimelineNode(
                        icon: "lightbulb.fill",
                        label: "Intent",
                        status: .completed,
                        color: .neonCyan
                    )
                }

                // Plan node
                if plan != nil {
                    TimelineConnector(isActive: true)
                    TimelineNode(
                        icon: "list.bullet",
                        label: "Plan",
                        status: .completed,
                        color: .neonPurple
                    )
                }

                // Action nodes
                ForEach(Array(actionResults.enumerated()), id: \.offset) { index, result in
                    TimelineConnector(isActive: true)
                    TimelineNode(
                        icon: result.action.type.icon,
                        label: result.action.tool ?? "Action",
                        status: result.success ? .completed : .failed,
                        color: result.success ? .green : .red
                    )
                }

                // Current executing node
                if executionState == .executing, let plan = plan {
                    let currentIndex = actionResults.count
                    if currentIndex < plan.actions.count {
                        TimelineConnector(isActive: false)
                        TimelineNode(
                            icon: plan.actions[currentIndex].type.icon,
                            label: plan.actions[currentIndex].tool ?? "...",
                            status: .inProgress,
                            color: .neonOrange
                        )
                    }
                }

                // Remaining nodes (dimmed)
                if let plan = plan {
                    let remainingStart = actionResults.count + (executionState == .executing ? 1 : 0)
                    ForEach(remainingStart..<plan.actions.count, id: \.self) { index in
                        TimelineConnector(isActive: false)
                        TimelineNode(
                            icon: plan.actions[index].type.icon,
                            label: plan.actions[index].tool ?? "Action",
                            status: .pending,
                            color: .gray
                        )
                    }
                }

                // Final status node
                if executionState == .completed || executionState == .failed {
                    TimelineConnector(isActive: executionState == .completed)
                    TimelineNode(
                        icon: executionState == .completed ? "checkmark.circle.fill" : "xmark.circle.fill",
                        label: executionState == .completed ? "Done" : "Failed",
                        status: executionState == .completed ? .completed : .failed,
                        color: executionState == .completed ? .green : .red
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.cardBackground.opacity(0.2))
        )
    }
}

/// Single node in the timeline
struct TimelineNode: View {
    let icon: String
    let label: String
    let status: NodeStatus
    let color: Color

    @State private var isPulsing = false

    enum NodeStatus {
        case pending, inProgress, completed, failed
    }

    var body: some View {
        VStack(spacing: 2) {
            // Circle with icon - compact
            ZStack {
                Circle()
                    .fill(backgroundColor)
                    .frame(width: 22, height: 22)
                    .shadow(color: status == .inProgress ? color.opacity(0.4) : .clear, radius: 3)
                    .scaleEffect(isPulsing ? 1.1 : 1.0)

                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            .animation(
                status == .inProgress ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default,
                value: isPulsing
            )
            .onAppear {
                if status == .inProgress {
                    isPulsing = true
                }
            }

            // Label - compact
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(labelColor)
                .lineLimit(1)
                .frame(maxWidth: 40)
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .pending:
            return Color.gray.opacity(0.2)
        case .inProgress:
            return color.opacity(0.3)
        case .completed:
            return color.opacity(0.2)
        case .failed:
            return Color.red.opacity(0.2)
        }
    }

    private var iconColor: Color {
        switch status {
        case .pending:
            return .gray
        case .inProgress, .completed:
            return color
        case .failed:
            return .red
        }
    }

    private var labelColor: Color {
        switch status {
        case .pending:
            return .gray.opacity(0.6)
        case .inProgress, .completed, .failed:
            return .secondary
        }
    }
}

/// Connector line between nodes
struct TimelineConnector: View {
    var isActive: Bool = true

    var body: some View {
        Rectangle()
            .fill(isActive ? Color.neonCyan.opacity(0.4) : Color.gray.opacity(0.2))
            .frame(width: 12, height: 1.5)
    }
}

#Preview {
    VStack(spacing: 20) {
        // In progress example
        ExecutionTimeline(
            intent: AgentIntent(type: .coding, description: "Create file", confidence: 0.9, rawMessage: ""),
            plan: ExecutionPlan(
                intent: AgentIntent(type: .coding, description: "", confidence: 0.9, rawMessage: ""),
                planSteps: [],
                actions: [
                    ExecutableAction(type: .createFile, tool: nil, parameters: [:], description: "", stepIndex: 0),
                    ExecutableAction(type: .toolCall, tool: "run_build", parameters: [:], description: "", stepIndex: 1)
                ],
                summary: "",
                estimatedDuration: nil
            ),
            actionResults: [
                ActionExecutionResult(
                    action: ExecutableAction(type: .createFile, tool: nil, parameters: [:], description: "", stepIndex: 0),
                    success: true,
                    output: "",
                    error: nil,
                    duration: 0.5,
                    metadata: nil
                )
            ],
            executionState: .executing
        )

        // Completed example
        ExecutionTimeline(
            intent: AgentIntent(type: .coding, description: "Create file", confidence: 0.9, rawMessage: ""),
            plan: ExecutionPlan(
                intent: AgentIntent(type: .coding, description: "", confidence: 0.9, rawMessage: ""),
                planSteps: [],
                actions: [
                    ExecutableAction(type: .createFile, tool: nil, parameters: [:], description: "", stepIndex: 0)
                ],
                summary: "",
                estimatedDuration: nil
            ),
            actionResults: [
                ActionExecutionResult(
                    action: ExecutableAction(type: .createFile, tool: nil, parameters: [:], description: "", stepIndex: 0),
                    success: true,
                    output: "",
                    error: nil,
                    duration: 0.5,
                    metadata: nil
                )
            ],
            executionState: .completed
        )
    }
    .padding()
    .background(Color.black)
}
