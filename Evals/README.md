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

## Run them

You need an Anthropic key (the grader and models under test use Claude). From the
repo root, make your key available to promptfoo, then run from this folder:

```
cd ~/mai
export ANTHROPIC_API_KEY="$(grep '^ANTHROPIC_API_KEY=' .env | cut -d= -f2-)"
cd Evals
promptfoo eval -c promptfooconfig.yaml
promptfoo eval -c promptfooconfig.drafter.yaml
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
