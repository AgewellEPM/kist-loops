import SwiftUI

/// Animated "Thinking..." indicator shown while the agent is analyzing
struct ThinkingIndicatorView: View {
    @State private var dotCount = 0
    @State private var pulseScale: CGFloat = 1.0

    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            // Animated brain icon
            ZStack {
                Circle()
                    .fill(Color.neonCyan.opacity(0.2))
                    .frame(width: 36, height: 36)
                    .scaleEffect(pulseScale)

                Image(systemName: "brain.head.profile")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.neonCyan)
            }
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseScale)
            .onAppear {
                pulseScale = 1.15
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Thinking" + String(repeating: ".", count: dotCount))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.neonCyan)
                    .frame(width: 100, alignment: .leading)

                Text("Analyzing your request and creating a plan...")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Spinning indicator
            ProgressView()
                .scaleEffect(0.8)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.cardBackground.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.neonCyan.opacity(0.3), lineWidth: 1)
        )
        .onReceive(timer) { _ in
            dotCount = (dotCount + 1) % 4
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ThinkingIndicatorView()
    }
    .padding()
    .background(Color.black)
}
