import SwiftUI

/// Banner showing the current project path and agent status in agent mode
struct AgentProjectBanner: View {
    let projectPath: String
    let stage: AgentPipelineManager.AgentStage
    let onChangeProject: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Agent indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(stageColor)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(stageColor.opacity(0.3), lineWidth: 2)
                            .scaleEffect(stage != .idle ? 1.5 : 1.0)
                            .opacity(stage != .idle ? 0 : 1)
                            .animation(
                                stage != .idle ?
                                    Animation.easeOut(duration: 1).repeatForever(autoreverses: false) :
                                    .default,
                                value: stage
                            )
                    )

                Text(stageText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(stageColor)
            }

            Text("|")
                .foregroundColor(.secondary.opacity(0.3))

            // Project folder
            Button(action: onChangeProject) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)

                    Text(projectName)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Click to change project folder: \(projectPath)")

            Spacer()

            // Stage-specific indicator
            if stage != .idle && stage != .complete {
                AgentActivityIndicator(stage: stage)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }

    private var stageColor: Color {
        switch stage {
        case .idle: return .green
        case .understanding: return .blue
        case .requirements: return .purple
        case .generating: return .orange
        case .building: return .yellow
        case .complete: return .green
        case .error: return .red
        }
    }

    private var stageText: String {
        switch stage {
        case .idle: return "Agent Ready"
        case .understanding: return "Understanding..."
        case .requirements: return "Planning..."
        case .generating: return "Coding..."
        case .building: return "Building..."
        case .complete: return "Complete"
        case .error: return "Error"
        }
    }
}

/// Animated activity indicator for agent stages
struct AgentActivityIndicator: View {
    let stage: AgentPipelineManager.AgentStage

    @State private var animationPhase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(stageColor)
                    .frame(width: 4, height: 4)
                    .opacity(index == animationPhase % 3 ? 1.0 : 0.3)
            }
        }
        .onAppear {
            startAnimation()
        }
    }

    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            animationPhase += 1
        }
    }

    private var stageColor: Color {
        switch stage {
        case .idle, .complete: return .green
        case .understanding: return .blue
        case .requirements: return .purple
        case .generating: return .orange
        case .building: return .yellow
        case .error: return .red
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        AgentProjectBanner(
            projectPath: "/Users/dev/MyProject",
            stage: .idle,
            onChangeProject: {}
        )

        AgentProjectBanner(
            projectPath: "/Users/dev/MyProject",
            stage: .generating,
            onChangeProject: {}
        )

        AgentProjectBanner(
            projectPath: "/Users/dev/MyProject",
            stage: .building,
            onChangeProject: {}
        )
    }
    .padding()
    .frame(width: 400)
}
