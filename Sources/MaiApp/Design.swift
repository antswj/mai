import SwiftUI

// Liquid Glass belongs on the functional layer (chrome, controls, the Mission mode
// HUD surface, floating controls), never on the content layer (transcript, card, and
// note content stay content). These helpers apply it on macOS 26 and fall back to a
// standard material on older systems. Reduce Transparency and Reduce Motion are
// handled automatically by the system for the glass material; do not fight them.
extension View {
    @ViewBuilder
    func functionalGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

// Groups nearby glass shapes so they render together (glass cannot sample other
// glass). A passthrough on older systems.
struct GlassStack<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// The living presence: a calm, quiet glow that breathes while Mai is listening and
// brightens briefly when it is thinking. Organic motion, never busy.
struct LivingGlow: View {
    enum Presence { case listening, thinking, idle }
    var presence: Presence
    @State private var pulse = false

    private var color: Color {
        switch presence {
        case .listening: return .accentColor
        case .thinking: return .teal
        case .idle: return .secondary
        }
    }
    private var active: Bool { presence != .idle }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(active ? 0.85 : 0.25), radius: pulse ? 7 : 2)
            .scaleEffect(pulse ? 1.18 : 0.9)
            .opacity(active ? 1 : 0.5)
            .onAppear {
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) { pulse = true }
            }
            .accessibilityHidden(true)
    }
}
