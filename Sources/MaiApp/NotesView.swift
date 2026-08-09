import SwiftUI
import MaiCore

// The meeting notes view: start/stop note-taking with a visible processing state,
// and the list of saved meetings to open. Content layer: standard controls, no glass.
struct NotesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Button(model.noteTaking ? "Stop Note-Taking" : "Start Note-Taking") {
                    model.toggleNoteTaking()
                }
                .glassButtonStyle(prominent: model.noteTaking)
                .disabled(model.notesProcessing != nil)

                if model.noteTaking {
                    Label("Capturing the meeting", systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                }
                Button("Save Transcript") { model.saveSessionTranscriptNow() }
                    .disabled(model.sessionTranscriptLineCount == 0 && model.lastEndedSession == nil)
                    .help("Save what was said in this session as a plain transcript, with no write-up.")

                if let processing = model.notesProcessing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(processing + "\u{2026}").foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if model.notesFolder == nil {
                Label("Choose a notes folder in Settings to save meetings and transcripts to disk.", systemImage: "folder.badge.questionmark")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Divider()

            Text("Saved Meetings").font(.headline)
            if model.savedMeetings.isEmpty {
                Text("No saved meetings yet. Start note-taking, hold a short meeting, then stop to save one. Saved session transcripts appear here too.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.savedMeetings) { meeting in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(meeting.title).font(.body)
                                // A plain transcript is not verified notes, so it says so.
                                if meeting.isTranscriptOnly {
                                    Text("Transcript")
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(.quaternary))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(meeting.date, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { model.openSavedMeeting(meeting) }
                            .accessibilityLabel("Open \(meeting.title)")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .navigationTitle("Notes")
        .onAppear { model.refreshSavedMeetings() }
    }
}
