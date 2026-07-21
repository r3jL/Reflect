# Genesis Spec — Local macOS Journaling App (working name: **Reflect**)

> **Status:** MVP-ready spec for AI coding agent initialization.
> **MVP scope:** Phase 0 (Journal Core) + Phase 1 (Extraction & Reflection).
> **Owner:** Jatin Chaudhary
> **Stack:** Native **Swift/SwiftUI** (revised 2026-07-21 from Tauri v2 — see DEC-06).
> **Last updated:** 2026-07-21

This document is the single source of truth for building v1. Sections 1–9 are authoritative. Two open items are marked `[NEEDS CLARIFICATION]` and must not be built until resolved.

---

## 1. Vision & Business Context

### 1.1 Problem
Journaling captures raw thought, but the value of a journal compounds only if you can *look back across it*. Manually re-reading months of entries to answer "when was I happiest?", "what have I stopped writing about?", or "which struggles keep recurring?" is impractical. Existing journaling apps either don't understand entry content at all, or route your most private writing through opaque cloud services with no local-first guarantee.

### 1.2 Solution
A **local-first macOS journaling app** where the user writes entries (text + photos + videos), and a layered AI system continuously builds structured understanding *on top of* the entries — never modifying the original text. Over time the app becomes a queryable, reflective model of the user's own thoughts.

### 1.3 Core principles (non-negotiable)
- **Immutable source of truth.** The user's written entry text is authored only by the user. AI never rewrites, replaces, or edits entry bodies. All AI output is stored as *separate, derived metadata*.
- **Offline-first.** All core journaling (write, attach media, browse, search, voice→text) works with zero network. AI enrichment queues and runs when a provider is reachable.
- **Provider-interchangeable AI.** All AI capability sits behind an abstraction that can be pointed at a cloud API or a local model via a settings toggle. v1 ships the cloud (OpenRouter) adapter and local Whisper; the local-LLM adapter interface is defined but its implementation is deferred.
- **Never fabricate.** On any AI failure, store `null` + a non-blocking warning. Never invent metadata.

### 1.4 Target audience
Primary (v1): the author — a single technical user on macOS (Apple Silicon), journaling ~1–2 entries/day, who wants long-horizon reflection over years of entries. Secondary (future): privacy-conscious individuals who want an on-device reflective journal. **Not** a multi-user or team product in v1.

### 1.5 Why it needs to exist
No shipping product combines: (a) true local-first storage, (b) a layered knowledge system (not a stateless chatbot), and (c) provider-swappable AI. This spec is that combination.

---

## 2. Success Outcomes & KPIs

All targets are for MVP (Phase 0 + 1) on a target machine: Apple Silicon Mac, ≤10,000 entries.

| ID | Metric | Target |
|----|--------|--------|
| KPI-01 | Cold app start to interactive | < 2.0 s |
| KPI-02 | Entry local write (draft save / complete) | < 100 ms; P95 < 200 ms |
| KPI-03 | Photo attach + thumbnail generated | < 1.0 s |
| KPI-04 | Short video (≤60 s) attach + thumbnail | < 3.0 s |
| KPI-05 | Keyword (FTS5) search over 10k entries | < 150 ms |
| KPI-06 | Semantic top-k retrieval (`sqlite-vec`, 10k vectors) | < 100 ms |
| KPI-07 | Extraction + Reflection pipeline (post-Complete, background) | P95 < 15 s |
| KPI-08 | Local Whisper transcription, 15 s clip | < 5 s |
| KPI-09 | Core journaling functional with no network | 100% of Phase 0 features |
| KPI-10 | AI spend | < $5/month (MVP target < $1/month) |
| KPI-11 | Data durability (crash/kill during write) | 0 lost committed entries (WAL + atomic writes) |
| KPI-12 | Pipeline failure handling | 100% of failures → `null` + warning, never fabricated data |

---

## 3. Foundational Tech Stack

> **Revision note (2026-07-21):** v1 is a **native Swift app**, replacing the earlier Tauri v2 (Rust + web) plan. Drivers: best-in-class writing feel (native text editing), the OS integration Apple's Journal app competes on (Touch ID, Shortcuts, widgets, share extension, Journaling Suggestions API on iOS), and a first-class future iOS path via shared SwiftUI/core code. See DEC-06.

Pin the **major** versions below; agent should resolve latest compatible minor/patch at init.

