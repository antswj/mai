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

Cards are intelligent and sourced. When something is worth surfacing, a card
appears instantly as a skeleton and fills in live, on its own tasks, so the
transcript never stalls. A lookup router sends each card to the right kind of
answer: instant local math and unit conversions; a Wikipedia summary with a real
image and source for a known thing (resolved into your language even when the
thing was named in Japanese or Chinese); a grounded web search with real sources
for anything current; or a plain, broken-down explanation for a technical
question. The answer is always written in your interface language, and nothing is
ever fabricated: a lookup that finds nothing says so. An optional reply toggle adds
a suggested response, in the language being spoken, with reading aids and a
translation, when one is clearly warranted.

To keep always-on listening affordable, an on-device voice-activity detector
(Silero VAD v5, fully local) gates each transcription stream: it opens on speech
and tears the stream down during sustained silence (Soniox bills for the whole
time a stream is open), flushing a short pre-roll so the first word is never
clipped. If the detector ever misbehaves it fails open (keeps transcribing) rather
than going silent.

Capture is meant to stay up by itself. A built-in watchdog keeps watch with no
buttons: real audio flows continuously even in silence, so if it stops, capture
died; if audio is being sent but no transcript comes back, the speech pipeline
stalled. Either way Mai restarts capture, transcription, and the card stream
automatically, and a transient failure to start retries on its own. A card always
shows the best information it can get: a Wikipedia summary or grounded web answer
when available, otherwise the model's own general knowledge, rather than going
blank. Suggested replies appear only when the **Reply** toggle is on; the
information itself is always there.

Mai has two faces, both driven by the same engine. **Mission mode** is the resting
state: a small, glassy heads-up display at the top-right of the screen, like where
Siri appears, that stays in front of every app (including full-screen calls) without
stealing focus. It slides in when there is something relevant (speech, a card, or
when you summon it with a global shortcut) and slides away to just the menu bar when
things go quiet. The **full app** is the lean-in state: an expansive window with the
full transcript, all cards, the chat assistant, the meeting notes view, settings, and
a spend meter. Open it deliberately; close it and Mai returns to the top-right HUD.

A meeting assistant (the Claude-backed chat, behind a swappable provider) reads the
whole transcript so you can ask "what are they talking about" and get a grounded
answer including what you yourself said; while you chat, info cards pause but
suggested-reply cards keep running so you never miss one. Say "note this down" and it
folds into the notes. A real notes pipeline accumulates the meeting, and on stop it
writes up structured notes, verifies every line against what was actually said,
generates a title, and saves a clean Word document plus a timestamped Markdown
transcript to a folder you choose.

Clone it, add your own API keys (stored in the macOS Keychain), build the app bundle,
grant two permissions, and it works. (Run unbundled with `swift run Mai` and it
degrades to a typed-input dev mode.)

## What is in here

- A platform-agnostic engine in plain Swift (`Sources/MaiCore`) with zero
  UI-framework dependencies, so it can move to a device later.
- Real capture in `Sources/MaiCapture` (macOS): ScreenCaptureKit microphone and
  system audio, Soniox streaming transcription, low-rate screen watching with a
  cheap frame-diff, and Gemini screen reads. It implements the engine's `Ears` and
  `Eyes` contracts, so the brain is unchanged.
- A SwiftUI app (`Sources/MaiApp`) with two faces: a floating Mission mode HUD
  (an `NSPanel`, non-activating, over full-screen apps, auto show/hide, a global
  summon hotkey) and a full HIG window (live transcript, cards, chat, notes, settings,
  spend meter). Liquid Glass on the functional layer, with a material fallback below
  macOS 26. A menu bar item is the 24/7 anchor; the app launches at login.
- A meeting assistant behind a swappable `AssistantProvider` (Claude now), a real
  notes pipeline (accumulate, verify against the transcript, title, save a clean
  `.docx` and a timestamped `.md`), and a spend meter from local usage counts.
- Real lookups over HTTP: an LLM (Anthropic by default, Groq as an alternative),
  Google Places (New) plus Recruit Hot Pepper for nearby places, Wikipedia (entity
  summaries with cross-language resolution), and Google Gemini (screen reads and
  grounded web search).
- A card brain: a lookup router (trivial / entity / fresh / technical) and an async
  enrichment pipeline that fills each card in part by part, with hard per-call
  timeouts and supersede cancellation.
