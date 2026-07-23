// Schema migrations — the §4 schema, verbatim. v1 creates everything
// (Phase 0 + Phase 1 tables) so completing an entry can enqueue pipeline
// rows from day one (AC-003); the Phase 1 workers arrive later.
import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // ── 4.1 Core journaling ─────────────────────────────────────
            try db.execute(sql: """
                CREATE TABLE entries (
                    id           TEXT PRIMARY KEY,
                    title        TEXT,
                    body         TEXT NOT NULL DEFAULT '',
                    entry_date   TEXT NOT NULL,
                    status       TEXT NOT NULL DEFAULT 'draft'
                                 CHECK (status IN ('draft','completed')),
                    word_count   INTEGER NOT NULL DEFAULT 0,
                    place        TEXT,
                    weather      TEXT,
                    is_milestone INTEGER NOT NULL DEFAULT 0,
                    is_deleted   INTEGER NOT NULL DEFAULT 0,
                    created_at   TEXT NOT NULL,
                    updated_at   TEXT NOT NULL,
                    completed_at TEXT
                );
                CREATE INDEX idx_entries_date   ON entries(entry_date);
                CREATE INDEX idx_entries_status ON entries(status);

                CREATE TABLE media (
                    id               TEXT PRIMARY KEY,
                    entry_id         TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                    file_path        TEXT NOT NULL,
                    thumbnail_path   TEXT,
                    media_type       TEXT NOT NULL CHECK (media_type IN ('photo','video')),
                    mime_type        TEXT NOT NULL,
                    file_size_bytes  INTEGER NOT NULL,
                    width            INTEGER,
                    height           INTEGER,
                    duration_seconds REAL,
                    sort_order       INTEGER NOT NULL DEFAULT 0,
                    created_at       TEXT NOT NULL
                );
                CREATE INDEX idx_media_entry ON media(entry_id);

                CREATE VIRTUAL TABLE entries_fts USING fts5(
                    title, body, content='entries', content_rowid='rowid'
                );
                CREATE TRIGGER entries_fts_ai AFTER INSERT ON entries BEGIN
                    INSERT INTO entries_fts(rowid, title, body)
                    VALUES (new.rowid, new.title, new.body);
                END;
                CREATE TRIGGER entries_fts_ad AFTER DELETE ON entries BEGIN
                    INSERT INTO entries_fts(entries_fts, rowid, title, body)
                    VALUES ('delete', old.rowid, old.title, old.body);
                END;
                CREATE TRIGGER entries_fts_au AFTER UPDATE ON entries BEGIN
                    INSERT INTO entries_fts(entries_fts, rowid, title, body)
                    VALUES ('delete', old.rowid, old.title, old.body);
                    INSERT INTO entries_fts(rowid, title, body)
                    VALUES (new.rowid, new.title, new.body);
                END;

                CREATE TABLE settings (
                    key        TEXT PRIMARY KEY,
                    value      TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                """)

            // ── 4.2 AI pipeline & metadata ──────────────────────────────
            try db.execute(sql: """
                CREATE TABLE pipeline_jobs (
                    id          TEXT PRIMARY KEY,
                    entry_id    TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                    stage       TEXT NOT NULL
                                CHECK (stage IN ('extraction','reflection','embedding')),
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

                CREATE TABLE entry_reflection (
                    entry_id        TEXT PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
                    summary         TEXT,
                    mood_label      TEXT,
                    mood_confidence REAL,
                    sentiment_score REAL,
                    energy          TEXT,
                    reflection_note TEXT,
                    model           TEXT,
                    model_version   TEXT,
                    created_at      TEXT NOT NULL
                );

                CREATE TABLE themes (
                    id   TEXT PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE
                );
                CREATE TABLE entry_themes (
                    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                    theme_id TEXT NOT NULL REFERENCES themes(id) ON DELETE CASCADE,
                    PRIMARY KEY (entry_id, theme_id)
                );

                CREATE TABLE entry_tags (
                    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                    tag      TEXT NOT NULL,
                    PRIMARY KEY (entry_id, tag)
                );

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

                CREATE TABLE self_questions (
                    id         TEXT PRIMARY KEY,
                    entry_id   TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                    text       TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                """)

            // ── 4.3 Embeddings (versioned) ──────────────────────────────
            try db.execute(sql: """
                CREATE TABLE embeddings_meta (
                    id            INTEGER PRIMARY KEY,
                    entry_id      TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                    chunk_index   INTEGER NOT NULL DEFAULT 0,
                    model         TEXT NOT NULL,
                    model_version TEXT NOT NULL,
                    dim           INTEGER NOT NULL,
                    status        TEXT NOT NULL DEFAULT 'current'
                                  CHECK (status IN ('current','stale')),
                    embedded_at   TEXT NOT NULL,
                    UNIQUE(entry_id, chunk_index, model, model_version)
                );
                CREATE INDEX idx_emb_entry ON embeddings_meta(entry_id);
                CREATE INDEX idx_emb_stale ON embeddings_meta(status);

                CREATE VIRTUAL TABLE vec_entries USING vec0(
                    embedding float[1024]
                );
                """)
        }

        return migrator
    }
}
