# Mai

Mai is an ambient awareness app for macOS. It listens to the microphone and the system
audio of a call, watches the screen, and surfaces small, sourced information cards in
real time. It is trilingual (English, Japanese, Chinese), shows a live transcript with
real speaker names and furigana or pinyin as true ruby, and can suggest a sentence to
say back in the language the other person is speaking.

Everything runs on your own accounts. You bring your own API keys, capture stays on
your machine, and there is no backend and no telemetry. The repo is the whole product.

## What it does

- **Live transcript.** Microphone and system audio are transcribed separately and merged
  into one speaker-attributed transcript. Remote speakers are named from the on-screen
  call tiles when possible. An optional Translate switch adds a same-speed translation
  line under each utterance.
- **Cards.** When something in the conversation or on the screen is worth surfacing, a
  card appears instantly and fills in live: local math and unit conversions, Wikipedia
  entities with images and sources (resolved across languages), grounded web answers with
  real links for anything current, and plain technical explanations. Nothing is ever
  fabricated; a lookup that finds nothing says so.
- **Suggested replies.** With the Reply toggle on, Mai drafts a response in the language
  being spoken, with furigana or pinyin and a translation. The conversation coach can
  also suggest a concrete sentence to say back to the other person, in their language,
  grounded in recognized communication frameworks. Suggestions are drafts you choose to
  say, adapt, or ignore. Both are off by default.
- **Voice coaching.** Vocal features (pace, pauses, energy, rough pitch) are computed
  locally from the audio; only that compact summary plus the transcript window is sent
  for analysis. It never claims anyone is lying or diagnoses intent; that is a hard
  filter, not a guideline.
- **Meeting notes.** Start note-taking, hold the meeting, stop: Mai writes structured
  notes, verifies every line against what was actually said, titles the meeting, and
  saves a .docx plus a timestamped Markdown transcript to a folder you choose.
- **Session transcripts.** Independent of note-taking, Mai can save a plain transcript
  (no model calls, just what was said) every time a session ends, or on demand with the
  Save Transcript button. Off by default.
- **Two faces.** A glassy heads-up panel at the top right that floats over every app,
  including full-screen calls, without stealing focus; and a full window with the
  transcript, cards, chat assistant, notes, and a spend meter. A menu bar item is the
  always-on anchor.
- **Cost control.** An on-device voice activity detector (Silero VAD, local ONNX) opens
  the transcription stream only while someone is speaking and tears it down in silence.
  A spend meter shows the estimated daily cost from local counts.
- **Self-watching capture.** Liveness is tracked per source. A dead microphone, a
  rejected transcription stream, or audio that is heard but never forwarded surfaces as
  an honest message in Health instead of a silent forever-"Capturing".
- **Echo suppression.** With speakers instead of headphones, remote voices are not
  transcribed twice: the mic copy is dropped by capture-time energy overlap plus text
  matching.

## Requirements

- macOS 15 or later, Swift 6 toolchain. Command Line Tools are enough; the Liquid Glass
  look needs the macOS 26 SDK and falls back to standard materials on older toolchains.
- Your own API keys: Anthropic or Groq (language), Soniox (real-time transcription,
  funded), Gemini (screen reads and grounded search), Google Places and Hot Pepper
  (nearby places). Each is optional except transcription; missing keys degrade features
  rather than break the app.
- First build fetches GRDB, ZIPFoundation, and ONNX Runtime once.

## Setup

For the app, keys are entered in onboarding and stored in the macOS Keychain, never a
file. For command line development, use a `.env`:

```
cp .env.example .env
git config core.hooksPath .githooks
```

Fill in the keys on the named lines. `.env` is gitignored; the pre-commit hook blocks
secrets and captured data from ever being committed.

## Run

Real capture needs Screen Recording and Microphone permissions, which only an app bundle
can hold:

```
./make-app.sh
open Mai.app
```

Grant both permissions, then quit and reopen (macOS applies Screen Recording after a
relaunch). If permission prompts stop appearing after rebuilds, create a self-signed
"Mai Dev" code-signing certificate in Keychain Access once, reset with
`tccutil reset ScreenCapture com.mai.app` and `tccutil reset Microphone com.mai.app`,
rebuild, and grant again; with a stable certificate the grants persist.

Without the bundle, `swift run Mai` runs a dev mode with typed input and no capture.

## Configure

`config.toml` is the tuning surface: providers and model ids, languages, surfacing
thresholds, voice activity gating, session rollover, transcript saving, coaching, echo
suppression. Every setting has a comment. The most useful:

- `[response] enabled`: the Reply toggle default (also a switch in the app).
- `[session] save_transcript`: write a plain transcript on every session end.
- `[surfacing] threshold` and `adaptive_quiet`: how chatty the cards are.
- `[providers] llm`: `anthropic` or `groq`, with model ids under `[models]`.

## Verify

```
swift run MaiTests        # deterministic acceptance harness, no network, exits non-zero on failure
swift test                # same behaviors as a swift-testing suite (needs full Xcode)
swift run MaiSmoke        # live checks against your real keys, per provider
```

Behavioral evals for the prompts (classifier, drafter, router, responder, coach, notes,
assistant) live in `Evals/` and run with promptfoo; see `Evals/README.md`. Scan for
secrets with `gitleaks git -v --exit-code 1 .`.

## Architecture

- `Sources/MaiCore`: the engine. Plain Swift, zero UI dependencies: transcript ingestion,
  triggers, the lookup router, card enrichment with hard timeouts, notes, transcripts,
  coaching, health policy, readings (furigana and pinyin), and all pure logic.
- `Sources/MaiCapture`: macOS capture. ScreenCaptureKit audio taps, Soniox streaming,
  on-device VAD gating, screen watching with a cheap frame diff, vision reads.
- `Sources/MaiApp`: SwiftUI faces. The floating panel, the full window, onboarding,
  settings, diagnostics.
- `Sources/MaiTests`: the acceptance harness executable. `Tests/`: the swift-testing
  mirror. `Evals/`: prompt evals.

## Privacy

Mai listens and watches continuously, so the captured audio, transcript, and screen reads
are sensitive. They stay local and leave the machine only as calls to your own provider
accounts. There is no telemetry. Voice activity detection runs entirely on device, so
audio streams out only while someone is speaking. Pause is a real valve: it tears down
capture and closes the transcription sockets; nothing is captured, transcribed, read, or
stored until you resume. Saving a session transcript is off by default and writes only to
the folder you chose. Vocal coaching features are computed locally; raw audio is never
uploaded for analysis. The store, logs, and every saved meeting file are gitignored.
See `SECURITY.md` for the full surface.

When Mai shows a place from Hot Pepper, it includes the required credit
"Powered by ホットペッパーグルメ Webサービス".

## License

MIT. See `LICENSE`.