- On-device voice-activity gating (Silero VAD v5 via ONNX Runtime, model bundled, no
  network at runtime) so transcription only runs, and only bills, while someone speaks.
- A local, exportable session store (SQLite via GRDB) and an append-only raw log.
- First-run onboarding (permissions, API keys into the Keychain with validation, the
  notes folder), and shipping scripts (a signed `.dmg` plus a ready-to-run, documented
  notarization script).
- Automated tests, behavioral LLM-as-judge evals, live smoke checks, and a secrets scan.

## Requirements

- macOS 15 or later with Swift 6.x. Command Line Tools are enough (full Xcode is
  optional). Check with `swift --version`.
- A network connection on the first build: SwiftPM fetches GRDB and the ONNX Runtime
  binary once. After that, voice-activity detection runs fully offline.
- Your own API keys (see below). Each user brings their own; nothing is shared.
- A funded Soniox account for live transcription (Soniox is pay-as-you-go; an empty
  balance returns a clear error and no transcript).

## Setup

There are two ways to provide keys. For the shipped app, enter them in the app: on
first run, onboarding walks you through pasting each key, and they are stored in the
**macOS Keychain** (never a file). For command-line development (`swift run MaiSmoke`,
the evals), a `.env` file is the convenient path.

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

   `.env` is gitignored and must never be committed. The app reads `.env` and the
   process environment first, then the Keychain, so a dev `.env` and the in-app keys
   can coexist. Keys you enter in the app go only to the Keychain.

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

On first launch, onboarding walks you through granting **Screen Recording** and
**Microphone**, pasting your API keys (into the Keychain), and choosing the folder
where meeting notes are saved. Grant both permissions, then quit and reopen `Mai.app`
(macOS requires a relaunch after granting Screen Recording). If a prompt does not
appear, grant them manually in System Settings, Privacy and Security: add `Mai` under
**Screen and System Audio Recording** and under **Microphone**, then relaunch.

Mai runs as a menu bar item (no Dock icon). Mission mode, the small heads-up display,
appears at the top-right when there is something relevant and slides away when things
are quiet. Use the menu bar item to pause, to show Mission mode, or to open the full
app; set a global summon shortcut in Settings to bring up Mission mode and its ask
field from any app.

### If Mai keeps asking for permission (even though System Settings shows it granted)

This is the ad-hoc signing churn: each `./make-app.sh` rebuild changes the app's code
hash, so the previous grant no longer matches and macOS leaves a stale "on" entry
that does not apply to the new build. `make-app.sh` auto-uses a stable certificate
when one is in your keychain, preferring a real **Developer ID Application**
certificate (best: trusted and notarizable) and otherwise a self-signed **Mai Dev**
cert; with either, the grants persist across rebuilds. If you have neither, create
the self-signed cert once:

1. Create a self-signed code-signing certificate named **Mai Dev**: open Keychain
   Access, menu Certificate Assistant, Create a Certificate, name it `Mai Dev`,
   Identity Type **Self Signed Root**, Certificate Type **Code Signing**, Create.
   `make-app.sh` then uses it automatically (no env var needed) and the grants stick.
2. Clear the stale grants (paste into Terminal, or type `! <command>` in this CLI):

   ```
   tccutil reset ScreenCapture com.mai.app
   tccutil reset Microphone com.mai.app
   ```

3. `./make-app.sh`, `open Mai.app`, grant once, then relaunch.

(Mai checks Screen Recording the ScreenCaptureKit-native way rather than via the
unreliable `CGPreflightScreenCaptureAccess`, so once the grant actually applies to the
running build, the app stops asking.)

The full app (open it from the menu bar) is a standard macOS window with a sidebar:
**Live** (the transcript and the card stream side by side), **Chat** (the meeting
assistant), **Notes** (start/stop note-taking and the list of saved meetings), and
**Spend** (the estimated daily cost). The card stream shows each card with a colored
tier badge, the title, the answer, a real image and tappable source when present, an
action button when there is one (for example "Open in Maps"), and an optional
suggested reply when the **Reply** toggle is on. Closing the window returns Mai to the
top-right HUD; the transcript, cards, and notes are continuous across both.

## Ship Mai to someone else

`make-app.sh` already signs with your Developer ID and the hardened runtime, so the
app opens cleanly on your own Mac. To produce a disk image and (when you are ready)
notarize it so it opens on anyone's Mac:

```
./release.sh        # builds + signs Mai.app, then packages a signed Mai.dmg
```

