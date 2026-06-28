# Mai

Mai is an ambient, real-time awareness engine. It continuously listens to a meeting
or conversation and watches a screen, and surfaces relevant, useful, or delightful
information as small, glanceable cards. The core loop is **trigger, then lookup,
then card**.

Mai now does real, always-on capture: it listens to your microphone and the system
audio (remote call participants) and transcribes both live with Soniox, and it
watches the screen and reads it with Gemini when it meaningfully changes. It is
trilingual (English, Japanese, Chinese), with a live transcript view (Apple Music
lyrics style, with real speaker names and furigana/pinyin shown as true ruby above
the characters) and a dual-language meeting mode that prepares suggested replies in
the floor language.

Clone it, add your own API keys, build the app bundle, grant two permissions, and it
works. (Run unbundled with `swift run Mai` and it degrades to a typed-input dev mode.)

## What is in here

- A platform-agnostic engine in plain Swift (`Sources/MaiCore`) with zero
  UI-framework dependencies, so it can move to a device later.
- Real capture in `Sources/MaiCapture` (macOS): ScreenCaptureKit microphone and
  system audio, Soniox streaming transcription, low-rate screen watching with a
  cheap frame-diff, and Gemini screen reads. It implements the engine's `Ears` and
  `Eyes` contracts, so the brain is unchanged.
- A SwiftUI app (`Sources/MaiApp`): the card stream, the always-on live transcript,
  a capture indicator, and a pause control. A debug toggle uses simulated input.
- Real lookups over HTTP: an LLM (Anthropic by default, Groq as an alternative),
  Google Places (New) plus Recruit Hot Pepper for nearby places, and Google Gemini.
- A local, exportable session store (SQLite via GRDB) and an append-only raw log.
- Automated tests, behavioral LLM-as-judge evals, live smoke checks, and a secrets scan.

## Requirements

- macOS 15 or later with Swift 6.x. Command Line Tools are enough (full Xcode is
  optional). Check with `swift --version`.
- Your own API keys (see below). Each user brings their own; nothing is shared.
- A funded Soniox account for live transcription (Soniox is pay-as-you-go; an empty
  balance returns a clear error and no transcript).

## Setup

1. Enter the workspace:

   ```
   cd ~/mai
   ```

