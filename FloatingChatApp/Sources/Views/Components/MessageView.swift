import SwiftUI

struct MessageView: View {
    let message: ChatMessage
    let onCopy: () -> Void
    let onRegenerate: () -> Void

    @State private var isHovering = false
    @State private var glowIntensity: Double = 0.3

    // Cycle through neon colors for variety
    private var glowColor: Color {
        let colors: [Color] = [.neonCyan, .neonPink, .neonPurple, .neonBlue]
        let index = abs(message.id.hashValue) % colors.count
        return colors[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Message content with markdown support
            if message.role == .assistant {
                // Assistant message with neon card effect
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownTextView(text: message.content)
                        .foregroundColor(.white.opacity(0.95))

                    // Action buttons for assistant messages
                    if !message.isStreaming {
                        MessageActionBar(
                            onRegenerate: onRegenerate,
                            onCopy: onCopy,
                            onSpeak: { speak(message.content) },
                            onThumbsUp: { /* feedback */ },
                            onThumbsDown: { /* feedback */ }
                        )
                        .opacity(isHovering ? 1 : 0.5)
                    } else {
                        // Streaming indicator - neon pulsing dots
                        NeonStreamingIndicator()
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    glowColor.opacity(isHovering ? 0.9 : 0.5),
                                    glowColor.opacity(isHovering ? 0.4 : 0.2),
                                    .clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isHovering ? 2 : 1
                        )
                )
                .shadow(color: glowColor.opacity(isHovering ? 0.5 : 0.2), radius: isHovering ? 20 : 10)
                .shadow(color: glowColor.opacity(0.15), radius: 30)
            } else {
                // User message with subtle neon effect
                Text(message.content)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.neonPurple.opacity(0.3),
                                        Color.neonPink.opacity(0.2)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.neonPink.opacity(0.6), Color.neonPurple.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.neonPink.opacity(0.3), radius: 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }

    private func speak(_ text: String) {
        // Use the SpeechOutputService for better control and preferences
        SpeechOutputService.shared.speak(text)
    }
}

// MARK: - Neon Streaming Indicator

struct NeonStreamingIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.neonCyan, .neonCyan.opacity(0.3)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 4
                        )
                    )
                    .frame(width: 6, height: 6)
                    .shadow(color: .neonCyan.opacity(0.8), radius: 4)
                    .shadow(color: .neonCyan.opacity(0.4), radius: 8)
                    .scaleEffect(isAnimating ? 1.2 : 0.8)
                    .opacity(isAnimating ? 1.0 : 0.6)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: isAnimating
                    )
            }
        }
        .padding(.top, 4)
        .onAppear {
            // Defer state change to avoid publishing during view update
            DispatchQueue.main.async {
                isAnimating = true
            }
        }
    }
}

// MARK: - Message Action Bar (Neon Style)

struct MessageActionBar: View {
    let onRegenerate: () -> Void
    let onCopy: () -> Void
    let onSpeak: () -> Void
    let onThumbsUp: () -> Void
    let onThumbsDown: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            NeonActionButton(icon: "arrow.clockwise", color: .neonCyan, action: onRegenerate, tooltip: "Regenerate")
            NeonActionButton(icon: "speaker.wave.2", color: .neonPurple, action: onSpeak, tooltip: "Read aloud")
            NeonActionButton(icon: "hand.thumbsup", color: .neonGreen, action: onThumbsUp, tooltip: "Good response")
            NeonActionButton(icon: "hand.thumbsdown", color: .neonOrange, action: onThumbsDown, tooltip: "Bad response")
            NeonActionButton(icon: "doc.on.doc", color: .neonPink, action: onCopy, tooltip: "Copy")
        }
        .padding(.top, 8)
    }
}

struct NeonActionButton: View {
    let icon: String
    let color: Color
    let action: () -> Void
    let tooltip: String

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isHovering ? color : .white.opacity(0.5))
                .shadow(color: isHovering ? color.opacity(0.8) : .clear, radius: 4)
                .shadow(color: isHovering ? color.opacity(0.5) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// Legacy ActionButton for compatibility
struct ActionButton: View {
    let icon: String
    let action: () -> Void
    let tooltip: String

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(isHovering ? .neonCyan : .white.opacity(0.5))
                .shadow(color: isHovering ? Color.neonCyan.opacity(0.6) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}