### 3.1 Application shell
- **Swift 5.10+** (adopt Swift 6 language mode where practical), **SwiftUI** app lifecycle, **AppKit interop** where SwiftUI is insufficient (notably the entry editor).
- Deployment target: **macOS 14 (Sonoma)+**, Apple Silicon.
- Structure: one Xcode app target + local **SwiftPM packages** for the core (see §8), keeping domain logic UI-independent and directly reusable by a future iOS target.

### 3.2 Data layer
- **SQLite** via **GRDB** (Swift). WAL journal mode; foreign keys enabled; numbered migrations via GRDB's `DatabaseMigrator`.
- Keyword search: **SQLite FTS5** (first-class in GRDB).
- Vector search: **`sqlite-vec`** (`vec0` virtual tables). ⚠️ macOS's system SQLite disables loadable extensions, so the app must bundle its own SQLite: use GRDB's custom-SQLite build and compile `sqlite-vec`'s C amalgamation into the app, registering it via `sqlite3_auto_extension`. **This build setup is a week-1 de-risk task.**

### 3.3 UI layer
- **SwiftUI** throughout; `@Observable` models; `NavigationSplitView` with sidebar (Today / Life / Insights, per the design).
- **Entry editor:** wrapped **`NSTextView`** via `NSViewRepresentable` — SwiftUI's `TextEditor` is not capable enough. `entries.body` persisted as plain Markdown text; live styling (headings, emphasis) applied through `NSTextStorage` attributes. Candidate base library: **STTextView**. **Highest-risk component — prototype before all other UI.**
- Charts (mood timeline): **Swift Charts** (native).
- Icons: **Lucide** (bundled as template images), per the design system.
- Styling: the **Classical design system** (§3.6) expressed as a Swift theme layer — the tokens are the single source of truth; no hard-coded colors/sizes in views.

### 3.4 AI layer
All via one **OpenRouter** OpenAI-compatible endpoint in v1, behind a provider abstraction (`AiProvider` **protocol**):
- **Extraction stage** model: `google/gemini-2.5-flash` (~$0.30 in / $2.50 out per 1M tokens).
- **Reflection stage** model: latest Claude Sonnet (`anthropic/claude-sonnet-4.6`; ~$3 in / $15 out per 1M).
- **Embeddings:** `bge-m3` at **1024 dimensions** — chosen because it is available *both* via OpenRouter and locally (Ollama/ONNX), so the future API↔local toggle uses the same model and vector space with no re-index.
- **Speech-to-text:** **self-hosted `whisper.cpp`** via its **SwiftPM package** (default model `large-v3-turbo`, configurable to a smaller model). Audio never leaves the device.
- Networking: `URLSession` + `Codable`; structured-JSON outputs validated against per-stage schemas.
- **API keys:** stored via **Keychain Services** (macOS Keychain), referenced (never persisted) in the DB.
- Pipeline orchestrator: Swift Concurrency (`actor`-based runner) driving the durable `pipeline_jobs` table.

### 3.5 Media
- Photo thumbnails: **ImageIO** (`CGImageSourceCreateThumbnailAtIndex`).
- Video poster frame + duration: **AVFoundation** (`AVAssetImageGenerator`, `AVAsset`) — **no ffmpeg dependency**.
- Attach via SwiftUI `PhotosPicker` and `fileImporter`; media files stored on disk in the app data directory; DB stores relative paths only.

### 3.6 Design direction — "Classical" design system
The visual design is fixed by the Classical design package (delivered 2026-07-21; tokenized CSS + full-page mockups + screenshots are the reference). Character: **editorial and book-like** — a quiet near-white page, serif type, hairline rules, color applied as stroke rather than fill, photographs matted like tipped-in book plates.

**Tokens (implement as a Swift `Theme`; never hard-code values in views):**

| Token | Value |
|---|---|
| Background | `#F3F2F2` |
| Surface | `#EAE9E9` |
| Text (ink) | `#201F1D` |
| Accent (single accent; mono scheme) | `#B68235` |
| Divider | ink @ 16% opacity (hairlines) |
| Neutral ramp 100–900 | `#F8F4F4 #EAE7E7 #D7D3D3 #BAB6B6 #9B9797 #7D7979 #605D5D #444141 #2D2B2B` |
| Accent ramp 100–900 | `#FFF3E4 #FFE3BF #FACB8D #E1AD66 #C28D41 #A06F24 #7D5411 #5A3B0A #3A270D` |
| Heading font | **Cormorant Garamond** — semibold ceiling; display sizes take the regular cut |
| Body font | **Lora** regular — tabular numerals (`tnum`) wherever numbers stand as figures |
| Type scale | h1–h6: 42 / 32 / 25 / 20 / 16 / 13; body 15pt, line-height 1.55 |
| Spacing scale | 4.6 / 9.2 / 13.8 / 18.4 / 27.6 / 36.8 pt |
| Radii | 2 / 4 / 7 pt |
| Shadows | soft ink-tinted, "a whisper" (sm/md/lg) |

