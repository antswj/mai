# Security and privacy

Mai is an always-on capture system in a public repository. This note lists the
current risk surface and how it is handled. It is updated every step as the system
grows.

## Principles

- The code is public. Secrets and captured data are local and never committed.
- Bring-your-own-keys: each user's audio, screen, and lookups go to their own
  provider accounts. There is no shared backend and no telemetry.
- Capture stays on the machine. Transcript and screen reads are sensitive and never
  leave the device except as the user's own provider API calls.

## Secrets

- The five API keys live in `.env`, which is gitignored. Only `.env.example` (with
  placeholders) is committed.
- `.gitignore` excludes `.env` and `.env.*` (except the example), the data
  directory, and `*.sqlite` / `*.jsonl` capture files.
- A pre-commit hook (`.githooks/pre-commit`, enabled with
  `git config core.hooksPath .githooks`) blocks committing `.env` files, the data
  directory, local store/capture files, and content matching common key shapes
  (Anthropic `sk-ant-`, generic `sk-`, Groq `gsk_`, Google `AIza`, long hex). It can
  also block an optional local `.private-terms` list.
- No GitHub token is ever stored in the app or `.env`; push auth lives in the
  machine's git credentials.
- Run a secrets scan with `gitleaks git -v --exit-code 1 .` (committed history;
  this is the "is the repo clean" check). `gitleaks dir -v .` additionally scans
  working files and will intentionally flag your local gitignored `.env`.

## Captured data

- The session store is a local SQLite file under `data/` (gitignored). The raw
  append-only log is `data/verbatim.jsonl` (gitignored).
- `exportSession` produces clean, general-purpose JSON so a user can take their own
  data out. There is no external sync.

## Action surface

- Phase A is mostly read-and-surface. The only action is `open_in_maps`, which opens
  a real maps URL drawn from a real Places API response (never fabricated). Opening a
  URL is safe and user-initiated (a button tap).
- Any future action that writes or sends must be gated and confirmable.

## Grounding

- The engine never fabricates specific links. Place URLs come only from real API
  responses; the drafter prompt forbids invented URLs and citations. This is asserted
  in the behavioral evals.

## Integrity checks in this repo

- Automated logic: `swift run MaiTests` (deterministic, no network) and the
  swift-testing suite under `Tests/`.
- Behavioral LLM-as-judge evals: `Evals/` (classifier and drafter).
- Secrets and dependency hygiene: gitleaks scan; the one third-party dependency
  (GRDB) is current and actively maintained.

## Reporting

If you find a security issue, open an issue describing the problem without including
any real secrets or captured data.
