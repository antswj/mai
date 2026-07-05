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

    // The Mission mode HUD surface: the CLEAR Liquid Glass variant, the most
    // text-forward and glassiest, so the desktop and the call behind it read through
    // strongly. Falls back to a translucent material below macOS 26.
    @ViewBuilder
    func missionGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.clear, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func spatialPanel<S: InsettableShape>(in shape: S, shadowOpacity: Double = 0.20) -> some View {
        self
            .functionalGlass(in: shape)
            .overlay {
                if #available(macOS 26.0, *) {
                    EmptyView()
                } else {
                    shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.7)
                }
            }
            .shadow(color: .black.opacity(shadowOpacity), radius: 18, y: 8)
            .shadow(color: .white.opacity(0.10), radius: 1, y: -1)
    }

    func spatialContentTile<S: InsettableShape>(in shape: S, tint: Color = .secondary,
                                                suppressed: Bool = false) -> some View {
        self
            .background {
                ZStack {
                    Color(nsColor: .controlBackgroundColor).opacity(suppressed ? 0.20 : 0.34)
                    tint.opacity(suppressed ? 0.04 : 0.08)
                }
                .clipShape(shape)
            }
            .overlay(shape.strokeBorder(.white.opacity(suppressed ? 0.07 : 0.13), lineWidth: 0.6))
            .shadow(color: .black.opacity(suppressed ? 0.04 : 0.10), radius: 7, y: 3)
    }

    func visionContentBackground() -> some View {
        self.background {
            LinearGradient(colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .controlBackgroundColor).opacity(0.52),
                Color(nsColor: .windowBackgroundColor)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
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

struct SpatialIconButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: active ? .semibold : .regular))
            .frame(width: 26, height: 26)
            .background {
                Circle()
                    .fill(active ? Color.accentColor.opacity(0.18)
                          : Color.secondary.opacity(configuration.isPressed ? 0.16 : 0.08))
            }
            .overlay(Circle().strokeBorder(.white.opacity(active ? 0.24 : 0.10), lineWidth: 0.6))
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
