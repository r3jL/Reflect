# Phase 0 Build Plan — Journal Core

> Ordered milestones for Phase 0 of the [genesis spec](../GENESIS_SPEC_journal_app.md).
> Each milestone is shippable-to-self: the app runs and is usable at every step.
> FR/AC/KPI references point at the spec. Design reference: `design/living-memory/`.

## M0 — De-risk spikes ✅ (2026-07-21)

| Spike | Result |
|---|---|
| `prototypes/DBSpike` | **Passed.** GRDB `DatabasePool` (WAL) + FTS5 + statically-linked sqlite-vec v0.1.9 in one connection. KNN top-5 over 10k×1024-dim vectors: **~18 ms** (KPI-06 <100ms ✅); FTS5 match <1 ms (KPI-05 ✅); FK cascades verified. **Key finding:** `sqlite3_auto_extension` is a no-op on Apple platforms — sqlite-vec must be registered **per-connection** via GRDB `Configuration.prepareDatabase` calling `sqlite3_vec_init` directly. No custom SQLite build needed. |
| `prototypes/EditorSpike` | **Builds & runs** (`cd prototypes/EditorSpike && swift run`). NSTextView wrapped in SwiftUI: 22pt serif with 1.45 leading, accent caret, undo/spell-check, margins fade to 25% while typing (restore after 1.2s idle), 2s-idle autosave hook, live word count. Human validation of typing feel pending. |

**Carry-forward decisions:** `DatabasePool` (not `DatabaseQueue`) for WAL; per-connection vec init; system serif (New York) stands in until Newsreader is bundled.

## M1 — Project scaffold & theme ✅ (2026-07-22)
Xcode app target `Reflect` (generated via **XcodeGen** — `xcodegen generate` from `project.yml`; the `.xcodeproj` is gitignored) + SwiftPM packages `ReflectCore` / `ReflectAI` / `ReflectSTT` / `ReflectMedia` (§8, stubs until M2). Living Memory `Theme` with **exact OKLCH→sRGB conversion at runtime** (OKLab reference math — spec values stay the source of truth), Newsreader variable fonts bundled (upright + italic, OFL; `ATSApplicationFontsPath`), top-bar shell (wordmark, Today/Life/Insights nav, Remember button stub with ⌘K), Today view with the working editor + margin fade, Life/Insights placeholder states. App sandbox on (user-selected files read-only).
**Result:** app builds, launches sandboxed, Newsreader registers; **cold start 1309 ms** (Debug) vs KPI-01 <2s ✅. Debug-only first-frame probe (sysctl process start → `onAppear`) left in for M9.

## M2 — Data layer (ReflectCore) ✅ (2026-07-23)
GRDB setup from the spike (`DatabasePool`/WAL, FK, per-connection vec init via `Configuration.prepareDatabase`), **migration v1 with the complete §4 schema** — Phase 0 *and* Phase 1 tables, so completing an entry enqueues `pipeline_jobs` rows from day one (AC-003). FTS5 external-content triggers (insert/update/delete), models (`Entry`/`Media`/`PipelineJob`, snake_case column mapping, ISO-8601 timestamps), repositories: `EntriesRepository` (draft→autosave→complete lifecycle, re-enqueue on completed-entry edit per FR-004, timeline/month/search/trash), `MediaRepository`, `SettingsRepository` (typed keys). Repos never touch the filesystem — trash/delete return file paths for the caller.
**Result:** 10/10 unit tests green (lifecycle+AC-003, FR-004 re-enqueue, FTS sync incl. prefix+snippet, trash-excluded search, cascade cleanup paths, month fetch, settings upsert, vec round-trip with `embeddings_meta` join). App target builds against the package.

## M3 — Today: the writing room (FR-001, 002, 003) ✅ (2026-07-23)
`TodayModel` (@Observable) wired to `EntriesRepository`: the day's draft loads or is created on appear (idempotent `fetchOrCreateForDate`, verified across relaunches), editor gains focus on appear (AC-001), autosave on 2s idle debounce + blur + app-quit flush (AC-002) with KPI-02 write-latency logging, live word count. Meta row: hollow mood dot (fills when reflection exists), editable place/weather (FR-015). Quiet "Complete entry" affordance → `completed_at` + three `pending` jobs (AC-003), then "Completed · AI pending" with breathing dot (AC-004). Completed-entry edits re-enqueue via the repo (FR-004). Margin metadata now real: words today, writing streak (consecutive-day computation), "on this day" count.
**Result:** app verified end-to-end against the sandboxed DB (draft row created on first launch, no duplicate on relaunch, jobs empty until Complete). Repo additions covered by tests (12/12 green).

