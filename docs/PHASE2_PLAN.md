# Phase 2 Build Plan — Ask Your Journal & the Local Adapter

> Ordered milestones for Phase 2 of the [genesis spec](../GENESIS_SPEC_journal_app.md)
> (Appendix B: "Hybrid retrieval + free-form chat + Ollama local LLM
> adapter"). Numbering continues from Phase 1 ([M10–M16](PHASE1_PLAN.md)).
>
> The spec gives Phase 2 one roadmap line, so this plan carries more design
> decisions than the earlier ones — each is recorded below and vetoable
> before its milestone starts. The non-negotiables hold: user text is
> immutable, answers are grounded or absent (never fabricated — FR-024
> extended to chat), everything degrades cleanly offline/AI-off, and cost
> stays measured.

## Standing decisions (veto before M18/M19 if desired)

- **DEC-P2-01 — Chat lives inside Remember.** No new tab. The overlay's
  question is already "What are you trying to remember?" — asking becomes
  answering. Search results and chat share one surface, per the design's
  one-system ethos.
- **DEC-P2-02 — Conversations are ephemeral.** No chat tables; a thread
  lives only while the overlay is open. The journal remains the single
  store of truth. (Persistent conversations can come later without schema
  regret.)
- **DEC-P2-03 — No streaming in v1 chat.** The provider abstraction stays
  simple; the breathing "listening…" state covers latency. Streaming is a
  clean later upgrade inside the provider.
- **DEC-P2-04 — Ollama speaks OpenAI.** One OpenAI-compatible transport,
  two providers: the existing OpenRouter adapter and Ollama's local
  `/v1` endpoint (no auth, `localhost:11434`).
- **DEC-P2-05 — Embeddings stay bge-m3 on both providers.** Same model
  weights → same vector space → no re-index on provider swap (§3.4's
  founding premise); per-vector provenance already records which provider
  produced what (FR-030/AC-029).

**Phase 2 non-goals:** persistent memory/graph (P3, still gated on
CLR-01), monthly chapters (P4), chat history persistence, streaming,
AI on media.

## M17 — Retrieval context builder (the RAG core) ✅ (2026-07-25)

Shipped: `JournalRetriever` + `RetrievedContext` in
`ReflectAI/Retrieval/`. One query embedding → KNN (floor 1.25, echo
discipline) merged with FTS5 hits (keyword evidence is never
floor-dropped); deterministic scoring — semantic = distance, keyword =
0.95 + 0.01·rank, dual-match takes `min − 0.1` boost; ties break to
recency then id. Pack assembly: ≤6 entries, ~4k-token budget with
whitespace-boundary truncation, first source always ships, trashed/empty
entries excluded, per-item mood + summary + stable 1-based citation id,
`promptBlock()` renders the numbered sources M18 hands to the model.
Honesty built in: empty pack ⇒ `.nothingRelevant` verdict (weak context
dropped, not padded); a failed query embedding degrades to keyword-only
retrieval instead of failing the caller.
**Result: 9/9 tests** — merge order + dual-match boost, dedupe, floor
drop + honest verdict, keyword-without-embeddings, embed-failure
degradation, budget truncation + pack closing, determinism across runs,
recency tie-break, prompt-block format, trash exclusion. ReflectAI
48/48; app builds. No UI, no live calls — exactly as scoped.

## M18 — Ask your journal (chat + UI) ✅ (2026-07-25)

Shipped: `AskPrompts` (grounding contract: sources are the only truth,
decline plainly, cite by date in prose — never "[1]" in the answer text)
+ `AskService` with **two decline layers**: an empty/nothing-relevant pack
declines *deterministically without a model call* (no spend, zero
invention risk), and the prompt contract handles weak-context cases at
the model level. Phantom citation ids filtered; follow-ups carry the last
3 exchanges; ledger stage `chat`. UI in Remember: **Ask** button (accent
outline; breathing "listening…"; with AI off it stays visible and
explains itself), Return submits question-shaped queries, exchanges
render as bordered cards — question kicker, answer in Reflect's italic
serif, "From your entries" cited rows that open the read view; errors
are quiet with try-again and the thread survives them. Ephemeral by
construction (fresh model per overlay, DEC-P2-02). `REFLECT_ASK` debug
hook = headless live smoke.
**Result:** 7/7 service tests (context-verbatim, decline-without-call,
phantom-citation filter, thread context, model-decline marking, failure
propagation, chat ledger) — ReflectAI **55/55**. Live: real question
answered correctly with the right date + citation ("smaller and kinder
than you'd expected"); adversarial "capital of France" **declined in
voice** ("That kind of question lives outside these pages") — the
model-level defense firing on weak context. Chat spend: $0.007/2 calls.

## M19 — The local adapter (Ollama, FR-025 completed) ✅ (2026-07-25)

Shipped: transport generalized to `OpenAICompatibleProvider` (base URL +
optional key; `OpenRouterProvider` preserved as a typealias — zero call
sites touched). **`OllamaProvider: LocalLlmProvider`** — the M10 protocol
finally implemented: local `/v1` chat + embeddings (keyless, DEC-P2-04),
cached `isAvailable` + async `probe()` (1.5s timeout; the pipeline gate
reads it synchronously, so **Ollama-not-running behaves exactly like
offline**), `/api/tags` model listing. App: `RoutingProvider` facade —
every consumer (stages, semantic search, chat, lead) resolves the settings
toggle *at call time*; provider-aware model ids (`bge-m3` local vs
`baai/bge-m3` cloud — same weights, DEC-P2-05); probe kicked at launch
before the sweep and on provider change. Settings: OpenRouter/Ollama
segmented picker; Ollama section with running-status + Check, local
chat-model field, installed-model list, and the pull-bge-m3 note.
**Result:** 5 new tests (keyless header, local /v1 URLs, probe caching,
tags parsing, malformed-tags schema error) — ReflectAI **60/60**. **Live,
fully local** (Ollama + bge-m3 + qwen2.5:3b): ask-your-journal answered
grounded with 3 correct citations — the query embedded by *local* bge-m3
retrieving against *OpenRouter-produced* vectors, **validating the
same-vector-space premise live**; a fresh entry ran the whole pipeline
locally in 16s, all stages success on attempt 1 with contract-valid JSON
from a 3B model. Zero cloud calls, zero spend. Provider restored to
OpenRouter after the smoke (the toggle is in ⌘,).

## M20 — Phase 2 hardening & exit ✅ (2026-07-25) → `v0.3.0-phase2`

**Grounding drill** (`GroundingDrillTests` + live): the contract's
load-bearing clauses are asserted to reach the model on every call (the
layer-2 defense is tested, not assumed); weak-but-nonzero context reaches
the model and its decline is honored as a decline; a mid-thread provider
failure leaves zero state (no ledger row, service stateless, same thread
retries cleanly). **Live adversarial:** "17×23 / who invented the
telephone" → declined in voice, zero citations, no arithmetic attempted.
**Provider-swap / mixed provenance:** across M19+M20 both directions ran
live — local bge-m3 queries over cloud-produced vectors, then a **cloud
query retrieving and citing the entry embedded locally** (2026-06-28) —
one vector space, provider-independent, as §3.4 promised. Mid-session
swaps are structural (`RoutingProvider` resolves per call). **Chat spend
line:** Settings' month section now shows "of which N asks · ≈$"
(`monthStageTotal`). Retrieval spot-checks stayed healthy (echo distances
0.67–0.89, citations correct throughout) — floors unchanged.
**Suites: ReflectAI 63/63 · ReflectCore 20/20 · ReflectMedia 4/4 ·
ReflectSTT 2/2 = 89 tests.**

**Phase 2 complete → `v0.3.0-phase2`.** The journal now: understands
every entry (P1), answers questions about your life from your own words
only (M17–18), and can do all of it without the internet (M19). Next
frontiers: Phase 3 memory (gated on CLR-01 — a design conversation) and
Phase 4 chapters.

---

**Sequencing rationale:** retriever before chat (M18's tests need M17's
pack shape); chat before the local adapter so the adapter lands against a
finished feature set (one new variable at a time); hardening last with
real usage data. The Ollama milestone is deliberately independent — it can
run before M18 if the appetite flips.

**Standing risks:** local-model output quality against the strict JSON
contracts (mitigated: the schema-retry + null-plus-warning machinery is
provider-agnostic and already drilled); Ollama API drift (mitigated: the
OpenAI-compatible endpoint is its stability contract); answer-quality
temptation — the model "knowing" things outside the journal (mitigated:
the M20 grounding drill is adversarial, and declining is a feature).
