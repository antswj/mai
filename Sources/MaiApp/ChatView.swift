import SwiftUI
import MaiCore

// The meeting assistant chat. The transcript so far is injected as context when the
// user asks; while this is on screen, info and fact cards pause but reply cards keep
// running (handled by the engine). Used both as the compact inline chat in Mission
// mode and the full chat in the app. Content layer: plain, no glass.
struct ChatView: View {
    @ObservedObject var model: AppModel
    var compact = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if model.chat.isEmpty {
                            Text("Ask about the meeting, for example \u{201C}What are they talking about?\u{201D}")
                                .font(compact ? .caption : .callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(model.chat) { message in
                            ChatBubble(message: message, compact: compact).id(message.id)
                        }
                        if model.assistantThinking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Thinking\u{2026}").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: model.chat.count) {
                    if let last = model.chat.last { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            HStack(spacing: 8) {
                TextField("Ask about the meeting", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($fieldFocused)
                    .onSubmit(send)
                Button("Send", action: send)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { model.openChat(); fieldFocused = true }
        .onDisappear { model.closeChat() }
    }

    private func send() {
        let text = draft
        draft = ""
        model.sendChat(text)
        fieldFocused = true
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    var compact: Bool
    var body: some View {
        HStack(alignment: .top) {
            if message.role == .assistant {
                Text(message.text)
                    .font(compact ? .caption : .body)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                Spacer(minLength: 28)
            } else {
                Spacer(minLength: 28)
                Text(message.text)
                    .font(compact ? .caption : .body)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
