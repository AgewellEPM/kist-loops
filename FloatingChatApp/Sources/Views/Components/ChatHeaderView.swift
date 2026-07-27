import SwiftUI

struct ChatHeaderView: View {
    let onClose: () -> Void
    let onCopy: () -> Void
    let onNewChat: () -> Void
    var onLibrary: (() -> Void)? = nil
    var showLibraryButton: Bool = false
    var isLibraryOpen: Bool = false
    var onTest: (() -> Void)? = nil

    var body: some View {
        HStack {
            // Close button with neon red glow on hover
            NeonHeaderButton(
                icon: "xmark",
                color: .neonPink,
                action: onClose,
                tooltip: "Close"
            )

            // Library button
            if showLibraryButton {
                NeonHeaderButton(
                    icon: isLibraryOpen ? "sidebar.left.fill" : "sidebar.left",
                    color: .neonCyan,
                    isActive: isLibraryOpen,
                    action: { onLibrary?() },
                    tooltip: isLibraryOpen ? "Hide Library" : "Show Library"
                )
            }

            Spacer()

            // Right side buttons with neon effects
            HStack(spacing: 10) {
                NeonHeaderButton(
                    icon: "doc.on.doc",
                    color: .neonPurple,
                    action: onCopy,
                    tooltip: "Copy conversation"
                )

                NeonHeaderButton(
                    icon: "square.and.pencil",
                    color: .neonCyan,
                    action: onNewChat,
                    tooltip: "New chat"
                )

                if let onTest = onTest {
                    NeonHeaderButton(
                        icon: "testtube.2",
                        color: .neonGreen,
                        action: onTest,
                        tooltip: "Run Tests"
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [
                    Color.headerBackground,
                    Color.headerBackground.opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            // Neon gradient line at bottom
            LinearGradient(
                colors: [Color.neonPurple.opacity(0.4), Color.neonCyan.opacity(0.4), Color.neonPink.opacity(0.4)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Neon Header Button

struct NeonHeaderButton: View {
    let icon: String
    let color: Color
    var isActive: Bool = false
    let action: () -> Void
    let tooltip: String

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive || isHovering ? color : .white.opacity(0.5))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(
                            isActive || isHovering
                                ? color.opacity(0.15)
                                : Color.white.opacity(0.05)
                        )
                )
                .overlay(
                    Circle()
                        .stroke(
                            isActive || isHovering ? color.opacity(0.5) : Color.clear,
                            lineWidth: 1
                        )
                )
                .shadow(color: isActive || isHovering ? color.opacity(0.5) : .clear, radius: 6)
                .shadow(color: isActive || isHovering ? color.opacity(0.3) : .clear, radius: 12)
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
