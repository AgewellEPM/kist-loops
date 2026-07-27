import SwiftUI

// MARK: - Synthwave Neon Theme

extension Color {
    // Deep dark background with slight purple tint
    static let chatBackground = Color(nsColor: NSColor(calibratedRed: 0.05, green: 0.03, blue: 0.08, alpha: 1.0))

    // Header with subtle gradient base
    static let headerBackground = Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.05, blue: 0.12, alpha: 1.0))

    // Input area - slightly lighter
    static let inputAreaBackground = Color(nsColor: NSColor(calibratedRed: 0.06, green: 0.04, blue: 0.10, alpha: 1.0))

    // Input field - with subtle depth
    static let inputBackground = Color(nsColor: NSColor(calibratedRed: 0.10, green: 0.07, blue: 0.15, alpha: 1.0))

    // User message - purple tinted
    static let userMessageBackground = Color(nsColor: NSColor(calibratedRed: 0.15, green: 0.10, blue: 0.22, alpha: 1.0))

    // Code block - deep dark
    static let codeBackground = Color(nsColor: NSColor(calibratedRed: 0.04, green: 0.02, blue: 0.06, alpha: 1.0))

    // Original accent (send button)
    static let accentOrange = Color(nsColor: NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.2, alpha: 1.0))

    // MARK: - Neon Colors

    // Neon Pink / Magenta
    static let neonPink = Color(nsColor: NSColor(calibratedRed: 1.0, green: 0.2, blue: 0.6, alpha: 1.0))

    // Neon Cyan / Electric Blue
    static let neonCyan = Color(nsColor: NSColor(calibratedRed: 0.0, green: 0.95, blue: 0.95, alpha: 1.0))

    // Neon Purple
    static let neonPurple = Color(nsColor: NSColor(calibratedRed: 0.7, green: 0.2, blue: 1.0, alpha: 1.0))

    // Neon Blue
    static let neonBlue = Color(nsColor: NSColor(calibratedRed: 0.2, green: 0.4, blue: 1.0, alpha: 1.0))

    // Neon Orange (hot)
    static let neonOrange = Color(nsColor: NSColor(calibratedRed: 1.0, green: 0.4, blue: 0.1, alpha: 1.0))

    // Neon Green (matrix)
    static let neonGreen = Color(nsColor: NSColor(calibratedRed: 0.2, green: 1.0, blue: 0.4, alpha: 1.0))

    // Neon Yellow
    static let neonYellow = Color(nsColor: NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.2, alpha: 1.0))

    // Card background with glow-ready dark
    static let cardBackground = Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.05, blue: 0.12, alpha: 0.95))

    // Grid lines color
    static let gridLine = Color(nsColor: NSColor(calibratedRed: 0.3, green: 0.1, blue: 0.5, alpha: 0.3))
}

extension NSColor {
    static let chatBackground = NSColor(calibratedRed: 0.05, green: 0.03, blue: 0.08, alpha: 1.0)
}

// MARK: - Neon Glow Effects

struct NeonGlow: ViewModifier {
    let color: Color
    let radius: CGFloat
    let intensity: CGFloat

    init(color: Color = .neonCyan, radius: CGFloat = 20, intensity: CGFloat = 1.0) {
        self.color = color
        self.radius = radius
        self.intensity = intensity
    }

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.8 * intensity), radius: radius * 0.3)
            .shadow(color: color.opacity(0.6 * intensity), radius: radius * 0.6)
            .shadow(color: color.opacity(0.4 * intensity), radius: radius)
    }
}

struct NeonBorder: ViewModifier {
    let color: Color
    let width: CGFloat
    let cornerRadius: CGFloat

    init(color: Color = .neonCyan, width: CGFloat = 1.5, cornerRadius: CGFloat = 12) {
        self.color = color
        self.width = width
        self.cornerRadius = cornerRadius
    }

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(color, lineWidth: width)
            )
            .shadow(color: color.opacity(0.6), radius: 8)
            .shadow(color: color.opacity(0.4), radius: 16)
    }
}

struct NeonCard: ViewModifier {
    let glowColor: Color
    let cornerRadius: CGFloat

    init(glowColor: Color = .neonPurple, cornerRadius: CGFloat = 16) {
        self.glowColor = glowColor
        self.cornerRadius = cornerRadius
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        LinearGradient(
                            colors: [glowColor.opacity(0.8), glowColor.opacity(0.3), glowColor.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: glowColor.opacity(0.4), radius: 12)
            .shadow(color: glowColor.opacity(0.2), radius: 24)
    }
}

struct PulsingGlow: ViewModifier {
    let color: Color
    @State private var isAnimating = false

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(isAnimating ? 0.8 : 0.4), radius: isAnimating ? 20 : 10)
            .shadow(color: color.opacity(isAnimating ? 0.5 : 0.2), radius: isAnimating ? 30 : 15)
            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isAnimating)
            .onAppear {
                DispatchQueue.main.async {
                    isAnimating = true
                }
            }
    }
}

struct SynthwaveGradient: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.02, blue: 0.1),
                        Color(red: 0.1, green: 0.02, blue: 0.15),
                        Color(red: 0.08, green: 0.02, blue: 0.12)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

// MARK: - View Extensions

extension View {
    func neonGlow(color: Color = .neonCyan, radius: CGFloat = 20, intensity: CGFloat = 1.0) -> some View {
        modifier(NeonGlow(color: color, radius: radius, intensity: intensity))
    }

    func neonBorder(color: Color = .neonCyan, width: CGFloat = 1.5, cornerRadius: CGFloat = 12) -> some View {
        modifier(NeonBorder(color: color, width: width, cornerRadius: cornerRadius))
    }

    func neonCard(glowColor: Color = .neonPurple, cornerRadius: CGFloat = 16) -> some View {
        modifier(NeonCard(glowColor: glowColor, cornerRadius: cornerRadius))
    }

    func pulsingGlow(color: Color = .neonPink) -> some View {
        modifier(PulsingGlow(color: color))
    }

    func synthwaveBackground() -> some View {
        modifier(SynthwaveGradient())
    }
}