The `.dmg` opens cleanly on your Mac. On someone else's Mac it shows a Gatekeeper
warning until it is notarized. When you are ready to share it, notarize once:

```
./notarize.sh       # notarizes and staples the app and the dmg
```

`notarize.sh` documents the one-time setup in plain English at the top: turn on
two-factor for your Apple Account, generate an **app-specific password** at
account.apple.com (this is not your Apple ID password), and store it once with
`xcrun notarytool store-credentials "MaiNotary" ...`. After that, each release is
`./release.sh` then `./notarize.sh`. The script verifies the result with
`stapler validate` and `spctl`; you can also run `syspolicy_check distribution Mai.app`
as the authoritative Gatekeeper check on macOS 14+.

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
6. Put a full-screen call on screen and confirm the top-right HUD stays in front and
   that clicking it does not pull focus out of the call. Open the full app and confirm
   the expansive experience, then close it and confirm Mai reverts to the HUD.
7. In the app's **Chat**, ask "what are they talking about" and confirm the assistant
   summarizes the meeting and what you said; while the chat is open, info cards pause
   but a suggested-reply card still appears. Say "note this down" to add an item.
8. In **Notes**, press **Start Note-Taking**, hold a short meeting, then **Stop**.
   Watch the processing state (reviewing, verifying, titling, saving), then open the
   saved `.docx` and `.md` from your chosen folder. The meeting appears in the list.
9. Check the menu bar pause and the **Spend** view (it reflects savings during silence).
10. With audio playing through the speakers (no headphones), have a remote participant
    talk: confirm their speech shows once, as the real speaker, not doubled as "You".
    When you speak, it still shows as "You". (Headphones remove the echo at the source;
    Mai filters it without them.) If it still doubles, run from a terminal with
    `MAI_DEBUG_ECHO=1 open Mai.app` (or `MAI_DEBUG_ECHO=1 swift run Mai`) and the
    console shows each stream's finals and the echo decision, which reveals whether the
    two copies are identical (ordering) or transcribed differently; tune `[echo]
    hold_seconds` in `config.toml`, or set `suppression = false` to turn it off.
11. Share a slide deck and advance a slide: confirm a useful, sourced card appears
    about the slide's subject (facts, a breakdown, figures), in your interface language,
    not a description, and a new slide produces a new card. A Japanese or Chinese slide
    works the same, the card coming back in the interface language.
12. Turn on the **Translate** switch in the live transcript: a Japanese or Chinese line
    shows an English (interface-language) translation beneath it, appearing about as
    fast as the line itself (it rides the same Soniox stream). Toggle it off to remove
    the translations. They never appear in the cards.
13. Pin a card with the pin button: it moves into the pinned carousel at the top of the
    cards area and stops auto-dismissing. Pin a few and swipe (or use the arrows and
    page dots) to page through them. The X unpins. The note button marks a pinned card
    for the meeting notes, so its content appears in the exported `.docx` and `.md`.
14. Confirm the Mission mode HUD stays compact: it shows a small recent transcript
    window and stays small, rather than growing tall as the meeting goes on (the full
    transcript is in the app). The cards area still grows as cards appear.
15. In Mission mode, tap a card to expand it: the full info, a larger image, the reply,
    and the sources appear; tap again to collapse. Card images show in Mission mode
    (a thumbnail when collapsed, larger when expanded).
16. Mute: click the mic button (in the Mission mode HUD header, the menu bar, or the app
    toolbar). Your own voice stops being transcribed while system audio and the screen
    keep going; click again to unmute. The mute survives an automatic capture restart.
17. The Translate switch is also in the Mission mode HUD header (the speech-bubble icon),
    not just the full app.

With simulated input (`swift run Mai`), the same flows work with typed lines: try a
sushi line, a `Sato: ご意見をお願いできますか？` reference (a Japanese suggested reply
with ruby and a translation), and `floor = "zh"` in `config.toml` to see pinyin. To
see the card brain, type a line like `i'm going to Malaysia next month` (a sourced
entity card with an image), `what's 15% of 80` (an instant local answer, no web),
`お寿司ってどんな食べ物` (an entity card resolved into English from Japanese), or a
current-events question (a grounded answer with real source links). Flip the **Reply**
toggle to have Mai also suggest a response when one is clearly warranted.

## Tune the noise

Open `config.toml`:

