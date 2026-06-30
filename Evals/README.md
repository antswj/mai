# Mai behavioral evals

These are LLM-as-judge evals (using [promptfoo](https://www.promptfoo.dev/)) over
the exact prompt templates the engine ships in `Sources/MaiCore/Prompts/`. The
prompt functions (`classifier_prompt.js`, `drafter_prompt.js`) read those committed
files directly, so the evals grade the real prompts, not copies.

What they check:

- Classifier (`promptfooconfig.yaml` + `dataset.yaml`): fires the right trigger
  types, stays quiet on boring lines, and code-switches across English, Japanese,
  and Chinese. Conservatism is the headline behavior.
- Drafter (`promptfooconfig.drafter.yaml` + `drafter_dataset.yaml`): produces
  accurate, natural prepared lines with correct furigana (Japanese) and pinyin
  (Chinese) plus a faithful translation, and grounded fun facts and recipes with no
  fabricated links.
- Lookup router (`promptfooconfig.router.yaml` + `router_dataset.yaml`): picks the
  right route (entity / fresh / technical), keeps Japanese and Chinese entity names
  in their native script, and flags freshness for time-sensitive asks. Trivial
  answers are decided locally (in code), so they are covered by `swift run MaiTests`,
  not by this prompt eval.

## Run them

You need an Anthropic key (the grader and models under test use Claude). From the
repo root, make your key available to promptfoo, then run from this folder:

```
cd ~/mai
export ANTHROPIC_API_KEY="$(grep '^ANTHROPIC_API_KEY=' .env | cut -d= -f2-)"
cd Evals
promptfoo eval -c promptfooconfig.yaml
promptfoo eval -c promptfooconfig.drafter.yaml
promptfoo eval -c promptfooconfig.router.yaml
promptfoo eval -c promptfooconfig.assistant.yaml
promptfoo eval -c promptfooconfig.notes.yaml
promptfoo eval -c promptfooconfig.responder.yaml
```

View the last results in a browser:

```
promptfoo view
```

These evals make real model calls (a small number). They are expected to grow every
step as the system grows.

## Step 2: capture paths

The new real-capture paths are verified across three layers, since promptfoo is
text-based and cannot take live audio or a microphone:

- Transcription to trigger: the classifier dataset includes lines as they arrive
  from live transcription of a meeting (mixed-language cravings, a remote speaker
  asking the user to respond, screen cues), so the LLM-as-judge confirms the right
  triggers fire on transcribed text. The audio side (format conversion plus the
  Soniox protocol) is verified live by `swift run MaiSmoke soniox`, which makes
  speech locally with `say` and transcribes it through the real client.
- Screen reads: `swift run MaiSmoke screen` renders a sanitized slide and confirms
  Gemini reads its content (a keyword assertion). The frame-diff change detection is
  unit-tested in `swift run MaiTests`.
- Speaker attribution: the source split (mic equals the user, system equals remote)
  plus diarization plus the on-screen-name correlation, with the graceful fallback,
  are unit-tested in `swift run MaiTests` (SpeakerNaming), and the local furigana and
  pinyin generation is tested there too.

## Step 3: card intelligence and gating

The card brain is verified across the same three layers:

- Routing: the router prompt eval above (per route, trilingual entity extraction).
  The end-to-end routing plus async enrichment, the never-fabricate path, and the
  response toggle are driven deterministically with stubs in `swift run MaiTests`.
- Real lookups: `swift run MaiSmoke entity` exercises the live Wikipedia summary and
  cross-language resolution (e.g. 寿司 and 马来西亚 resolve to the English article),
  and `swift run MaiSmoke grounded` exercises the live Gemini grounded web search
  with real sources.
- Voice-activity gating: the gate, frame accumulator, and pre-roll ring are pure
  logic unit-tested in `swift run MaiTests`, which also loads the bundled Silero
  model and runs real on-device ONNX inference. `swift run MaiSmoke vad` runs it live.

## Step 3 final: assistant and notes

- Assistant (`promptfooconfig.assistant.yaml` + `assistant_dataset.yaml`): grades the
  real assistant prompt on summarizing what the meeting is about and identifying what
  the user themselves said, grounded only in the transcript.
- Notes writer (`promptfooconfig.notes.yaml` + `notes_dataset.yaml`): grades the real
  notes-writer prompt on producing notes grounded only in the transcript and the
  noted items, with no invented specifics.
- Responder (`promptfooconfig.responder.yaml` + `responder_dataset.yaml`): grades that
  the suggested reply is written in the language actually spoken for the utterance
  (English/Japanese/Chinese, tracked per utterance), with an interface-language
  translation, and that a reply is offered equally readily across languages.
- Router freshness (in `router_dataset.yaml`): a brand-new movie or a release-date
  question routes to grounded search, not a model answer. The local freshness
  guardrail that enforces this ahead of the model is tested in `swift run MaiTests`.
- The separate verification pass (dropping unsupported bullets), the generated title,
  the .docx and .md write, the "note this down" merge, the info-cards-pause-while-
  reply-cards-run gate, Keychain storage, the spend math, and the HUD show/hide and
  pin math are all exercised deterministically in `swift run MaiTests`.