**Rules (from the DS guide):**
- Draw with **borders, rules, underlines** — never solid accent fills. Buttons are **outlined** (1px accent border on transparent), cards are **bordered and unfilled**, kickers are small caps in accent.
- Photographs get the **plate treatment**: warm archival grade (sepia 0.22, saturation 0.82, contrast 1.05) inside a 6pt surface-colored mat with a hairline outline.
- Hover/pressed states tint from the accent ramp; keyboard focus is a 2pt accent ring. Accent-on-ground contrast is ~3:1 — fine for chrome and large text; use accent-700 for body-size accent text.
- Both fonts are OFL-licensed (Google Fonts) — **bundle them in the app**.
- Light theme is the default; the design includes a theme toggle — a dark variant may follow but is **not** MVP.

**Key screens (from the mockups):**
- **Sidebar:** brand, search field (⌘F), nav (Today / Life / Insights), theme toggle, profile row with journaling streak.
- **Life (month view):** calendar grid of entry cells; month header with season kicker ("SUMMER · 2025"), display-size month name, italic month summary line, and pages/photos/trips stat numerals; right rail with THIS MONTH stats and BOOKMARKS list.
- **Day/entry view:** weekday kicker, display-size date, mood chip ("● Felt Awe"), time-of-day section dividers ("— Dawn —"), justified body text, matted photos, entity/place tags, prev/next day arrows.

---

## 4. Initial Data Models & Schema

All tables are SQLite. `id` columns are `TEXT` UUIDv4 unless noted. Timestamps are `TEXT` ISO-8601 UTC. `[P0]`/`[P1]` = build phase.

### 4.1 Core journaling (Phase 0)

```sql
-- Entries: the immutable-by-AI source of truth.
CREATE TABLE entries (
    id           TEXT PRIMARY KEY,
    title        TEXT,                                  -- optional
    body         TEXT NOT NULL DEFAULT '',              -- Markdown; authored only by user
    entry_date   TEXT NOT NULL,                         -- the date the entry is "about"
    status       TEXT NOT NULL DEFAULT 'draft'
                 CHECK (status IN ('draft','completed')),
    word_count   INTEGER NOT NULL DEFAULT 0,
    is_deleted   INTEGER NOT NULL DEFAULT 0,            -- soft delete (trash)
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL,
    completed_at TEXT                                   -- set when status -> completed
);
CREATE INDEX idx_entries_date   ON entries(entry_date);
CREATE INDEX idx_entries_status ON entries(status);

-- Media attachments (files on disk; DB holds relative path only).
CREATE TABLE media (
    id               TEXT PRIMARY KEY,
    entry_id         TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    file_path        TEXT NOT NULL,                     -- relative to app media dir
    thumbnail_path   TEXT,
    media_type       TEXT NOT NULL CHECK (media_type IN ('photo','video')),
    mime_type        TEXT NOT NULL,
    file_size_bytes  INTEGER NOT NULL,
    width            INTEGER,
    height           INTEGER,
    duration_seconds REAL,                              -- video only
    sort_order       INTEGER NOT NULL DEFAULT 0,
    created_at       TEXT NOT NULL
);
CREATE INDEX idx_media_entry ON media(entry_id);

-- Full-text search over entry bodies (keyword, offline).
CREATE VIRTUAL TABLE entries_fts USING fts5(
    title, body, content='entries', content_rowid='rowid'
);
-- (Triggers to keep entries_fts in sync with entries on insert/update/delete.)

-- App settings + AI config (key/value). API keys are NOT stored here.
CREATE TABLE settings (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
-- e.g. keys: 'ai.enabled', 'ai.provider', 'ai.model.extraction',
--            'ai.model.reflection', 'ai.embedding.model', 'stt.model',
--            'security.app_lock'   (API key material lives in Keychain)
```

### 4.2 AI pipeline & metadata (Phase 1)