## M4 — Life map + entry view (FR-008, 009) ✅ (2026-07-23)
`LifeModel` + rebuilt `LifeView`: season kicker, 88pt month, Sun-first calendar grid with leading blanks; day cells carry density bars (1–3 from `word_count`), mood wash + mood-colored bars (plumbed through `entry_reflection` — lights up when Phase 1 runs; ink fallback until then), photo glyph (from `media`), milestone diamonds, today accent ring, future-day dimming, hover lift + shadow, legend row. ‹›/←→ arrow keys navigate months. **Entry morph-open**: `matchedGeometryEffect` from cell → full read view with the design's 660ms `(0.22,1,0.36,1)` curve, scrim + tap/ESC close, content fade after settle; Reduce Motion falls back to plain transition. `EntryReadView`: serif date header, mood/place/draft meta row, paragraph rendering; prev/next entry buttons within the month. Repo additions: `moodLabels(entryIds:)`, `entryIdsWithMedia(_:)` (13/13 tests green). DEBUG seeder (`REFLECT_SEED=1`, idempotent) populates recent weeks.
**Result:** seeded month verified in the sandboxed DB (15 completed entries with gaps, milestones, 45 pending jobs); app builds and runs. 60fps morph feel = human check on real hardware.

## M5 — Media (FR-005, 006, 007) ✅ (2026-07-24)
`ReflectMedia.MediaStore`: originals copied into `media/`, ImageIO thumbnails (≤1200px) into `thumbnails/`, video poster + duration via AVFoundation (`AVAssetImageGenerator`, poster pulled from just inside the clip), UTType-based detection with unsupported-type cleanup, `remove(relativePaths:)`. **4 package tests with timing assertions green** — photo import ~36ms vs AC-006's 1s; video import (real H.264 fixture generated in-test via `AVAssetWriter`) ~0.7s vs AC-007's 3s. App side: attach via `fileImporter`, **Photos-library picker** (`PhotosPicker` → staged temp file → same import path), and **drag-and-drop** onto the writing column; `MediaFigure` renders figures in the design's style (soft shadow, mono `[ photo ]`/`[ video ]` caption, duration badge, click-to-play via system player, hover-remove in Today); galleries in Today and the morph-open read view. DEBUG `REFLECT_SEED_MEDIA=1` drives one generated photo through the real import path.
**Result:** verified in the sandboxed container — original + thumbnail files on disk, correct `media` row (type/mime/1600×1000, relative paths). Trash file cleanup wires up with the Trash UI in M7 (repo already returns paths; `store.remove` exists).

## M6 — Remember: keyword search (FR-011) ✅ (2026-07-24)
Full-screen overlay from the top-bar button or **⌘K**: veiled blur ground, 38pt light-serif prompt ("What are you trying to remember?"), focused on open. Debounced (150ms) FTS5 search with `snippet()`, results **grouped by month** (the group header component is facet-shaped, ready for Phase 1's People/Places/… facets), serif snippet rows → open the read view above the overlay (scale+fade; ESC walks back: entry → overlay → out). Suggestion chips when empty — recent places from FR-015 data plus fallbacks — via a small `FlowRow` layout. Static lead line until Phase 1's Reflection-stage sentence. `EntryReadView` prev/next now optional (hidden from search). ReflectCore: `recentPlaces()`; **AC-009/KPI-05 test: search over a 1,000-entry journal in <150ms** (15/15 tests green).
**Result:** app builds and launches with the overlay wired end-to-end; search is fully offline.

## M7 — Trash, Settings, app lock (FR-010, 013, 014)
Soft delete → Trash view, restore, empty-trash hard delete + media file cleanup (AC-008). Settings: OpenRouter key → Keychain Services, per-stage model pickers, STT model choice, AI on/off. Touch ID app lock (`LocalAuthentication`) gating launch.
**Exit:** AC-008 passes; key present in Keychain, never in DB (grep the DB file).

## M8 — Voice capture (FR-029 brought forward; on-device)
whisper.cpp via SwiftPM, `large-v3-turbo` with model download manager + smaller fallback; mic button in the editor; record → transcribe → insert at cursor. 15s clip <5s (AC-028, KPI-08); zero network egress (verify with a proxy/Little Snitch pass).
**Exit:** AC-028 passes. *(Listed under Phase 1 in the spec but has no cloud dependency; it completes the offline core promised by §1.3/KPI-09.)*

## M9 — Hardening & Phase 0 exit
KPI benchmark harness (cold start, write P95, search, thumbnail timings) run on a 10k-entry synthetic DB; crash-during-write test (kill -9 during autosave; WAL recovery, KPI-11); full offline pass of AC-001…AC-012 with networking disabled; Reduce Motion + keyboard-only + VoiceOver sanity pass.
**Exit:** every Phase 0 AC green offline → tag `v0.1.0-phase0`.

---
**Sequencing rationale:** M2 before any UI because every view reads through repos; Life/entry (M4) before media (M5) so media has surfaces to appear on; search before settings because it needs no configuration; voice late because it's the only piece with a heavyweight external dependency (whisper model download). Phase 1 (pipeline + extraction/reflection/embeddings → marginalia goes live) starts against the `pipeline_jobs` rows M3 already creates.