2. Copy the example env file and paste your keys on the exact named lines:

   ```
   cp .env.example .env
   ```

   Then open `.env` and fill in:

   - `ANTHROPIC_API_KEY`
   - `GROQ_API_KEY`
   - `GEMINI_API_KEY`
   - `GOOGLE_PLACES_API_KEY` (enable "Places API (New)" on this key's Google Cloud project)
   - `HOTPEPPER_API_KEY`
   - `SONIOX_API_KEY` (real-time speech to text; fund the account for live transcripts)

   `.env` is gitignored and must never be committed.

3. Enable the pre-commit safety hook (one time):

   ```
   git config core.hooksPath .githooks
   ```

## Run the app with real capture

Real capture needs Screen Recording and Microphone permissions, which only a proper
app bundle can hold. Build the bundle and open it:

```
cd ~/mai
./make-app.sh
open Mai.app
```

The first launch prompts for **Screen Recording** and **Microphone**. Grant both,
then quit and reopen `Mai.app` (macOS requires a relaunch after granting Screen
Recording). If a prompt does not appear, grant them manually in System Settings,
Privacy and Security: add `Mai` under **Screen and System Audio Recording** and under
**Microphone**, then relaunch.

(Ad-hoc grants reset on each rebuild. To make them persist, create a self-signed code
signing certificate named `Mai Dev` in Keychain Access, then build with
`SIGN_ID="Mai Dev" ./make-app.sh`.)

The window has a capture bar at the top (a colored indicator, a **Pause** button, and
a **Simulated** debug toggle), the live transcript in the middle, and the card stream
on the right. The card stream shows each card with a colored tier badge, the title,
the body, an action button when there is one (for example "Open in Maps"), and small
secondary detail (trigger type, score, latency). A toggle hides suppressed cards.

## Run unbundled (dev mode, no capture)

```
swift run Mai
```

Run this way, Mai has no permissions, so it degrades to **simulated input**: a left
panel lets you type a line (prefix with `Name:` to set the speaker), inject a screen
change, replay a scripted fixture, or summarize the session. This is the path for
quick testing without a microphone or live transcription.

## What to try, step by step

With real capture (`open Mai.app`, permissions granted):

1. Open the live transcript and speak. Watch lines appear with the active line
   emphasized and earlier lines dimming, each labeled with the speaker. In a Japanese
   or Chinese meeting, furigana and pinyin appear as true ruby above the characters.
2. In a grid-view call (Zoom, Meet, Teams), confirm remote people get named from the
   on-screen tiles; your own mic speech is labeled as you.
3. Speak a mixed-language line such as `ngl ちょっとお寿司を食べたい気分` and watch the
   transcript and then a nearby-sushi card with a real maps link.
4. Open a slideshow, advance a slide, and watch the screen card appear after the
   screen settles; a tiny scroll or cursor move does not trigger a read. Then say a
   screen cue such as `画面を見てください`.
5. Press **Pause** and confirm capturing stops (the indicator changes and nothing new
   appears); press Resume to continue.

With simulated input (`swift run Mai`), the same flows work with typed lines: try a
sushi line, a `Sato: ご意見をお願いできますか？` reference (a Japanese suggested reply
with ruby and a translation), and `floor = "zh"` in `config.toml` to see pinyin.

## Tune the noise

Open `config.toml`:

- Raise `[surfacing] threshold` for fewer cards, lower it for more.
- Keep `show_suppressed_log = true` to watch what was filtered while you tune.
- Switch the LLM provider with `[providers] llm` (`anthropic` or `groq`). If you set
  `groq`, also set `[models] classifier = "openai/gpt-oss-20b"` and
  `drafter = "openai/gpt-oss-120b"`.

Model names, providers, languages, latency targets, and the test location all live
in `config.toml`, so a change is one edit plus a restart.

## Automated checks

- **Acceptance harness** (runs everywhere, including Command Line Tools only):

  ```
  swift run MaiTests
  ```

  This drives the engine through every canonical example plus the step-2 capture
  logic (local furigana/pinyin, ruby segmentation, the Soniox token parser, the
  frame-diff, speaker naming, and the audio converter) with deterministic stubs and
  fakes (no network, no microphone, no screen) and exits non-zero on any failure.

- **`swift test`**: the same behaviors are also written as a swift-testing suite.
  `swift test` uses Apple's testing framework, which ships with full Xcode. With
  Command Line Tools only it cannot run, so use `swift run MaiTests` there.

- **Behavioral evals** (LLM-as-judge): see `Evals/README.md`. In short:

  ```
  cd ~/mai && export ANTHROPIC_API_KEY="$(grep '^ANTHROPIC_API_KEY=' .env | cut -d= -f2-)"
  cd Evals && promptfoo eval -c promptfooconfig.yaml && promptfoo eval -c promptfooconfig.drafter.yaml
  ```

- **Live smoke tests** (validate your keys end to end against the real APIs):

  ```
  swift run MaiSmoke          # all
  swift run MaiSmoke llm      # Anthropic + Groq
  swift run MaiSmoke places   # real Google + Hot Pepper merge, query "sushi"
  swift run MaiSmoke vision   # Gemini reads a small embedded image
  swift run MaiSmoke soniox   # makes speech with `say`, transcribes it via Soniox
  swift run MaiSmoke screen   # Gemini reads a generated slide
  ```

  The `soniox` check needs a funded Soniox account; with an empty balance it prints
  the Soniox error (account balance exhausted) rather than a transcript, which still
  confirms the connection and auth work.

- **Secrets scan** (requires [gitleaks](https://github.com/gitleaks/gitleaks)):

  ```
  gitleaks git -v --exit-code 1 .
  ```

  This scans the committed history; a fresh clone has none. (`gitleaks dir .`
  scans working files too and will flag your local `.env`, which is expected and
  gitignored.)

## Privacy

Mai listens and watches continuously, so the captured audio, transcript, and screen
reads are sensitive. They stay **local only** and never leave your machine, except as
calls to your own Soniox (transcription) and Gemini (screen read) accounts. There is
no telemetry, and Mai excludes its own audio from capture. The **Pause** button is a
real privacy valve: it stops capture and closes the transcription sockets, so nothing
is captured, transcribed, read, or stored until you resume. The local store and raw
log are gitignored; participant names inferred from the screen are session-only.

When Mai shows a place from Hot Pepper, it includes the required credit
"Powered by ホットペッパーグルメ Webサービス".

## License

MIT. See `LICENSE`.