```sql
-- Async pipeline jobs: one row per (entry, stage). Retryable, offline-aware.
CREATE TABLE pipeline_jobs (
    id          TEXT PRIMARY KEY,
    entry_id    TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    stage       TEXT NOT NULL
                CHECK (stage IN ('extraction','reflection','embedding')),  -- 'memory' added P3
    status      TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','running','success','failed','skipped')),
    attempts    INTEGER NOT NULL DEFAULT 0,
    last_error  TEXT,
    provider    TEXT,
    model       TEXT,
    started_at  TEXT,
    finished_at TEXT,
    created_at  TEXT NOT NULL,
    UNIQUE(entry_id, stage)
);
CREATE INDEX idx_jobs_status ON pipeline_jobs(status);

-- Reflection stage output (1:1 with entry; superseded on re-run).
CREATE TABLE entry_reflection (
    entry_id        TEXT PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
    summary         TEXT,
    mood_label      TEXT,        -- e.g. down|low|neutral|good|great
    mood_confidence REAL,        -- 0.0–1.0
    sentiment_score REAL,        -- -1.0–1.0
    energy          TEXT,        -- low|medium|high
    reflection_note TEXT,        -- entry-LOCAL insight only in P1
    model           TEXT,
    model_version   TEXT,
    created_at      TEXT NOT NULL
);

-- Themes (canonical, deduped) + entry link (Extraction stage).
CREATE TABLE themes (
    id   TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);
CREATE TABLE entry_themes (
    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    theme_id TEXT NOT NULL REFERENCES themes(id) ON DELETE CASCADE,
    PRIMARY KEY (entry_id, theme_id)
);

-- Free-form tags per entry (Extraction stage).
CREATE TABLE entry_tags (
    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    tag      TEXT NOT NULL,
    PRIMARY KEY (entry_id, tag)
);

-- Entities (people, places, books, companies, projects) + link.
CREATE TABLE entities (
    id   TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN
         ('person','place','book','company','project','other')),
    UNIQUE(name, type)
);
CREATE TABLE entry_entities (
    entry_id  TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    PRIMARY KEY (entry_id, entity_id)
);

-- Action items / tasks (Extraction stage).
CREATE TABLE action_items (
    id         TEXT PRIMARY KEY,
    entry_id   TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    text       TEXT NOT NULL,
    status     TEXT NOT NULL DEFAULT 'open'
               CHECK (status IN ('open','done','dropped')),
    due_hint   TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX idx_actions_status ON action_items(status);

-- Self-questions the user posed (Extraction/Reflection stage).
CREATE TABLE self_questions (
    id         TEXT PRIMARY KEY,
    entry_id   TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    text       TEXT NOT NULL,
    created_at TEXT NOT NULL
);
```

### 4.3 Embeddings — versioned, migration-ready (Phase 1)

The `vec0` virtual table is **fixed-dimension** and cannot hold FKs or arbitrary columns. Vector metadata therefore lives in a normal table (`embeddings_meta`); the raw vector lives in `vec_entries`, joined by an integer key.

```sql
-- Vector metadata (versioning lives here). One row per (entry, chunk).
CREATE TABLE embeddings_meta (
    id            INTEGER PRIMARY KEY,   -- also the vec0 rowid
    entry_id      TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    chunk_index   INTEGER NOT NULL DEFAULT 0,
    model         TEXT NOT NULL,         -- e.g. 'bge-m3'
    model_version TEXT NOT NULL,         -- provenance for migration
    dim           INTEGER NOT NULL,      -- e.g. 1024
    status        TEXT NOT NULL DEFAULT 'current'
                  CHECK (status IN ('current','stale')),
    embedded_at   TEXT NOT NULL,
    UNIQUE(entry_id, chunk_index, model, model_version)
);
CREATE INDEX idx_emb_entry ON embeddings_meta(entry_id);
CREATE INDEX idx_emb_stale ON embeddings_meta(status);

-- The vector store. rowid == embeddings_meta.id. Dim fixed at 1024 in v1.
CREATE VIRTUAL TABLE vec_entries USING vec0(
    embedding float[1024]
);
```

**Migration design (documented; worker deferred — see §10):** exactly one embedding model is active at a time in v1. To migrate later: (1) create `vec_entries_v2` with the new dimension, (2) mark old rows `stale`, (3) a background worker re-embeds `stale`/missing entries incrementally into v2, (4) retrieval reads v2, falling back to v1 for not-yet-migrated entries during transition. The versioning columns above make this non-disruptive.

