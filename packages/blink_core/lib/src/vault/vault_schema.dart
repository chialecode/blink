import 'package:sqlite3/sqlite3.dart';

/// Current portable vault container format version stored in `vault.json`.
const int currentVaultFormatVersion = 1;

/// Current SQLite schema version stored in `vault.json` and `vault_meta`.
const int currentVaultSchemaVersion = 2;

/// Applies BLINK's mandatory SQLite WAL & safety pragmas on [db].
void applyBlinkSqlitePragmas(Database db) {
  db.execute('PRAGMA journal_mode=WAL;');
  db.execute('PRAGMA synchronous=NORMAL;');
  db.execute('PRAGMA busy_timeout=15000;');
  db.execute('PRAGMA foreign_keys=ON;');
  db.execute('PRAGMA temp_store=MEMORY;');
  db.execute('PRAGMA cache_size=-32000;');
}

/// Runs `PRAGMA wal_checkpoint(TRUNCATE)` on [db] before closing (`INV-07`).
void checkpointSqliteTruncate(Database db) {
  db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
}

/// Initializes schema v1 tables, indexes, and `v_normal_*` isolation views in `db/blink.db`.
void initializeMainDatabaseSchema(Database db) {
  db.execute('''
CREATE TABLE IF NOT EXISTS vault_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS raw_entries (
  id TEXT PRIMARY KEY,
  entry_kind TEXT NOT NULL CHECK(entry_kind IN ('blink', 'diary', 'voice_note', 'photo_note')),
  body_md TEXT NOT NULL,
  audio_blob_sha256 TEXT NULL,
  image_blob_sha256s TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(image_blob_sha256s)),
  source_ref_id TEXT NULL,
  capture_origin TEXT NOT NULL CHECK(capture_origin IN ('app_ui', 'share_sheet', 'cli_capture', 'mcp_capture', 'chat_promoted')),
  privacy_level TEXT NOT NULL CHECK(privacy_level IN ('normal', 'private')),
  revision INTEGER NOT NULL DEFAULT 1,
  hlc_ts TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT NULL
);
CREATE INDEX IF NOT EXISTS idx_raw_entries_active_created
  ON raw_entries (deleted_at, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_raw_entries_privacy
  ON raw_entries (privacy_level, deleted_at, created_at DESC);

CREATE TABLE IF NOT EXISTS raw_sources (
  id TEXT PRIMARY KEY,
  source_kind TEXT NOT NULL CHECK(source_kind IN ('web_article', 'epub', 'pdf', 'book_record')),
  title TEXT NOT NULL,
  authors_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(authors_json)),
  origin_url TEXT NULL,
  file_blob_sha256 TEXT NULL,
  cover_blob_sha256 TEXT NULL,
  ast_version INTEGER NOT NULL DEFAULT 1,
  ingest_state TEXT NOT NULL DEFAULT 'queued' CHECK(ingest_state IN ('queued', 'parsing', 'ready', 'failed')),
  ingest_error TEXT NULL,
  text_layer TEXT NOT NULL DEFAULT 'not_applicable' CHECK(text_layer IN ('embedded', 'missing_ocr', 'not_applicable')),
  reading_progress_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(reading_progress_json)),
  privacy_level TEXT NOT NULL DEFAULT 'normal' CHECK(privacy_level IN ('normal', 'private')),
  revision INTEGER NOT NULL DEFAULT 1,
  hlc_ts TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT NULL
);

CREATE TABLE IF NOT EXISTS raw_source_chapters (
  source_id TEXT NOT NULL REFERENCES raw_sources(id) ON DELETE CASCADE,
  chapter_id TEXT NOT NULL,
  order_index INTEGER NOT NULL,
  chapter_title TEXT NOT NULL,
  ast_json TEXT NOT NULL CHECK(json_valid(ast_json)),
  plain_text_len INTEGER NOT NULL DEFAULT 0,
  ast_sha256 TEXT NOT NULL,
  PRIMARY KEY (source_id, chapter_id)
);

CREATE TABLE IF NOT EXISTS raw_annotations (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL REFERENCES raw_sources(id) ON DELETE CASCADE,
  anchor_kind TEXT NOT NULL CHECK(anchor_kind IN ('ast_range', 'pdf_bbox', 'book_page')),
  anchor_json TEXT NOT NULL CHECK(json_valid(anchor_json)),
  quoted_excerpt TEXT NOT NULL,
  note_md TEXT NOT NULL,
  style_token TEXT NOT NULL DEFAULT 'highlight_yellow',
  anchor_status TEXT NOT NULL DEFAULT 'exact' CHECK(anchor_status IN ('exact', 'reanchored', 'orphan')),
  privacy_level TEXT NOT NULL CHECK(privacy_level IN ('normal', 'private')),
  revision INTEGER NOT NULL DEFAULT 1,
  hlc_ts TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT NULL
);

CREATE TABLE IF NOT EXISTS raw_marginalia_turns (
  id TEXT PRIMARY KEY,
  annotation_id TEXT NOT NULL REFERENCES raw_annotations(id) ON DELETE CASCADE,
  turn_index INTEGER NOT NULL,
  role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
  content_md TEXT NOT NULL,
  model_id TEXT NULL,
  privacy_level TEXT NOT NULL CHECK(privacy_level IN ('normal', 'private')),
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS raw_tasks (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('open', 'done', 'deferred', 'dropped')),
  origin_entry_id TEXT NULL,
  origin_annotation_id TEXT NULL,
  origin_line_index INTEGER NULL,
  focus_date TEXT NULL,
  completed_at TEXT NULL,
  privacy_level TEXT NOT NULL CHECK(privacy_level IN ('normal', 'private')),
  revision INTEGER NOT NULL DEFAULT 1,
  hlc_ts TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT NULL
);
CREATE INDEX IF NOT EXISTS idx_raw_tasks_origin_entry
  ON raw_tasks (origin_entry_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_raw_tasks_status_privacy
  ON raw_tasks (status, privacy_level, deleted_at);

CREATE TABLE IF NOT EXISTS media_blobs (
  sha256 TEXT PRIMARY KEY,
  mime_type TEXT NOT NULL,
  byte_size INTEGER NOT NULL,
  width INTEGER NULL,
  height INTEGER NULL,
  duration_ms INTEGER NULL,
  storage_rel_path TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS ai_entry_enrichments (
  entry_id TEXT PRIMARY KEY,
  intent_tags_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(intent_tags_json)),
  matched_source_ids_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(matched_source_ids_json)),
  verbatim_transcript_text TEXT NULL,
  clean_transcript_md TEXT NULL,
  ocr_extracted_quote TEXT NULL,
  model_id TEXT NOT NULL DEFAULT '',
  source_agent TEXT NOT NULL DEFAULT '',
  privacy_level TEXT NOT NULL CHECK(privacy_level IN ('normal', 'private')),
  computed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS ai_task_candidates (
  id TEXT PRIMARY KEY,
  origin_type TEXT NOT NULL CHECK(origin_type IN ('entry', 'annotation')),
  origin_id TEXT NOT NULL,
  title TEXT NOT NULL,
  rationale_md TEXT NOT NULL DEFAULT '',
  suggested_focus_date TEXT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending', 'accepted', 'dismissed')),
  privacy_level TEXT NOT NULL CHECK(privacy_level IN ('normal', 'private')),
  model_id TEXT NOT NULL DEFAULT '',
  computed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS ai_echo_links (
  id TEXT PRIMARY KEY,
  subject_type TEXT NOT NULL,
  subject_id TEXT NOT NULL,
  echo_owner_type TEXT NOT NULL,
  echo_owner_id TEXT NOT NULL,
  similarity REAL NOT NULL,
  relation_kind TEXT NOT NULL CHECK(relation_kind IN ('resonance', 'contrast', 'evolution')),
  reason_md TEXT NOT NULL DEFAULT '',
  privacy_scope TEXT NOT NULL CHECK(privacy_scope IN ('normal_only', 'local_with_private')),
  model_id TEXT NOT NULL DEFAULT '',
  computed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS ai_syntheses (
  id TEXT PRIMARY KEY,
  synth_kind TEXT NOT NULL CHECK(synth_kind IN ('morning_brief', 'evening_reconcile', 'weekly_review', 'book_synthesis', 'topic_page', 'chat_summary')),
  period_key TEXT NOT NULL,
  target_source_id TEXT NULL,
  title TEXT NOT NULL,
  privacy_scope TEXT NOT NULL CHECK(privacy_scope IN ('normal_only', 'local_with_private')),
  render_surface TEXT NOT NULL CHECK(render_surface IN ('surface1_native', 'surface2_sandbox')),
  summary_md TEXT NOT NULL,
  view_html TEXT NOT NULL,
  artifact_html TEXT NULL,
  citations_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(citations_json)),
  model_id TEXT NOT NULL DEFAULT '',
  source_agent TEXT NOT NULL DEFAULT '',
  computed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS ai_user_principles (
  id TEXT PRIMARY KEY,
  topic_slug TEXT NOT NULL,
  statement_md TEXT NOT NULL,
  view_html TEXT NULL,
  status TEXT NOT NULL DEFAULT 'candidate' CHECK(status IN ('candidate', 'confirmed', 'superseded', 'rejected')),
  evidence_ids_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(evidence_ids_json)),
  supersedes_id TEXT NULL,
  privacy_level TEXT NOT NULL CHECK(privacy_level IN ('normal', 'private')),
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS ai_bfm_links (
  id TEXT PRIMARY KEY,
  src_type TEXT NOT NULL CHECK(src_type IN ('entry', 'annotation')),
  src_id TEXT NOT NULL,
  target_kind TEXT NOT NULL CHECK(target_kind IN ('entry', 'annotation', 'source', 'ai', 'title_query')),
  target_id TEXT NULL,
  anchor TEXT NULL,
  privacy_level TEXT NOT NULL CHECK(privacy_level IN ('normal', 'private'))
);
CREATE INDEX IF NOT EXISTS idx_ai_bfm_links_src
  ON ai_bfm_links (src_type, src_id);
CREATE INDEX IF NOT EXISTS idx_ai_bfm_links_target
  ON ai_bfm_links (target_id, privacy_level);

CREATE TABLE IF NOT EXISTS sync_oplog (
  seq_id INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id TEXT NOT NULL,
  client_op_id TEXT NOT NULL,
  hlc_ts TEXT NOT NULL,
  base_revision INTEGER NOT NULL DEFAULT 0,
  entity_layer TEXT NOT NULL CHECK(entity_layer IN ('raw', 'ai')),
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  op_type TEXT NOT NULL,
  op_origin TEXT NOT NULL,
  privacy_level TEXT NOT NULL CHECK(privacy_level IN ('normal', 'private')),
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
  created_at TEXT NOT NULL,
  UNIQUE (device_id, client_op_id)
);
CREATE INDEX IF NOT EXISTS idx_sync_oplog_entity
  ON sync_oplog (entity_type, entity_id, seq_id DESC);
CREATE INDEX IF NOT EXISTS idx_sync_oplog_hlc
  ON sync_oplog (hlc_ts, device_id, client_op_id);

CREATE TABLE IF NOT EXISTS outbox_ops (
  client_op_id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  hlc_ts TEXT NOT NULL,
  base_revision INTEGER NOT NULL DEFAULT 0,
  entity_layer TEXT NOT NULL CHECK(entity_layer IN ('raw', 'ai')),
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  op_type TEXT NOT NULL,
  op_origin TEXT NOT NULL DEFAULT 'app_ui',
  privacy_level TEXT NOT NULL CHECK(privacy_level IN ('normal', 'private')),
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
  status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending', 'sent', 'failed')),
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_outbox_ops_status
  ON outbox_ops (status, created_at ASC, client_op_id ASC);

CREATE TABLE IF NOT EXISTS sync_devices (
  device_id TEXT PRIMARY KEY,
  device_name TEXT NOT NULL,
  token_sha256 TEXT NOT NULL,
  revoked_at TEXT NULL,
  last_seen_at TEXT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sync_conflicts (
  id TEXT PRIMARY KEY,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  local_copy_id TEXT NOT NULL,
  remote_device_id TEXT NOT NULL,
  remote_device_name TEXT NOT NULL DEFAULT '',
  remote_hlc_ts TEXT NOT NULL,
  local_body_md TEXT NOT NULL,
  remote_body_md TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open', 'resolved')),
  resolution TEXT NULL,
  created_at TEXT NOT NULL,
  resolved_at TEXT NULL
);
CREATE INDEX IF NOT EXISTS idx_sync_conflicts_status
  ON sync_conflicts (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sync_conflicts_entity
  ON sync_conflicts (entity_type, entity_id, status);

CREATE TABLE IF NOT EXISTS sync_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS media_cache_index (
  sha256 TEXT PRIMARY KEY,
  byte_size INTEGER NOT NULL,
  pinned INTEGER NOT NULL DEFAULT 0,
  last_accessed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS editor_drafts (
  draft_key TEXT PRIMARY KEY,
  body_md TEXT NOT NULL,
  entry_kind TEXT NOT NULL CHECK(entry_kind IN ('blink', 'diary', 'voice_note', 'photo_note')),
  privacy_locked INTEGER NOT NULL DEFAULT 0,
  image_blob_sha256s TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(image_blob_sha256s)),
  updated_at TEXT NOT NULL
);

CREATE VIEW IF NOT EXISTS v_normal_entries AS
  SELECT * FROM raw_entries WHERE privacy_level = 'normal' AND deleted_at IS NULL;

CREATE VIEW IF NOT EXISTS v_normal_tasks AS
  SELECT * FROM raw_tasks WHERE privacy_level = 'normal' AND deleted_at IS NULL;

CREATE VIEW IF NOT EXISTS v_normal_sources AS
  SELECT * FROM raw_sources WHERE privacy_level = 'normal' AND deleted_at IS NULL;

CREATE VIEW IF NOT EXISTS v_normal_annotations AS
  SELECT * FROM raw_annotations WHERE privacy_level = 'normal' AND deleted_at IS NULL;

CREATE VIEW IF NOT EXISTS v_normal_bfm_links AS
  SELECT * FROM ai_bfm_links WHERE privacy_level = 'normal';

CREATE VIEW IF NOT EXISTS v_normal_syntheses AS
  SELECT * FROM ai_syntheses WHERE privacy_scope = 'normal_only';
''');
}

