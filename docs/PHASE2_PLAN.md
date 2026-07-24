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

## M17 — Retrieval context builder (the RAG core)

`JournalRetriever` in ReflectAI: question → one query embedding → KNN over
current vectors + FTS5 keyword hits → merged, deduped, recency-tiebroken
ranking → a **token-budgeted context pack**: for each cited entry, its
date, body (or chunk), mood/summary when present, and a stable citation
id. Deterministic given the same stores; distance floor reuses the echo
discipline (weak context is dropped, not padded). Also: a "nothing
relevant" verdict when the best match is beyond the floor — the honesty
signal M18's prompt depends on.
**Exit:** unit tests with canned vectors/FTS fixtures prove merge order,
dedupe, token budget truncation, and the nothing-relevant verdict; no
UI, no live calls.

## M18 — Ask your journal (chat + UI)

Prompt contract (`AskPrompts`): Reflect's voice; answer **only** from the
provided entries; cite the entries used by date; when the pack is empty or
the verdict is nothing-relevant, say so plainly ("Your journal doesn't
seem to hold this") — never general knowledge, never invention. In-overlay
thread (in-memory, DEC-P2-02) with follow-ups re-retrieving per question.
UI in the Remember overlay: an **Ask** affordance (and auto-detect for
question-shaped queries); the answer as a serif card in the AI's italic
voice, "From your entries" beneath it as cited rows that open the read
view; "listening…" while the model works. Ledger stage `chat`. AI-off:
the affordance explains chat needs AI enrichment enabled.
**Exit:** canned-provider tests (context reaches the prompt verbatim;
empty pack → decline path; provider failure → quiet error, thread
intact); live smoke: real questions against the real journal, spend
recorded.

## M19 — The local adapter (Ollama, FR-025 completed)

Generalize the transport: `OpenAICompatibleProvider` core (base URL +
optional key) with `OpenRouterProvider` as today's configuration and
**`OllamaProvider: LocalLlmProvider`** (localhost `/v1`, `isAvailable`
health probe, local model listing via `/api/tags`). Settings gains a
**provider picker** (OpenRouter / Ollama) plus local chat-model fields
shown when Ollama is selected; embeddings pinned to bge-m3 on both sides
(DEC-P2-05). The orchestrator, chat, and search resolve their provider
through one settings-driven closure — the spec's §1.3 toggle, real.
Pipeline gates extend naturally: Ollama selected but not running behaves
like offline (jobs wait; a quiet hint in Settings).
**Exit:** transport tests against the stub (both configurations); provider
resolution tests; live smoke gated on Ollama being installed — otherwise
documented as the milestone's human check.

## M20 — Phase 2 hardening & exit

Grounding drill: questions with no relevant entries must decline (never
answer from world knowledge — adversarial cases in tests); provider
failures mid-thread leave the thread intact; provider-swap drill
(openrouter ↔ ollama mid-session: pipeline, chat, and search all follow;
mixed-provenance vectors retrieve together). Chat spend visible in the
Settings month line (stage `chat`). Retrieval quality spot-check against
the real journal; echo/context distance floors re-calibrated with more
data if needed. Docs updated.
**Exit:** tag **`v0.3.0-phase2`**.

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
