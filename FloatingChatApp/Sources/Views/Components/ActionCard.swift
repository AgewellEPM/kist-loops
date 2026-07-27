import SwiftUI

/// Shows an individual action with its status, duration, and result
struct ActionCard: View {
    let action: ExecutableAction
    let result: ActionExecutionResult?
    let isExecuting: Bool

    @State private var isExpanded = false
    @State private var pulseOpacity: Double = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main row
            HStack(spacing: 10) {
                // Status indicator
                StatusIndicator(
                    isExecuting: isExecuting,
                    success: result?.success
                )

                // Action info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // Action type badge
                        Text(action.type.rawValue.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(Color.secondary.opacity(0.2))
                            )

                        // Tool name if present
                        if let tool = action.tool {
                            Text(tool)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.neonOrange)
                        }
                    }

                    // Description
                    Text(action.description)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(isExpanded ? nil : 1)
                }

                Spacer()

                // Duration badge (if completed)
                if let result = result {
                    DurationBadge(duration: result.duration)
                } else if isExecuting {
                    // Elapsed time counter
                    ElapsedTimeView()
                }

                // Expand button
                if result != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Expanded result view
            if isExpanded, let result = result {
                ActionResultView(result: result)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(cardBackground)
        .cornerRadius(8)
        .overlay(executingBorder)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.cardBackground.opacity(0.7))
    }

    @ViewBuilder
    private var executingBorder: some View {
        if isExecuting {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.neonCyan, lineWidth: 2)
                .opacity(pulseOpacity)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseOpacity)
                .onAppear {
                    pulseOpacity = 1.0
                }
        } else if let result = result {
            RoundedRectangle(cornerRadius: 8)
                .stroke(result.success ? Color.green.opacity(0.3) : Color.red.opacity(0.3), lineWidth: 1)
        }
    }
}

/// Animated status indicator
struct StatusIndicator: View {
    let isExecuting: Bool
    let success: Bool?

    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
                .frame(width: 24, height: 24)

            if isExecuting {
                // Spinning loader
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Color.neonCyan, lineWidth: 2)
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(rotation))
                    .onAppear {
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(iconColor)
            }
        }
    }

    private var backgroundColor: Color {
        if isExecuting {
            return Color.neonCyan.opacity(0.2)
        } else if let success = success {
            return success ? Color.green.opacity(0.2) : Color.red.opacity(0.2)
        }
        return Color.gray.opacity(0.2)
    }

    private var iconName: String {
        if let success = success {
            return success ? "checkmark" : "xmark"
        }
        return "circle"
    }

    private var iconColor: Color {
        if let success = success {
            return success ? .green : .red
        }
        return .gray
    }
}

/// Shows duration in a compact format
struct DurationBadge: View {
    let duration: TimeInterval

    var body: some View {
        Text(formatDuration(duration))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
            )
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

/// Live elapsed time counter
struct ElapsedTimeView: View {
    @State private var elapsed: TimeInterval = 0
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(String(format: "%.1fs", elapsed))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.neonCyan)
            .onReceive(timer) { _ in
                elapsed += 0.1
            }
    }
}

/// Expanded result details
struct ActionResultView: View {
    let result: ActionExecutionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            if !result.output.isEmpty {
                Text("Output:")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)

                ScrollView(.vertical, showsIndicators: true) {
                    Text(result.output.prefix(1000))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .padding(8)
                .background(Color.black.opacity(0.3))
                .cornerRadius(4)
            }

            if let error = result.error {
                Text("Error:")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.red)

                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.red.opacity(0.8))
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(4)
            }
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        ActionCard(
            action: ExecutableAction(
                type: .createFile,
                tool: nil,
                parameters: ["path": "Sources/Auth.swift"],
                description: "Create AuthService.swift",
                stepIndex: 0
            ),
            result: ActionExecutionResult(
                action: ExecutableAction(type: .createFile, tool: nil, parameters: [:], description: "", stepIndex: 0),
                success: true,
                output: "Created file: Sources/Auth.swift",
                error: nil,
                duration: 0.342,
                metadata: nil
            ),
            isExecuting: false
        )

        ActionCard(
            action: ExecutableAction(
                type: .toolCall,
                tool: "run_build",
                parameters: [:],
                description: "Build project",
                stepIndex: 1
            ),
            result: nil,
            isExecuting: true
        )
    }
    .padding()
    .background(Color.black)
}
