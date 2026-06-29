import SwiftUI
import MaiCore

// Settings, reachable with Command-comma and from the app. HIG-exact: a grouped Form
// with Sections and standard controls (Toggle, Picker, Slider, SecureField), title
// style labels, sentence-case helper text. Discrete changes apply live (the session
// rebuilds); sliders apply when you let go.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    // Sliders use local state so a drag does not rebuild the session on every frame.
    @State private var threshold: Double = 0.6
    @State private var onset: Double = 0.5
    @State private var offset: Double = 0.35
    @State private var hangover: Double = 4

    private func langBinding(_ keyPath: WritableKeyPath<Config, Language>) -> Binding<Language> {
        Binding(get: { model.config[keyPath: keyPath] }, set: { v in model.updateConfig { $0[keyPath: keyPath] = v } })
    }

    var body: some View {
        Form {
            Section("Languages") {
                Picker("Interface language", selection: langBinding(\.interfaceLanguage)) {
                    Text("English").tag(Language.en); Text("Japanese").tag(Language.ja); Text("Chinese").tag(Language.zh)
                }
                Picker("Floor language", selection: langBinding(\.floorLanguage)) {
                    Text("English").tag(Language.en); Text("Japanese").tag(Language.ja); Text("Chinese").tag(Language.zh)
                }
                Toggle("Meeting mode", isOn: Binding(get: { model.config.meetingMode }, set: { v in model.updateConfig { $0.meetingMode = v } }))
            }

            Section("Cards") {
                Toggle("Suggested replies", isOn: Binding(get: { model.responseEnabled }, set: { _ in model.toggleResponse() }))
                Toggle("Show suppressed cards", isOn: $model.showSuppressed)
                VStack(alignment: .leading) {
                    Text("Surfacing sensitivity")
                    Slider(value: $threshold, in: 0.3...0.9, step: 0.05) { editing in
                        if !editing { model.updateConfig { $0.threshold = threshold } }
                    }
                    Text("Lower surfaces more cards; higher is quieter.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Voice Activity") {
                Toggle("On-device voice-activity gating", isOn: Binding(get: { model.config.vadEnabled }, set: { v in model.updateConfig { $0.vadEnabled = v } }))
                slider("Speech onset", $onset, 0.2...0.9) { model.updateConfig { $0.vadOnset = onset } }
                slider("Silence offset", $offset, 0.1...0.8) { model.updateConfig { $0.vadOffset = offset } }
                slider("Silence hangover (seconds)", $hangover, 1...10, step: 1) { model.updateConfig { $0.vadSilenceHangoverSeconds = hangover } }
            }

            Section("Mission Mode") {
                Toggle("Keep the HUD pinned open", isOn: $model.missionPinned)
                LabeledContent("Summon shortcut") { HotkeyRecorder() }
                Text("A global shortcut that brings up Mission mode and focuses the ask field from any app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notes Folder") {
                HStack {
                    Text(model.notesFolder?.path ?? "Not chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose\u{2026}") { model.pickNotesFolder() }
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }

            Section("API Keys") {
                ForEach(Secrets.knownKeys, id: \.self) { key in
                    APIKeyRow(model: model, key: key)
                }
                HStack {
                    Button("Check Keys") { model.validateKeys() }
                    Spacer()
                    Text("Keys are stored in your macOS Keychain.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 460, minHeight: 520)
        .onAppear {
            threshold = model.config.threshold
            onset = model.config.vadOnset
            offset = model.config.vadOffset
            hangover = model.config.vadSilenceHangoverSeconds
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double = 0.05, commit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            Slider(value: value, in: range, step: step) { editing in if !editing { commit() } }
        }
    }
}

private struct APIKeyRow: View {
    @ObservedObject var model: AppModel
    let key: String
    @State private var draft = ""

    private var label: String {
        key.replacingOccurrences(of: "_API_KEY", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }
    private var status: String {
        if let s = model.keyStatus[key] { return s }
        return (model.keyPresence[key] ?? false) ? "Set" : "Not set"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(status).font(.caption).foregroundStyle(status == "Set" || status == "OK" ? .green : .secondary)
            }
            HStack {
                SecureField((model.keyPresence[key] ?? false) ? "Stored in Keychain" : "Paste your key", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { model.saveKey(draft, for: key); draft = "" }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.vertical, 2)
    }
}