### 4.4 Roadmap schema (NOT built in v1 — documented for continuity)

- **Phase 3 — Memory:** `memories(id, type, title, description, confidence, importance, first_seen_at, last_updated_at, status)`, `memory_evidence(memory_id, entry_id, weight)`, `relationships(source_type, source_id, target_type, target_id, relation, weight)`. Reconciliation/merge logic → `[NEEDS CLARIFICATION]`.
- **Phase 4 — Insights & summaries:** `period_summaries(period_type, period_start, period_end, summary)`, `insights(type, title, description, evidence_json, confidence, dismissed)`.

---

## 5. Core Functional Modules (MVP = Phase 0 + Phase 1)

### 5.1 Phase 0 — Journal Core (no AI)
- **FR-001** Create a new entry in `draft` status.
- **FR-002** Edit entry body (native `NSTextView`-based editor), autosaving the draft; entry `word_count` recomputed.
- **FR-003** Complete an entry (`draft → completed`), setting `completed_at` and **enqueuing** the AI pipeline (Phase 1). Completion works offline (jobs stay `pending`).
- **FR-004** Edit a *completed* entry: allowed; on save, **re-enqueue** pipelines and **supersede** prior derived metadata (metadata rows replaced; the entry text is simply the user's new text — no AI versioning of the body).
- **FR-005** Attach one or more photos to an entry (copy into app media dir; record in `media`).
- **FR-006** Attach one or more videos to an entry.
- **FR-007** Generate and display thumbnails for all media (poster frame for video via AVFoundation).
- **FR-008** View an entry: read view with rendered body + media gallery + derived metadata (once available).
- **FR-009** Browse entries in a reverse-chronological timeline; jump by date.
- **FR-010** Soft-delete an entry to Trash (`is_deleted=1`); restore; empty-trash performs hard delete + cascades media file removal.
- **FR-011** Keyword search (FTS5) over titles/bodies; works offline.
- **FR-012** Full offline operation for all FR-001…FR-011.
- **FR-013** Settings: enable/disable AI, set OpenRouter API key (→ Keychain), choose per-stage models and STT model.
- **FR-014** Optional app lock (Touch ID) gating app open. *(Config: `security.app_lock`.)*

### 5.2 Phase 1 — Extraction & Reflection (AI enrichment)
- **FR-020** Async pipeline orchestrator: a durable job queue driving stages **Extraction → Reflection → (Memory: P3)**, with **Embedding** running in parallel. Per-stage `status`, bounded retries with backoff, offline-aware (runs when provider reachable).
- **FR-021** **Extraction stage** (Gemini 2.5 Flash): from entry body, produce `themes`, `entry_tags`, `entities`, `action_items`, `self_questions`. One grouped structured-JSON call.
- **FR-022** **Reflection stage** (Claude Sonnet): depends on Extraction output; produce `summary`, `mood_label` + `mood_confidence`, `sentiment_score`, `energy`, entry-local `reflection_note`. One grouped structured-JSON call. **No cross-entry insights in P1.**
- **FR-023** **Embedding stage** (`bge-m3`, 1024): chunk long entries; write `embeddings_meta` + `vec_entries`. Runs in parallel with Extraction/Reflection.
- **FR-024** Null-plus-warning: any stage failure sets job `failed`, stores `last_error`, writes **no** fabricated metadata, and surfaces a **non-blocking** warning on the entry.
- **FR-025** Provider abstraction (`AiProvider` trait): v1 implements the OpenRouter adapter (extraction/reflection/embeddings) and local `whisper.cpp` STT. A `LocalLlmProvider` interface is defined but not implemented (Ollama impl = Phase 2+).
- **FR-026** Mood timeline view: chart `mood_label`/`sentiment_score` over time; answers "when was I down / happy" by navigation and filtering.
- **FR-027** Theme & entity browse: filter/reflect on entries by theme, tag, person, place, book, company, or project.
- **FR-028** Action-items view: surface `open` action items aggregated across entries; mark done/dropped.
- **FR-029** Voice input: record → local Whisper transcription → insert transcribed text into the entry editor (works offline).
- **FR-030** Embedding versioning: persist `model`/`model_version`/`dim` per vector; single active model in v1; schema migration-ready (worker deferred).
- **FR-031** Manual re-run: user can re-trigger the pipeline for a failed or edited entry.

---

## 6. Primary User Flows

### 6.1 First-run / onboarding
1. Launch app → landing/timeline (empty state).
2. (Optional) Open Settings → paste OpenRouter API key (stored in Keychain), confirm default models. **Skippable** — the journal is fully usable offline without AI.
3. Tap **New Entry** → editor opens (`draft`).
4. Write text (optionally tap mic for voice→text, optionally attach photos/videos).
5. Tap **Complete** → entry saved as `completed`; pipeline enqueues.
6. Within seconds (if AI enabled + online), the entry view populates with summary, mood, themes, entities, tasks. If offline/disabled, entry shows as completed with a subtle "AI pending" indicator.

### 6.2 Core daily loop
`New Entry → write (+voice/+media) → Complete → [background pipeline] → view enriched entry`.

### 6.3 Reflection
1. Open **Reflect** tab.
2. View **mood timeline**; scrub to a low/high period.
3. Or filter by **theme / person / project**.
4. Tap any point/facet → open the underlying entry.

> Free-form chat ("ask my journal") is **Phase 2** — see §9 Non-Goals.

---

## 7. Acceptance Criteria (Given-When-Then)

### Journal core
- **AC-001** *Create.* GIVEN the timeline, WHEN the user taps New Entry, THEN a `draft` row is created and the editor opens focused on the body.
- **AC-002** *Autosave.* GIVEN an open draft with unsaved text, WHEN 2 s of idle elapse OR the editor loses focus, THEN `body`, `word_count`, `updated_at` persist and the write completes in < 200 ms (P95).
- **AC-003** *Complete triggers pipeline.* GIVEN a draft, WHEN the user taps Complete, THEN `status='completed'`, `completed_at` is set, AND three `pipeline_jobs` rows (`extraction`,`reflection`,`embedding`) are created with `status='pending'`.
- **AC-004** *Complete works offline.* GIVEN no network, WHEN the user taps Complete, THEN the entry is saved as completed and jobs remain `pending` (no error shown to the user beyond an "AI pending" indicator).
- **AC-005** *Edit supersedes metadata.* GIVEN a completed entry with derived metadata, WHEN the user edits and re-saves it, THEN prior `entry_reflection`/theme/entity/action/question rows for that entry are replaced and jobs are re-enqueued; the entry `body` reflects exactly the user's new text with no AI alteration.
- **AC-006** *Photo attach.* GIVEN the editor, WHEN the user attaches a photo, THEN the file is copied into the media dir, a `media` row (`media_type='photo'`) and a thumbnail are created within 1 s, and the thumbnail renders in the gallery.
- **AC-007** *Video attach.* GIVEN the editor, WHEN the user attaches a ≤60 s video, THEN a `media` row (`media_type='video'`, `duration_seconds` set) and a poster-frame thumbnail are created within 3 s.
- **AC-008** *Soft delete.* GIVEN an entry, WHEN the user deletes it, THEN `is_deleted=1` and it leaves the timeline but remains in Trash; WHEN Trash is emptied, THEN the row and its media files are permanently removed.
- **AC-009** *Keyword search offline.* GIVEN ≥1 completed entry and no network, WHEN the user searches a term present in a body, THEN matching entries return in < 150 ms.
- **AC-010** *Immutability.* GIVEN any AI pipeline run, WHEN it completes, THEN `entries.body` is byte-for-byte unchanged from what the user authored.

### AI pipeline (Phase 1)
- **AC-020** *Stage ordering.* GIVEN a completed entry with AI enabled + online, WHEN the pipeline runs, THEN Reflection does not start until Extraction is `success`, AND Embedding may run concurrently with Extraction/Reflection.
- **AC-021** *Extraction output.* GIVEN a non-trivial entry, WHEN Extraction succeeds, THEN zero-or-more rows exist across `themes`/`entry_tags`/`entities`/`action_items`/`self_questions`, all linked to the entry.
- **AC-022** *Reflection output.* GIVEN Extraction success, WHEN Reflection succeeds, THEN exactly one `entry_reflection` row exists with `mood_confidence` in [0,1] and `sentiment_score` in [-1,1].
- **AC-023** *Embedding written.* GIVEN AI enabled, WHEN Embedding succeeds, THEN ≥1 `embeddings_meta` row (`model='bge-m3'`, `dim=1024`, `status='current'`) and a matching `vec_entries` row exist.
- **AC-024** *Failure = null + warning.* GIVEN a stage that errors on all retries, WHEN it finally fails, THEN its job is `failed` with `last_error` populated, NO derived rows for that stage are written, AND a non-blocking warning appears on the entry.
- **AC-025** *Offline queue drains.* GIVEN `pending` jobs created offline, WHEN network returns, THEN the orchestrator processes them without user action.
- **AC-026** *Mood timeline.* GIVEN ≥2 entries with reflections, WHEN the user opens Reflect, THEN a timeline plots each entry's mood/sentiment and tapping a point opens that entry.
- **AC-027** *Theme filter.* GIVEN entries tagged with a theme, WHEN the user selects that theme, THEN only entries linked to it are listed.
- **AC-028** *Voice transcription local.* GIVEN AI/STT configured, WHEN the user records 15 s of speech, THEN transcription completes on-device in < 5 s with no network egress and the text is inserted at the cursor.
- **AC-029** *Provider swap does not corrupt vectors.* GIVEN the active embedding model is `bge-m3`, WHEN a vector is written, THEN its `model`/`model_version`/`dim` are recorded such that a future model change can be detected per-vector.
- **AC-030** *Cost guard.* GIVEN a month of ~60 completed entries, WHEN measured, THEN AI spend is < $5 (expected ~$0.40–0.50).
- **AC-031** *Manual re-run.* GIVEN a `failed` stage, WHEN the user taps Re-run, THEN a new job attempt is enqueued.

---

## 8. Proposed Directory Structure

```
Reflect/
├─ Reflect.xcodeproj
├─ Reflect/                        # app target (SwiftUI, macOS)
│  ├─ ReflectApp.swift             # @main; DB + orchestrator bootstrap
│  ├─ Features/
│  │  ├─ Timeline/                 # Today + reverse-chron browse, date jump
│  │  ├─ Life/                     # month calendar view (per design)
│  │  ├─ Entry/                    # read view, metadata panels, media gallery
│  │  ├─ Editor/                   # NSTextView wrapper + voice button
│  │  ├─ Insights/                 # mood timeline (Swift Charts), theme/entity
│  │  │                            #   browse, action items
│  │  ├─ Settings/                 # AI config, models, app lock
│  │  ├─ Trash/
│  │  └─ Search/                   # FTS5 keyword search (⌘F)
│  ├─ DesignSystem/                # Classical theme: Color+Theme, Typography,
│  │                               #   Spacing, components (buttons, cards,
│  │                               #   tags, plate image style)
│  ├─ Resources/                   # bundled fonts (Cormorant Garamond, Lora),
│  │                               #   Lucide icons, Assets.xcassets
│  └─ Support/                     # app lock (LocalAuthentication), misc
├─ Packages/
│  ├─ ReflectCore/                 # UI-independent domain core (SwiftPM)
│  │  └─ Sources/ReflectCore/
│  │     ├─ Database/              # GRDB setup, WAL/pragmas, sqlite-vec
│  │     │                         #   registration, DatabaseMigrator migrations
│  │     ├─ Models/                # Entry, Media, Reflection, Theme, Entity…
│  │     ├─ Repositories/          # entries, media, metadata, embeddings, FTS
│  │     └─ Queue/                 # durable job queue, retry/backoff (actor)
│  ├─ ReflectAI/
│  │  └─ Sources/ReflectAI/
│  │     ├─ AiProvider.swift       # AiProvider + LocalLlmProvider protocols
│  │     ├─ OpenRouterProvider.swift  # chat + embeddings adapter
│  │     ├─ Prompts/               # extraction.md, reflection.md (+ JSON schemas)
│  │     └─ Pipeline/              # orchestrator, extraction, reflection,
│  │                               #   embedding stages
│  ├─ ReflectSTT/                  # whisper.cpp SwiftPM wrapper, model mgmt
│  └─ ReflectMedia/                # ImageIO thumbnails, AVFoundation posters
├─ design/                         # Classical design package (tokens CSS,
│                                  #   mockups, screenshots) — reference only
└─ README.md
```

Notes: `ReflectCore`/`ReflectAI`/`ReflectSTT`/`ReflectMedia` import no UI frameworks — a future iOS target consumes them unchanged. Keychain access lives in `ReflectAI` (key storage) via Keychain Services.

---

## 9. Non-Goals (v1)

Explicitly **out of scope** for MVP, to prevent over-engineering:
1. **Free-form chat assistant** ("ask my journal") — Phase 2.
2. **Persistent memory system + knowledge graph** (`memories`, `relationships`, reconciliation) — Phase 3.
3. **Insight Engine** (proactive cross-entry patterns) and **hierarchical summaries** (weekly/monthly/yearly) — Phase 4.
4. **AI on media** — no image captioning, no video analysis. Media is stored/displayed only.
5. **Multiple simultaneous embedding models.** One active model; versioned for future migration.
6. **The embedding backfill worker.** Schema + migration design ship in v1; the incremental re-embed worker is deferred.
7. **Local LLM (Ollama) execution.** Interface defined; implementation deferred (STT is the only local model in v1).
8. **Cloud sync, multi-device, mobile, sharing/collaboration, multi-user/accounts.**
9. **Non-macOS platforms.**

---

## 10. Open Decisions & Clarifications

### `[NEEDS CLARIFICATION]` (must resolve before its phase is built)
- **CLR-01 — Memory reconciliation (Phase 3).** How a new entry updates existing memories vs. creates new ones: exact match threshold (embedding similarity + type), merge rules (evidence append, confidence update, `last_updated`), and dormancy/resolution transitions. Proposed starting algorithm exists but thresholds/merge logic are undecided. **Do not build Phase 3 memory until resolved.**

### Defaults chosen by architect — veto if desired
- **DEC-01 — Embedding migration worker timing.** Shipping versioning schema + documented migration in v1; **deferring the backfill worker** until a second embedding model is actually needed. *(Confirm defer, or build the worker in v1.)*
- **DEC-02 — Entry editor. ✅ Resolved (2026-07-21, with DEC-06):** wrapped `NSTextView` via `NSViewRepresentable`; `body` persisted as plain Markdown; live styling via `NSTextStorage` attributes; STTextView as candidate base. SwiftUI `TextEditor` rejected (insufficient). Prototype first — highest-risk component. *(Supersedes TipTap.)*
- **DEC-03 — Whisper model.** Default `large-v3-turbo` (accuracy on Apple Silicon; ~larger download). Configurable to a smaller model for speed/size. *(Confirm default.)*
- **DEC-04 — Reflection model pin.** Default to the latest Claude Sonnet (4.6) rather than pinning the 4.0 snapshot. *(Confirm.)*
- **DEC-05 — DB-at-rest encryption.** v1 relies on macOS FileVault + optional Touch ID app lock (FR-014). SQLCipher whole-DB encryption is available as an add-on but not enabled by default. *(Confirm, or require SQLCipher in v1.)*
- **DEC-06 — Application stack. ✅ Decided (2026-07-21):** native **Swift/SwiftUI** replaces the original Tauri v2 (Rust + React) plan. Drivers: native writing feel, macOS/iOS system integration (Touch ID, Shortcuts, widgets, share extension, Journaling Suggestions API on iOS), and a shared-code path to a future iOS app. Consequences: GRDB replaces `rusqlite`; AVFoundation replaces ffmpeg; Swift Charts replaces Recharts; Swift Concurrency actor replaces the Rust queue; the Classical design tokens are re-expressed as a Swift theme (§3.6). Schema (§4), functional modules (§5), flows (§6), and acceptance criteria (§7) are unchanged.

---

## Appendix A — AI Pipeline (adopted architecture)

```
Journal Completed
      │
      ▼
┌───────────────────────────┐
│ Extraction  (Gemini 2.5   │  themes, tags, entities,
│ Flash)                    │  action items, self-questions
└───────────────────────────┘
      │ (success required)
      ▼
┌───────────────────────────┐
│ Reflection  (Claude       │  summary, mood+confidence,
│ Sonnet)                   │  sentiment, energy, entry-local note
└───────────────────────────┘
      │
      ▼
┌───────────────────────────┐
│ Memory      (Phase 3)     │  persistent memories + graph
└───────────────────────────┘

Embedding (bge-m3, 1024)  ── runs in PARALLEL (needs only raw entry text)
```

**Phase-1 active stages:** Extraction, Reflection (entry-local), Embedding. Memory stage and cross-entry insights activate in later phases.

## Appendix B — Phase Roadmap
- **Phase 0** Journal Core (no AI) — *MVP*
- **Phase 1** Extraction & Reflection + Embeddings — *MVP*
- **Phase 2** Hybrid retrieval + free-form chat + (Ollama local LLM adapter)
- **Phase 3** Persistent memory system + relationship graph *(blocked on CLR-01)*
- **Phase 4** Insight Engine + hierarchical summaries
