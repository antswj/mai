import SwiftUI

private enum GlassTuning {
    static func amount(_ value: Double) -> Double { min(1.0, max(0.0, value)) }
    static func backingOpacity(_ amount: Double, max: Double) -> Double { max * (1.0 - amount) }
    static func highlightOpacity(_ amount: Double) -> Double { 0.035 + (0.075 * amount) }
}

// Liquid Glass belongs on the functional layer (chrome, controls, the Mission mode
// HUD surface, floating controls), never on the content layer (transcript, card, and
// note content stay content). These helpers apply it on macOS 26 and fall back to a
// standard material on older systems. Reduce Transparency and Reduce Motion are
// handled automatically by the system for the glass material; do not fight them.
extension View {
    @ViewBuilder
    func functionalGlass<S: Shape>(in shape: S, amount: Double = 0.72) -> some View {
        let a = GlassTuning.amount(amount)
        Group {
            // Compile-time gate first: the glass symbols exist only in the macOS 26 SDK,
            // and #available is a runtime check. Toolchains older than the one shipping
            // that SDK (compiler 6.2) build the material fallback instead, which is what
            // lets this compile on CI runners with an older SDK.
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                if a < 0.35 {
                    self.glassEffect(.regular, in: shape)
                } else {
                    self.glassEffect(.clear, in: shape)
                }
            } else {
                if a > 0.70 {
                    self.background(.ultraThinMaterial, in: shape)
                } else if a > 0.35 {
                    self.background(.thinMaterial, in: shape)
                } else {
                    self.background(.regularMaterial, in: shape)
                }
            }
            #else
            if a > 0.70 {
                self.background(.ultraThinMaterial, in: shape)
            } else if a > 0.35 {
                self.background(.thinMaterial, in: shape)
            } else {
                self.background(.regularMaterial, in: shape)
            }
            #endif
        }
        .background {
            ZStack {
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(GlassTuning.backingOpacity(a, max: 0.28)))
                shape.fill(Color.white.opacity(GlassTuning.highlightOpacity(a)))
            }
        }
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        #endif
    }

    // The Mission mode HUD surface: the CLEAR Liquid Glass variant, the most
    // text-forward and glassiest, so the desktop and the call behind it read through
    // strongly. Falls back to a translucent material below macOS 26.
    @ViewBuilder
    func missionGlass<S: Shape>(in shape: S, amount: Double = 0.72) -> some View {
        let a = GlassTuning.amount(amount)
        Group {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                if a < 0.30 {
                    self.glassEffect(.regular, in: shape)
                } else {
                    self.glassEffect(.clear, in: shape)
                }
            } else {
                if a > 0.70 {
                    self.background(.ultraThinMaterial, in: shape)
                } else if a > 0.35 {
                    self.background(.thinMaterial, in: shape)
                } else {
                    self.background(.regularMaterial, in: shape)
                }
            }
            #else
            if a > 0.70 {
                self.background(.ultraThinMaterial, in: shape)
            } else if a > 0.35 {
                self.background(.thinMaterial, in: shape)
            } else {
                self.background(.regularMaterial, in: shape)
            }
            #endif
        }
        .background {
            ZStack {
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(GlassTuning.backingOpacity(a, max: 0.34)))
                shape.fill(Color.white.opacity(0.025 + (0.055 * a)))
            }
        }
    }

    @ViewBuilder
    func spatialPanel<S: InsettableShape>(in shape: S, shadowOpacity: Double = 0.20,
                                          glassAmount: Double = 0.72) -> some View {
        let a = GlassTuning.amount(glassAmount)
        self
            .functionalGlass(in: shape, amount: a)
            .overlay {
                if #available(macOS 26.0, *) {
                    EmptyView()
                } else {
                    shape.strokeBorder(.white.opacity(0.08 + (0.10 * a)), lineWidth: 0.7)
                }
            }
            .shadow(color: .black.opacity(shadowOpacity * (0.70 + (0.55 * a))),
                    radius: 12 + (10 * a), y: 5 + (5 * a))
            .shadow(color: .white.opacity(0.04 + (0.08 * a)), radius: 1 + a, y: -1)
    }

    func spatialContentTile<S: InsettableShape>(in shape: S, tint: Color = .secondary,
                                                suppressed: Bool = false,
                                                glassAmount: Double = 0.72) -> some View {
        let a = GlassTuning.amount(glassAmount)
        let baseOpacity = suppressed ? 0.18 + (0.08 * (1.0 - a)) : 0.42 - (0.16 * a)
        let tintOpacity = suppressed ? 0.03 + (0.02 * a) : 0.05 + (0.06 * a)
        return self
            .background {
                ZStack {
                    Color(nsColor: .controlBackgroundColor).opacity(baseOpacity)
                    tint.opacity(tintOpacity)
                }
                .clipShape(shape)
            }
            .overlay(shape.strokeBorder(.white.opacity((suppressed ? 0.05 : 0.08) + (0.08 * a)), lineWidth: 0.6))
            .shadow(color: .black.opacity(suppressed ? 0.03 + (0.02 * a) : 0.06 + (0.07 * a)),
                    radius: 5 + (5 * a), y: 2 + (2 * a))
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
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
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

// The living presence: a calm, quiet glow that breathes while Mai is listening,
// cools while finding, brightens while thinking, and goes still for private states.
// Organic motion, never busy.
struct LivingGlow: View {
    enum Presence: String {
        case listening, finding, thinking, muted, `private`, idle

        var label: String {
            switch self {
            case .listening: return "Listening"
            case .finding: return "Finding"
            case .thinking: return "Thinking"
            case .muted: return "Muted"
            case .private: return "Private"
            case .idle: return "Idle"
            }
        }

        var symbol: String {
            switch self {
            case .listening: return "waveform"
            case .finding: return "sparkle.magnifyingglass"
            case .thinking: return "sparkles"
            case .muted: return "mic.slash.fill"
            case .private: return "lock.fill"
            case .idle: return "circle"
            }
        }
    }

    var presence: Presence
    @State private var pulse = false

    private var color: Color {
        switch presence {
        case .listening: return .accentColor
        case .finding: return .blue
        case .thinking: return .teal
        case .muted: return .red
        case .private: return .purple
        case .idle: return .secondary
        }
    }
    private var active: Bool {
        switch presence {
        case .idle, .muted, .private: return false
        default: return true
        }
    }
    private var pulseDuration: Double {
        switch presence {
        case .thinking: return 0.9
        case .finding: return 1.2
        case .listening: return 1.7
        default: return 1.7
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(active ? 0.85 : 0.25), radius: pulse ? 7 : 2)
            .scaleEffect(pulse ? 1.18 : 0.9)
            .opacity(active ? 1 : 0.5)
            .animation(.easeInOut(duration: 0.22), value: presence)
            .onAppear {
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                withAnimation(.easeInOut(duration: pulseDuration).repeatForever(autoreverses: true)) { pulse = true }
            }
            .onChange(of: presence) {
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                pulse = false
                withAnimation(.easeInOut(duration: pulseDuration).repeatForever(autoreverses: true)) { pulse = active }
            }
            .accessibilityHidden(true)
    }
}

struct PresenceChip: View {
    var presence: LivingGlow.Presence
    var glassAmount: Double = 0.72

    var body: some View {
        HStack(spacing: 7) {
            LivingGlow(presence: presence)
            Image(systemName: presence.symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 13)
            Text(presence.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .spatialPanel(in: Capsule(), shadowOpacity: 0.06, glassAmount: glassAmount)
        .animation(.easeInOut(duration: 0.22), value: presence)
        .accessibilityLabel("Mai \(presence.label)")
    }
}
