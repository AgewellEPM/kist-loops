import SwiftUI

/// UI for selecting and viewing agent teams
struct TeamPickerView: View {
    @Binding var selectedTeamId: String
    let onDismiss: () -> Void

    @State private var showingCustomTeam = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Agent Team")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.secondary.opacity(0.1))

            // Team list
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(AgentTeam.allPresets) { team in
                        TeamCard(
                            team: team,
                            isSelected: selectedTeamId == team.id,
                            onSelect: {
                                selectedTeamId = team.id
                            }
                        )
                    }
                }
                .padding()
            }

            // Info footer
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("Teams work together to plan, code, and review")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
        }
        .frame(width: 400, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

/// Card showing a team configuration
struct TeamCard: View {
    let team: AgentTeam
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                // Header row
                HStack {
                    Image(systemName: team.iconName)
                        .font(.title2)
                        .foregroundColor(isSelected ? .white : .accentColor)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(team.name)
                            .font(.headline)
                            .foregroundColor(isSelected ? .white : .primary)
                        Text(team.description)
                            .font(.caption)
                            .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.white)
                    }
                }

                // Agents row
                HStack(spacing: 4) {
                    ForEach(team.agents) { agent in
                        AgentBadge(agent: agent, compact: true)
                    }
                    Spacer()
                }

                // Mode indicator
                HStack {
                    Image(systemName: modeIcon(team.orchestrationMode))
                        .font(.caption2)
                    Text(modeDescription(team.orchestrationMode))
                        .font(.caption2)
                }
                .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
            }
            .padding(12)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.1))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private func modeIcon(_ mode: AgentTeam.OrchestrationMode) -> String {
        switch mode {
        case .sequential: return "arrow.right"
        case .parallel: return "arrow.triangle.branch"
        case .collaborative: return "person.3.sequence"
        case .debate: return "bubble.left.and.bubble.right"
        }
    }

    private func modeDescription(_ mode: AgentTeam.OrchestrationMode) -> String {
        switch mode {
        case .sequential: return "Sequential: One at a time"
        case .parallel: return "Parallel: All at once"
        case .collaborative: return "Collaborative: Lead delegates"
        case .debate: return "Debate: Discuss & consensus"
        }
    }
}

/// Small badge showing an agent in the team
struct AgentBadge: View {
    let agent: AgentTeam.AgentTeamMember
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(providerColor)
                .frame(width: 8, height: 8)

            if !compact {
                Text(agent.provider.capitalized)
                    .font(.caption2)
            }

            Text(roleEmoji)
                .font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.15))
        .cornerRadius(4)
    }

    private var providerColor: Color {
        switch agent.provider {
        case "claude": return .orange
        case "gpt", "openai": return .green
        case "deepseek": return .blue
        case "mlx": return Color(red: 0.2, green: 0.8, blue: 0.4)
        case "ollama": return .purple
        default: return .gray
        }
    }

    private var roleEmoji: String {
        switch agent.role {
        case .lead: return "👑"
        case .coder: return "💻"
        case .reviewer: return "🔍"
        case .researcher: return "📚"
        case .builder: return "🔨"
        }
    }
}

/// Banner showing current team in chat view
struct TeamBanner: View {
    let team: AgentTeam
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: team.iconName)
                    .font(.system(size: 12))

                Text(team.name)
                    .font(.system(size: 11, weight: .medium))

                Spacer()

                // Show agent badges
                HStack(spacing: 2) {
                    ForEach(team.agents.prefix(4)) { agent in
                        Circle()
                            .fill(agentColor(agent.provider))
                            .frame(width: 6, height: 6)
                    }
                    if team.agents.count > 4 {
                        Text("+\(team.agents.count - 4)")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func agentColor(_ provider: String) -> Color {
        switch provider {
        case "claude": return .orange
        case "gpt", "openai": return .green
        case "deepseek": return .blue
        case "mlx": return Color(red: 0.2, green: 0.8, blue: 0.4)
        case "ollama": return .purple
        default: return .gray
        }
    }
}

#Preview {
    TeamPickerView(
        selectedTeamId: .constant("coding-duo"),
        onDismiss: {}
    )
}
