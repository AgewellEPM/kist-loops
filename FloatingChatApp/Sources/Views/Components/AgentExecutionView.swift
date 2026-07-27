import SwiftUI

/// The main container view for displaying agent execution
/// Shows: Timeline → Intent → Plan Steps → Actions → Results
struct AgentExecutionView: View {
    let intent: AgentIntent?
    let plan: ExecutionPlan?
    let actionResults: [ActionExecutionResult]
    let currentActionIndex: Int
    let executionState: ExecutionState

    @ObservedObject var runtimeService = AgentRuntimeService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Timeline at top - compact
            ExecutionTimeline(
                intent: intent,
                plan: plan,
                actionResults: actionResults,
                executionState: executionState
            )

            // Intent banner - only show if not completed
            if let intent = intent, executionState != .completed && executionState != .failed {
                IntentBanner(intent: intent)
            }

            // Plan steps (collapsible) - only show during execution
            if let plan = plan, !plan.planSteps.isEmpty, executionState == .executing {
                PlanStepsView(
                    steps: plan.planSteps,
                    currentActionIndex: currentActionIndex
                )
            }

            // Action cards - limit to last 3 to avoid clutter
            VStack(alignment: .leading, spacing: 6) {
                // Show only last few completed actions
                ForEach(Array(actionResults.suffix(3).enumerated()), id: \.element.id) { index, result in
                    ActionCard(
                        action: result.action,
                        result: result,
                        isExecuting: false
                    )
                }

                // Currently executing action
                if let plan = plan,
                   currentActionIndex < plan.actions.count,
                   executionState == .executing {
                    ActionCard(
                        action: plan.actions[currentActionIndex],
                        result: nil,
                        isExecuting: true
                    )
                }
            }

            // Build status (if applicable)
            BuildStatusView()
                .environmentObject(runtimeService)

            // Retry status indicator
            RetryStatusView()
                .environmentObject(runtimeService)

            // Summary on completion - compact
            if executionState == .completed || executionState == .failed {
                ExecutionSummaryView(
                    plan: plan,
                    results: actionResults,
                    state: executionState
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.cardBackground.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var borderColor: Color {
        switch executionState {
        case .executing:
            return .neonCyan.opacity(0.3)
        case .completed:
            return .green.opacity(0.3)
        case .failed:
            return .red.opacity(0.3)
        default:
            return .gray.opacity(0.2)
        }
    }
}

/// Summary shown after execution completes
struct ExecutionSummaryView: View {
    let plan: ExecutionPlan?
    let results: [ActionExecutionResult]
    let state: ExecutionState

    var body: some View {
        HStack(spacing: 8) {
            // Status icon - compact
            Image(systemName: state == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(state == .completed ? .green : .red)

            VStack(alignment: .leading, spacing: 1) {
                Text(state == .completed ? "Execution Complete" : "Execution Failed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(state == .completed ? .green : .red)

                HStack(spacing: 8) {
                    // Actions count
                    Label("\(successCount)/\(results.count) actions", systemImage: "checkmark")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    // Total duration
                    Label(formatDuration(totalDuration), systemImage: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill((state == .completed ? Color.green : Color.red).opacity(0.08))
        )
    }

    private var successCount: Int {
        results.filter { $0.success }.count
    }

    private var totalDuration: TimeInterval {
        results.reduce(0) { $0 + $1.duration }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        } else if duration < 60 {
            return String(format: "%.1fs", duration)
        } else {
            let minutes = Int(duration / 60)
            let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(seconds)s"
        }
    }
}

/// Shows build status from AgentRuntimeService
struct BuildStatusView: View {
    @EnvironmentObject var runtimeService: AgentRuntimeService

    var body: some View {
        Group {
            if runtimeService.pendingBuild {
                BuildingIndicatorView()
            }

            if !runtimeService.lastBuildErrors.isEmpty {
                BuildErrorsListView(errors: runtimeService.lastBuildErrors)
            }
        }
    }
}

/// Animated building indicator
struct BuildingIndicatorView: View {
    @State private var rotation: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            // Spinning indicator
            Image(systemName: "hammer.fill")
                .font(.system(size: 14))
                .foregroundColor(.neonOrange)
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }

            Text("Building...")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.neonOrange)

            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.neonOrange.opacity(0.1))
        )
    }
}

/// Shows list of build errors
struct BuildErrorsListView: View {
    let errors: [AgentRuntimeService.BuildError]

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            Button {
                withAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)

                    Text("Build Failed - \(errorCount) error(s)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.red)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            // Error list
            if isExpanded {
                ForEach(errors.prefix(5)) { error in
                    BuildErrorRow(error: error)
                }

                if errors.count > 5 {
                    Text("... and \(errors.count - 5) more")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.1))
        )
    }

    private var errorCount: Int {
        errors.filter { $0.type == .error }.count
    }
}

/// Single build error row
struct BuildErrorRow: View {
    let error: AgentRuntimeService.BuildError

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // File and line
            HStack(spacing: 4) {
                Text(URL(fileURLWithPath: error.file).lastPathComponent)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)

                Text(":\(error.line)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Error message
            Text(error.message)
                .font(.system(size: 11))
                .foregroundColor(.red.opacity(0.9))
                .lineLimit(2)
        }
        .padding(6)
        .background(Color.black.opacity(0.2))
        .cornerRadius(4)
    }
}

/// Shows retry status when agent is auto-fixing build errors
struct RetryStatusView: View {
    @EnvironmentObject var runtimeService: AgentRuntimeService

    @State private var pulseOpacity: Double = 0.5

    var body: some View {
        Group {
            if runtimeService.currentRetryAttempt > 0 && runtimeService.hasPendingErrors {
                HStack(spacing: 10) {
                    // Animated retry icon
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.neonCyan)
                        .rotationEffect(.degrees(pulseOpacity * 360))
                        .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: pulseOpacity)
                        .onAppear {
                            pulseOpacity = 1.0
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Retry: Attempt \(runtimeService.currentRetryAttempt)/\(runtimeService.maxRetryAttempts)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.neonCyan)

                        Text("Analyzing errors and applying fixes...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Progress indicator
                    ProgressView()
                        .scaleEffect(0.8)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.neonCyan.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.neonCyan.opacity(0.3), lineWidth: 1)
                )
            }
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 20) {
            // Executing state
            AgentExecutionView(
                intent: AgentIntent(type: .coding, description: "Create authentication", confidence: 0.9, rawMessage: ""),
                plan: ExecutionPlan(
                    intent: AgentIntent(type: .coding, description: "", confidence: 0.9, rawMessage: ""),
                    planSteps: [
                        PlanStep(index: 0, description: "Create AuthService.swift", actionIndices: [0], status: .completed),
                        PlanStep(index: 1, description: "Build project", actionIndices: [1], status: .inProgress)
                    ],
                    actions: [
                        ExecutableAction(type: .createFile, tool: nil, parameters: [:], description: "Create Auth", stepIndex: 0),
                        ExecutableAction(type: .toolCall, tool: "run_build", parameters: [:], description: "Build", stepIndex: 1)
                    ],
                    summary: "Creating authentication",
                    estimatedDuration: nil
                ),
                actionResults: [
                    ActionExecutionResult(
                        action: ExecutableAction(type: .createFile, tool: nil, parameters: [:], description: "Create Auth", stepIndex: 0),
                        success: true,
                        output: "Created file",
                        error: nil,
                        duration: 0.35,
                        metadata: nil
                    )
                ],
                currentActionIndex: 1,
                executionState: .executing
            )
        }
        .padding()
    }
    .background(Color.black)
}
