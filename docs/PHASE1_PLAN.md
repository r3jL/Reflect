# Phase 1 Build Plan — Extraction, Reflection & Embeddings

> Ordered milestones for Phase 1 of the [genesis spec](../GENESIS_SPEC_journal_app.md)
> (§5.2, AC-020…AC-031, KPI-07/KPI-10). Numbering continues from Phase 0
> ([M0–M9](PHASE0_PLAN.md)). Design reference: `design/living-memory/` — this
> phase is where the margins come alive.
>
> **Ground rules carried from the spec:** the pipeline never touches
> `entries.body` (AC-010); every failure is null-plus-warning, never
> fabricated data (FR-024/AC-024); everything queues offline and drains on
> reconnect (AC-025); target spend <$5/month, expected ~$0.50 (AC-030).

## What Phase 0 already prepared

- `pipeline_jobs` rows (extraction/reflection/embedding, `pending`) are
  created on Complete and re-enqueued on completed-entry edits — the queue
  has real work waiting the moment the orchestrator exists.
- The full §4.2/4.3 metadata schema exists (reflection, themes, tags,
  entities, action items, self-questions, versioned embeddings + vec0).
- UI is plumbed: mood dot/washes render `entry_reflection` data the moment
  rows appear; Remember's group component is facet-shaped; the margins
  reserve space for echoes and "Reflect noticed"; "AI pending" already
  breathes on completed entries.
- The OpenRouter key lives in the Keychain (⌘,); `ai.enabled` gates it all.

## M10 — Provider layer (`ReflectAI`: protocols + OpenRouter)

`AiProvider` protocol (structured-JSON chat + embeddings) and the defined-
but-unimplemented `LocalLlmProvider` (FR-025). OpenRouter adapter:
`URLSession` + Keychain key, per-stage model ids from Settings, strict
JSON-schema response validation (one retry on schema mismatch), error
taxonomy (auth / rate-limit / network / schema / provider) so the queue can
tell retryable from terminal. **Migration v2:** `ai_usage` ledger
(job, model, tokens in/out, cost estimate) — KPI-10 is measured, not
guessed. Tests against a stub `URLProtocol` (golden request/response
transcripts; no network in CI).
**Exit:** adapter round-trips canned extraction/reflection/embedding calls;
usage rows written; auth/rate-limit/schema failures classified correctly.

## M11 — Orchestrator + durable queue (FR-020)

Actor-based runner in `ReflectCore`: claims `pending` jobs, enforces stage
order (Reflection waits on Extraction success; Embedding independent —
AC-020), bounded retries with exponential backoff (≤3 attempts), per-stage
`running/success/failed` transitions with `last_error`, ≤2 concurrent
provider calls. Triggers: entry completion, app launch sweep, reconnect
(`NWPathMonitor`) — AC-025. Gates: `ai.enabled` + key present, else jobs
stay `pending` (AC-004 semantics preserved). Manual re-run API (FR-031)
resets a stage through the existing enqueue path. Failure = job `failed` +
`last_error`, no derived rows (AC-024).
**Exit:** mock-provider tests prove ordering, retry/backoff, offline
queueing + drain, failure semantics, re-run.

## M12 — Extraction stage (FR-021)

`prompts/extraction.md` + JSON schema (themes, tags, entities typed
person/place/book/company/project/other, action items with due hints,
self-questions). Writers: canonical theme dedupe (`themes.name` unique),
entity dedupe on (name, type), link tables; **supersede-on-rerun** — a
re-run replaces that entry's prior extraction rows in one transaction
(AC-005). Only `title`+`body` are sent to the provider — place/weather/
media stay local. Golden-transcript tests: canned Gemini responses →
exact row assertions (AC-021); malformed-response tests → schema failure,
no partial writes.
**Exit:** AC-021 green on transcripts; re-run replaces cleanly; a real
completed entry extracts end-to-end with a live key (manual smoke).

## M13 — Reflection + Embedding stages (FR-022, 023, 030)

