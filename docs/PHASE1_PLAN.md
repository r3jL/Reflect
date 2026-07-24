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

## M10 — Provider layer (`ReflectAI`: protocols + OpenRouter) ✅ (2026-07-24)

Shipped: `AiProvider` (generic structured-JSON chat decoded straight into
caller `Codable` types + batch embeddings) and the defined-only
`LocalLlmProvider` (FR-025). `OpenRouterProvider`: key via injected
provider (Keychain at the app boundary), `response_format: json_object`,
code-fence-tolerant decoding, **one corrective retry on schema mismatch**
(the retry prompt cites the decode error) then hard `.schema` failure —
never repaired/partial data. Error taxonomy with `isRetryable` contract:
`.auth`/`.schema`/`.notConfigured` terminal; `.rateLimited` (honors
Retry-After) /`.network`/5xx retryable. `ModelPricing` local price table.
**Migration v2** adds the `ai_usage` ledger + `UsageRepository`
(`monthTotal` for the Settings spend line).
**Result:** 8/8 provider tests (stub `URLProtocol`, golden transcripts —
happy paths, fenced JSON, retry-then-succeed, retry-then-fail, embeddings
index ordering, no-key-no-network, 401/429/503 classification, pricing);
ledger test green; **v1→v2 migration verified on the real container DB**
(entries intact, `ai_usage` present).

## M11 — Orchestrator + durable queue (FR-020) ✅ (2026-07-24)

Shipped per spec §8 layout: `PipelineRepository` in ReflectCore owns the
SQL invariants — atomic claims (`UPDATE … WHERE status='pending'` guard),
stage dependency in the claim query (reflection claimable only after
extraction success — AC-020), trash exclusion, the failure state machine,
and `reenqueue` (FR-031). A **terminally failed extraction cascades a
`skipped` reflection** (with reason) so entries never breathe "AI pending"
forever. `PipelineOrchestrator` actor in ReflectAI: ≤2 concurrent stage
runs, exponential backoff (base×2^attempts, capped; honors Retry-After) via
in-memory holds + delayed kicks, `isEnabled`/`isOnline` gates checked per
drain (AC-004/AC-025), ledger write on every success (stage, model, tokens,
priced estimate), `StageNotApplicable` → `skipped`. Stages plug in as
`PipelineStageRunner`s (M12/M13); a claimed job with no registered runner
is returned to pending untouched. `NetworkMonitor` (NWPathMonitor) exposes
`isOnline` + a reconnect callback for the app to `kick()`.
**Result: 10/10 orchestrator tests** — ordering, extraction-failure
cascade, retry-then-succeed (attempts=3), budget exhaustion, disabled gate,
offline-queue-then-drain, skip, ledger rows, manual re-run revival, and a
measured concurrency peak ≤2 across 12 slow jobs. ReflectCore 18/18; app
builds with the new package graph.

## M12 — Extraction stage (FR-021) ✅ (2026-07-24)

Shipped: `Prompts.extractionSystem` (strict JSON contract, "extract only
what is present, never invent"), `ExtractionOutput` Codable (decoding =
validation), `ExtractionStage` runner (≥5-word guard → skip; list-size
bounds; only title+body sent — verified by test), `MetadataRepository`
(single-transaction supersede per AC-005, canonical theme dedupe, entity
dedupe on (name,type), unknown entity types → `other`, insertion-order
reads). App wiring: orchestrator lives in `AppServices` with the extraction
runner + Keychain key provider; kicks on launch sweep, completion, and
completed-entry edits; reconnect kick via `NetworkMonitor`.
**Live smoke found and fixed two real queue bugs:** (1) `running` jobs
stranded by a killed session are now recovered to pending on first drain
(`recoverStaleRunning`); (2) claims for stages with no registered runner
no longer burn attempts (`releaseClaim`) — previously they exhausted the
retry budget across relaunches.
**Result:** 6 golden-transcript tests (AC-021 rows, supersede, cross-entry
dedupe, short-skip, no-partial-writes, privacy boundary) + 2 new queue
tests — ReflectAI 26/26, ReflectCore 18/18. **Live: 15/15 real entries
extracted via Gemini 2.5 Flash** — sensible themes/tags in the container
DB, ledger shows 12-call sample at 4,881 prompt + 548 completion tokens ≈
**$0.0028** (AC-030 tracking well under budget).

## M13 — Reflection + Embedding stages (FR-022, 023, 030) ✅ (2026-07-24)

Shipped: `Prompts.reflectionSystem` (4-mood vocabulary with meanings, the
"Reflect noticed" voice: one sentence, <25 words, no advice/questions;
versioned `p1` into `model_version`), `ReflectionStage` (consumes
extraction context — themes/tags/entities in the prompt, verified by test;
**range/vocabulary validation beyond decoding**: unknown mood/energy or
out-of-range confidence/sentiment = `.schema` failure, no clamping, no row
— AC-022/024), `replaceReflection` upsert. `EmbeddingStage`:
paragraph-aware greedy chunking (≤3500 chars, mid-paragraph split only
when forced), dim validation (≠1024 = schema failure, nothing written),
`EmbeddingsRepository` versioned replace + `firstChunkVector` +
`nearestEntries` KNN (entry-deduped, self-excluding — M14's echo query,
ready). Canonical model name `bge-m3` stored; provider id
(`baai/bge-m3`) in `model_version`. Full-pipeline integration test
(orchestrator + all three canned stages → enriched entry + 3 ledger rows).
**Result:** ReflectAI **34/34**. Live: **45/45 jobs success** across 15
entries — moods 12 calm/3 quiet, 15×1024 vectors, reflection notes in
exactly the design's voice. One data cleanup (stale attempt counts from
the pre-fix M12 era). **KPI-07 measured: fresh entry complete→fully
enriched in 11s** including app cold start (<15s budget ✅). Spend to
date: extraction $0.0035 + reflection $0.0431 + embeddings ~$0 ≈
**$0.047** (AC-030 on track).

## M14 — The margins come alive (Today / Life / Entry UI) ✅ (2026-07-24)

Shipped: `EchoService` — local-only retrieval (stored first-chunk vector →
`nearestEntries` KNN → past-entries-only filter → distance ceiling 1.2,
weak matches hidden), sentence-aware snippets, the design's when-language
("3 weeks ago" / "July 2025" / "a year ago this week"). `TodayModel` grew
the living layer: reflection + echoes + failed-job awareness, a 2s poll
that runs only while work is in flight and surfaces results the moment
jobs land, **"listen again"** (reflection-only re-run with the breathing
"listening…" state) and **"try again"** (full re-run, FR-031). `TodayView`:
echo blocks in the left margin (breathing accent-soft dot + italic serif +
when line), "Reflect noticed" in the right margin above the hairline+meta
stack, mood dot fills with the 4-mood color, the AC-024 warning row
("Reflect hit a snag with this entry · try again") replacing "AI pending"
on failure; the narrow inline layer carries all of it too. `EntryReadView`:
loads its own reflection (mood chip from fresh data) + a left-bordered
memory-echo block after the body, per the mockup. Life washes were already
plumbed and are now colored by real moods.
**Result:** end-to-end live — today's entry completed → 3/3 stages → mood
`calm`, a genuinely good note, and **two echoes at distances 0.672/0.890**
(probe confirms the threshold has sensible headroom; final calibration in
M16). AI-off leaves Phase 0 behavior untouched (gates unchanged). Visual
pass = human check.

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