/// Idempotent schema migration from v1 to v2 (`sync_conflicts`, sync indexes,
/// `outbox_ops.base_revision`/`op_origin`, and `sync_devices.last_seen_at`).
///
/// Must be invoked inside an active `BEGIN IMMEDIATE` transaction AFTER taking
/// a pre-migration `VACUUM INTO` hot snapshot (`INV-07`).
void migrateMainDatabaseV1ToV2(Database db) {
  db.execute('''
CREATE TABLE IF NOT EXISTS sync_conflicts (
  id TEXT PRIMARY KEY,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  local_copy_id TEXT NOT NULL,
  remote_device_id TEXT NOT NULL,
  remote_device_name TEXT NOT NULL DEFAULT '',
  remote_hlc_ts TEXT NOT NULL,
  local_body_md TEXT NOT NULL,
  remote_body_md TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open', 'resolved')),
  resolution TEXT NULL,
  created_at TEXT NOT NULL,
  resolved_at TEXT NULL
);
CREATE INDEX IF NOT EXISTS idx_sync_conflicts_status
  ON sync_conflicts (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sync_conflicts_entity
  ON sync_conflicts (entity_type, entity_id, status);
CREATE INDEX IF NOT EXISTS idx_sync_oplog_entity
  ON sync_oplog (entity_type, entity_id, seq_id DESC);
CREATE INDEX IF NOT EXISTS idx_sync_oplog_hlc
  ON sync_oplog (hlc_ts, device_id, client_op_id);
CREATE INDEX IF NOT EXISTS idx_outbox_ops_status
  ON outbox_ops (status, created_at ASC, client_op_id ASC);
''');

  final outboxCols = _tableColumnNames(db, 'outbox_ops');
  if (!outboxCols.contains('base_revision')) {
    db.execute(
      'ALTER TABLE outbox_ops ADD COLUMN base_revision INTEGER NOT NULL DEFAULT 0;',
    );
  }
  if (!outboxCols.contains('op_origin')) {
    db.execute(
      "ALTER TABLE outbox_ops ADD COLUMN op_origin TEXT NOT NULL DEFAULT 'app_ui';",
    );
  }

  // Backfill base_revision and op_origin on existing v1 outbox rows from sync_oplog.
  db.execute('''
UPDATE outbox_ops
SET
  base_revision = COALESCE(
    (
      SELECT o.base_revision
      FROM sync_oplog o
      WHERE o.device_id = outbox_ops.device_id
        AND o.client_op_id = outbox_ops.client_op_id
      LIMIT 1
    ),
    base_revision
  ),
  op_origin = COALESCE(
    (
      SELECT o.op_origin
      FROM sync_oplog o
      WHERE o.device_id = outbox_ops.device_id
        AND o.client_op_id = outbox_ops.client_op_id
      LIMIT 1
    ),
    op_origin
  );
''');

  final deviceCols = _tableColumnNames(db, 'sync_devices');
  if (!deviceCols.contains('last_seen_at')) {
    db.execute('ALTER TABLE sync_devices ADD COLUMN last_seen_at TEXT NULL;');
  }

  db.execute(
    "INSERT INTO vault_meta (key, value) VALUES ('schema_version', ?) "
    'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    <Object?>[currentVaultSchemaVersion.toString()],
  );
}

Set<String> _tableColumnNames(Database db, String tableName) {
  final rows = db.select('PRAGMA table_info($tableName);');
  return rows.map((row) => row['name'] as String).toSet();
}

/// Initializes isolated FTS5 schema (`fts_normal` and `fts_private`) in `index/fts.db` (`INV-03`, `INV-09`).
void initializeFtsDatabaseSchema(Database ftsDb) {
  ftsDb.execute('''
CREATE TABLE IF NOT EXISTS fts_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS fts_normal USING fts5(
  doc_id UNINDEXED,
  doc_kind UNINDEXED,
  updated_at UNINDEXED,
  content,
  tokenize='unicode61 remove_diacritics 2'
);

CREATE VIRTUAL TABLE IF NOT EXISTS fts_private USING fts5(
  doc_id UNINDEXED,
  doc_kind UNINDEXED,
  updated_at UNINDEXED,
  content,
  tokenize='unicode61 remove_diacritics 2'
);
''');
}
