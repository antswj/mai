import SwiftUI
import MaiCore

// Stands in for the real always-on capture (audio + screen), which arrives later.
// Type a line (optionally "Name: text" to set the speaker), inject a changed screen
// read, replay a scripted fixture, or generate a session summary on demand.
struct SimulatedInputView: View {
    @ObservedObject var model: AppModel
    @State private var line: String = ""
    @State private var screenText: String = ""
    @State private var selectedFixture: String = "meeting_ja_en.txt"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mai").font(.title2.bold())
            Text(model.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            GroupBox("Say a line") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("e.g. Tanaka: 田中さん、ご意見をお願いできますか？", text: $line, onCommit: send)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text("Prefix with \"Name:\" to set the speaker.").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Send", action: send).keyboardShortcut(.return, modifiers: [])
                    }
                }.padding(6)
            }

            GroupBox("Screen (always-seeing)") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("e.g. slide 2: Q3 revenue up 18%", text: $screenText)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("Set screen (new slide)") {
                            model.injectScreen(screenText)
                        }
                    }
                }.padding(6)
            }

            GroupBox("Replay a fixture") {
                HStack {
                    Picker("", selection: $selectedFixture) {
                        ForEach(model.fixtures, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                    Button("Load") { model.loadFixture(selectedFixture) }
                }.padding(6)
            }

            HStack {
                Button("Summarize session") { model.summarize() }
                Spacer()
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 320)
    }

    private func send() {
        model.injectLine(line)
        line = ""
    }
}