**Reflection** (`prompts/reflection.md`): consumes the entry + extraction
output; writes the single `entry_reflection` row — summary, mood
(bright/warm/calm/quiet per §3.6), `mood_confidence` [0,1],
`sentiment_score` [-1,1] (range-validated — out-of-range = schema failure,
AC-022), energy, and the entry-local `reflection_note` that becomes
"Reflect noticed". **Embedding:** ~1k-token chunking for long entries,
bge-m3 @1024 via the adapter, versioned writes to `embeddings_meta` +
`vec_entries` (AC-023; FR-030 columns already enforced by schema).
**KPI-07 harness:** measure complete→all-stages-done, P95 <15s.
**Exit:** AC-022/023 green on transcripts; live smoke turns a real entry's
mood dot colored; KPI-07 measured.

## M14 — The margins come alive (Today / Life / Entry UI)

- **"Reflect noticed"** (right margin, italic serif): shows
  `reflection_note`; **"listen again"** = manual reflection re-run with the
  breathing-dot "listening…" state (design behavior).
- **Memory echoes** (left margin + entry read view): top-k vector neighbors
  of this entry over *past* entries (excluding same-day), rendered as
  italic snippet + "when" line. Echo retrieval is **local-only** (stored
  vectors; no per-keystroke API calls) — refreshed on load and after the
  embedding job lands. *(DEC-P1-01: live-while-typing echoes would need
  draft embedding on idle — deferred until cost data says it's fine.)*
- Mood dot fills on Today's meta row; Life washes/bars go mood-colored
  (already plumbed — verify live); entry read view gains mood chip +
  summary + echo block.
- **Failure surfaces (AC-024):** completed entries with a `failed` stage
  show a quiet, non-blocking warning line with a "try again" affordance
  (FR-031); "AI pending" clears as stages succeed.
**Exit:** with a live key, completing an entry visibly enriches it within
seconds; failures show the warning + re-run; AI-off leaves Phase 0 behavior
untouched.

## M15 — Remember facets, hybrid retrieval & Insights browse (FR-026/027/028)

- **Remember:** facet groups from extraction (People / Places / Projects /
  Books / Feelings via entities+themes) replacing month groups when facets
  exist; **hybrid retrieval** — FTS5 keyword hits merged with vector top-k
  of the query embedding (one cheap embed call per settled query, AI-on
  only); the AI **lead sentence** (small reflection-model call, ~700ms
  debounce, silent fallback to static leads offline).
- **Insights:** real month stats (pages, streak, words, photos) with the
  count-up animation; **theme & entity browse** (chips → filtered entry
  list → morph-open, FR-027); **open action items** list with done/dropped
  (FR-028) — mood-over-time stays expressed via Life washes + the future
  P4 chapter (per §3.6 note).
**Exit:** AC-026 (mood visible over time), AC-027 (theme filter), FR-028
usable; Remember degrades gracefully with AI off.

## M16 — Cost guard, failure drills & Phase 1 exit

Settings gains a quiet **spend line** (this month's estimated cost from
`ai_usage`; AC-030 sanity: ~60 entries ≈ $0.40–0.50). Failure-injection
sweep (auth revoked, rate-limited, network drop mid-stage, malformed JSON,
provider 500s) — every path ends in null+warning+retryable, never fabricated
rows, never a blocked UI. Offline month: complete entries offline → jobs
drain correctly on reconnect (AC-025 live). Full AC-020…AC-031 pass; KPI-07
P95 re-measured on a real week of entries; docs updated.
**Exit:** tag **`v0.2.0-phase1`** — the MVP as specced (Phase 0 + 1).

---

**Sequencing rationale:** provider before queue (M11's tests need a mock of
M10's protocol); extraction before reflection (hard dependency, AC-020);
UI after both write paths exist (M14 renders real rows, not fixtures);
Remember/Insights last because they consume everything (facets need
extraction, hybrid search needs embeddings, lead needs reflection); cost
guard at the end when real usage data exists to display.

**Standing risks:** OpenRouter/model API drift (mitigated: strict schemas +
transcript tests + model ids editable in Settings); structured-output
quality from Gemini Flash (mitigated: one schema-retry, then fail-null);
echo quality at small journal sizes (mitigated: echoes hidden below a
similarity threshold rather than showing weak matches).
