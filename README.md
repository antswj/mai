# Mai

Mai is an ambient, real-time awareness engine. It continuously listens to a meeting
or conversation and watches a screen, and surfaces relevant, useful, or delightful
information as small, glanceable cards. The core loop is **trigger, then lookup,
then card**.

This is the first working version: the engine (the "brain") is real and fully
wired, with a minimal SwiftUI app and simulated input standing in for real
microphone and screen capture (those arrive in a later step behind the same
contracts). It is trilingual (English, Japanese, Chinese), with a dual-language
meeting mode that prepares suggested replies in the floor language with reading aids
(furigana for Japanese, pinyin for Chinese) and a translation underneath.

Clone it, add your own API keys, and it works.

## What is in here

- A platform-agnostic engine in plain Swift (`Sources/MaiCore`) with zero
  UI-framework dependencies, so it can move to a device later.
- A SwiftUI app (`Sources/MaiApp`) that shows the card stream and lets you simulate
  speech and screen changes.
- Real lookups over HTTP: an LLM (Anthropic by default, Groq as an alternative),
  Google Places (New) plus Recruit Hot Pepper for nearby places, and Google Gemini
  for reading an image (used by the smoke test now).
- A local, exportable session store (SQLite via GRDB) and an append-only raw log.
- Automated tests, behavioral LLM-as-judge evals, and a secrets scan.

## Requirements

- macOS with Swift 6.x. Command Line Tools are enough (full Xcode is optional).
  Check with `swift --version`.
- Your own API keys (see below). Each user brings their own; nothing is shared.

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

   `.env` is gitignored and must never be committed.

3. Enable the pre-commit safety hook (one time):

   ```
   git config core.hooksPath .githooks
   ```

## Run the app

The simplest path is the terminal:

```
swift run Mai
```

A window opens with two panes. (If you prefer Xcode, you can also open the folder's
`Package.swift` in Xcode and press Run.)

The left pane stands in for the real always-on capture, which arrives later:

- **Say a line**: type into the field and press Send. Prefix with `Name:` to set the
  speaker, for example `Sato: それでは、ご意見をお願いできますか？`.
- **Screen (always-seeing)**: type some screen text and press "Set screen (new
  slide)" to inject a changed screen read. Mai stores it silently; it only surfaces
  it when someone points at the screen.
- **Replay a fixture**: pick a scripted sample meeting and press Load.
- **Summarize session**: generate a short session summary on demand.

The right pane is the card stream, newest first. Each card shows a colored tier
badge, the title, the body, an action button when there is one (for example "Open in
Maps"), and small secondary detail (trigger type, score, latency). A toggle shows or
hides the quietly-suppressed cards so you can tune the noise filter.

## What to try, step by step

1. Replay `meeting_ja_en.txt` and watch cards fire on the interesting moments while
   the boring lines stay quiet.
2. Type a mixed-language sushi line such as `ngl ちょっとお寿司を食べたい気分` and
   see the best nearby pick, with a real maps link.
3. Set screen text twice (two "slides"), then type a line that points at the screen
   such as `画面を見てください` and watch the current screen card appear (it shows
   the latest slide, not the stale one).
4. With meeting mode on, type a line where someone asks you to respond, such as
   `Sato: ご意見をお願いできますか？`, and see a suggested Japanese reply with
   furigana and an English translation.
5. Switch `floor` to `zh` in `config.toml`, restart, and try `你怎么看？` to see
   pinyin instead.

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

  This drives the engine through every canonical example with deterministic stubs
  (no network) and exits non-zero on any failure.

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
  ```

- **Secrets scan** (requires [gitleaks](https://github.com/gitleaks/gitleaks)):

  ```
  gitleaks git -v --exit-code 1 .
  ```

  This scans the committed history; a fresh clone has none. (`gitleaks dir .`
  scans working files too and will flag your local `.env`, which is expected and
  gitignored.)

## Privacy

Mai listens and watches continuously, so the captured transcript and screen reads
are sensitive. They stay **local only** and never leave your machine. There is no
telemetry. Bring-your-own-keys means your audio and screen go to your own provider
accounts, not a shared service. The local store and raw log are gitignored.

When Mai shows a place from Hot Pepper, it includes the required credit
"Powered by ホットペッパーグルメ Webサービス".

## License

MIT. See `LICENSE`.
