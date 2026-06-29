import SwiftUI
import MaiCore

// First-run onboarding: a brief explanation, the two permissions, the API keys into
// the Keychain, and the notes folder. Standard, HIG-correct steps with a clear
// primary action on each.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var step = 0
    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)

            Divider()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Text("Step \(step + 1) of \(steps)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if step < steps - 1 {
                    Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") { model.completeOnboarding() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 560)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcome
        case 1: permissions
        case 2: keys
        case 3: folder
        default: done
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles").font(.system(size: 52)).foregroundStyle(.tint)
            Text("Welcome to Mai").font(.largeTitle.bold())
            Text("Mai listens to your meetings and watches your screen, surfacing useful, glanceable cards and a meeting assistant. It rests as a small heads-up display at the top-right of your screen and opens into a full app when you need it.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("Your audio, transcript, and notes stay on your Mac.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Grant Permissions").font(.title.bold())
            Text("Mai needs Screen Recording (to watch the screen and capture system audio) and Microphone (to transcribe your own speech).")
                .foregroundStyle(.secondary)
            Button("Request Permissions") { model.requestPermissions() }.glassButtonStyle(prominent: true)
            Label(model.permissionStatus, systemImage: model.permissionStatus == "Granted" ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(model.permissionStatus == "Granted" ? .green : .secondary)
            Text("If a prompt does not appear, grant Mai under System Settings, Privacy and Security, in Screen and System Audio Recording and in Microphone, then relaunch Mai.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Your API Keys").font(.title.bold())
            Text("Mai uses your own keys, stored in the macOS Keychain. At minimum add Anthropic (assistant and cards), Soniox (transcription), and Gemini (screen reads and search).")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(["ANTHROPIC_API_KEY", "SONIOX_API_KEY", "GEMINI_API_KEY", "GOOGLE_PLACES_API_KEY", "HOTPEPPER_API_KEY", "GROQ_API_KEY"], id: \.self) { key in
                        OnboardingKeyRow(model: model, key: key)
                    }
                }
            }
            Button("Check Keys") { model.validateKeys() }
        }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a Notes Folder").font(.title.bold())
            Text("Mai saves each meeting as a formatted Word document and a Markdown transcript into a folder you choose.")
                .foregroundStyle(.secondary)
            HStack {
                Text(model.notesFolder?.path ?? "No folder chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                Button("Choose\u{2026}") { model.pickNotesFolder() }.glassButtonStyle(prominent: true)
            }
        }
    }

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(.green)
            Text("You are all set").font(.largeTitle.bold())
            Text("Mai now rests at the top-right of your screen and shows up when there is something relevant. Open the full app any time from the menu bar.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}

private struct OnboardingKeyRow: View {
    @ObservedObject var model: AppModel
    let key: String
    @State private var draft = ""
    private var label: String { key.replacingOccurrences(of: "_API_KEY", with: "").replacingOccurrences(of: "_", with: " ").capitalized }
    var body: some View {
        HStack {
            Text(label).frame(width: 130, alignment: .leading)
            SecureField((model.keyPresence[key] ?? false) ? "Stored" : "Paste key", text: $draft).textFieldStyle(.roundedBorder)
            Button("Save") { model.saveKey(draft, for: key); draft = "" }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