- Raise `[surfacing] threshold` for fewer cards, lower it for more.
- Keep `show_suppressed_log = true` to watch what was filtered while you tune.
- Switch the LLM provider with `[providers] llm` (`anthropic` or `groq`). If you set
  `groq`, also set `[models] classifier = "openai/gpt-oss-20b"` and
  `drafter = "openai/gpt-oss-120b"`.

Model names, providers, languages, latency targets, and the test location all live
in `config.toml`, so a change is one edit plus a restart.

Step-3 knobs, also in `config.toml`:

- `[lookup] enabled` turns the card brain on or off. `[models] router` picks the
  fast model that routes each card (trivial / entity / fresh / technical).
- `[response] enabled` turns the suggested-reply toggle on (also a switch in the app
  window, labeled "Reply"). Off by default; conservative when on.
- `[latency] online_cap_seconds` is the hard ceiling on any single online enrichment.
- `[vad]` controls the on-device gate: `enabled`, `onset` / `offset` (speech
  probability thresholds), `silence_hangover_seconds` (silence before tearing the
  stream down), and `preroll_seconds` (audio kept so the first word is not clipped).
  The Silero model ships in the app; ONNX Runtime is fetched once at build time.

## Automated checks

- **Acceptance harness** (runs everywhere, including Command Line Tools only):

  ```
  swift run MaiTests
  ```

  This drives the engine through every canonical example plus the step-2 capture
  logic (local furigana/pinyin, ruby segmentation, the Soniox token parser, the
  frame-diff, speaker naming, and the audio converter) and the step-3 card brain
  (lookup routing including Japanese/Chinese entity extraction, trivial answers,
  async enrichment and the never-fabricate path, the response toggle, and the VAD
  gate, frame accumulator, and pre-roll ring) with deterministic stubs and fakes
  (no network, no microphone, no screen). It also loads the bundled Silero model and
  runs real ONNX inference, and exits non-zero on any failure.

- **`swift test`**: the same behaviors are also written as a swift-testing suite.
  `swift test` uses Apple's testing framework, which ships with full Xcode. With
  Command Line Tools only it cannot run, so use `swift run MaiTests` there.

- **Behavioral evals** (LLM-as-judge): see `Evals/README.md`. In short:

  ```
  cd ~/mai && export ANTHROPIC_API_KEY="$(grep '^ANTHROPIC_API_KEY=' .env | cut -d= -f2-)"
  cd Evals && promptfoo eval -c promptfooconfig.yaml && promptfoo eval -c promptfooconfig.drafter.yaml
  # plus: promptfooconfig.router.yaml, promptfooconfig.assistant.yaml, promptfooconfig.notes.yaml
  ```

- **Live smoke tests** (validate your keys end to end against the real APIs):

  ```
  swift run MaiSmoke          # all
  swift run MaiSmoke llm      # Anthropic + Groq
  swift run MaiSmoke places   # real Google + Hot Pepper merge, query "sushi"
  swift run MaiSmoke vision   # Gemini reads a small embedded image
  swift run MaiSmoke soniox   # makes speech with `say`, transcribes it via Soniox
  swift run MaiSmoke screen   # Gemini reads a generated slide
  swift run MaiSmoke vad      # on-device Silero VAD runs on silence and a tone
  swift run MaiSmoke entity   # Wikipedia summary + cross-language (寿司, 马来西亚)
  swift run MaiSmoke grounded # Gemini grounded web search with real sources
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
calls to your own accounts: Soniox (transcription), Gemini (screen reads and grounded
search), and Wikipedia (entity summaries). There is no telemetry, and Mai excludes
its own audio from capture. Voice-activity detection runs **entirely on-device** (no
audio is sent anywhere to decide if you are speaking), and because it tears the
transcription stream down during silence, audio only leaves the machine while
someone is actually talking. The **Pause** button is a real privacy valve: it stops
capture and closes the transcription sockets, so nothing is captured, transcribed,
read, or stored until you resume. The local store, raw log, and saved meeting files
(the notes `.docx`, the transcript `.md`, and the export bundle) are gitignored and
stay in the folder you chose; participant names inferred from the screen are
session-only. API keys live in the macOS Keychain, never in the repo. The spend meter
stores only local aggregate counts (audio-seconds and call counts), never content.

When Mai shows a place from Hot Pepper, it includes the required credit
"Powered by ホットペッパーグルメ Webサービス".

## License

MIT. See `LICENSE`.
