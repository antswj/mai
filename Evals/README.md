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
