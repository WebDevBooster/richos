ALTER TABLE ecs_corrections RENAME TO ecs_corrections_v1;
CREATE TABLE ecs_corrections (
    correction_id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL,
    entity_id TEXT NOT NULL REFERENCES ecs_entities(entity_id),
    thread_id TEXT REFERENCES ecs_threads(thread_id),
    mode TEXT NOT NULL CHECK (mode IN ('explicit', 'inferred')),
    classification TEXT NOT NULL CHECK (classification IN (
        'unclassified', 'architecture', 'hook_test', 'skill_rule', 'wiki_loro', 'ecs',
        'principle'
    )),
    destination TEXT,
    content TEXT NOT NULL,
    entity_scope TEXT,
    temporal_scope TEXT,
    before_json TEXT,
    after_json TEXT,
    ambiguity_state TEXT NOT NULL CHECK (ambiguity_state IN (
        'unclassified', 'unambiguous', 'needs_ceo_clarification', 'not_applicable'
    )),
    apply_state TEXT NOT NULL CHECK (apply_state IN (
        'observed', 'candidate', 'accepted', 'applied', 'verified', 'reported',
        'queued_for_enforcement', 'failed', 'repair_required', 'rejected'
    )),
    report TEXT,
    report_ref TEXT,
    source_turn TEXT,
    source_ref TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision > 0)
);
INSERT INTO ecs_corrections (
    correction_id, person_id, entity_id, thread_id, mode, classification, destination,
    content, ambiguity_state, apply_state, report, source_ref, created_at, updated_at,
    revision
)
SELECT
    correction_id, person_id, entity_id, thread_id, mode, classification, destination,
    content,
    CASE WHEN mode = 'inferred' THEN 'not_applicable' ELSE 'needs_ceo_clarification' END,
    apply_state, report, source_ref, created_at, updated_at, revision
FROM ecs_corrections_v1;
DROP TABLE ecs_corrections_v1;

CREATE INDEX IF NOT EXISTS ecs_corrections_scope_idx
    ON ecs_corrections(entity_id, thread_id, apply_state, updated_at);

CREATE TABLE IF NOT EXISTS ecs_turn_extractions (
    extraction_id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL,
    entity_id TEXT NOT NULL REFERENCES ecs_entities(entity_id),
    thread_id TEXT REFERENCES ecs_threads(thread_id),
    session_id TEXT,
    turn_id TEXT NOT NULL,
    source_kind TEXT NOT NULL CHECK (source_kind IN ('ceo_prompt', 'rich_reply')),
    block_present INTEGER NOT NULL CHECK (block_present IN (0, 1)),
    statements INTEGER NOT NULL CHECK (statements >= 0),
    applied INTEGER NOT NULL CHECK (applied >= 0),
    rejected INTEGER NOT NULL CHECK (rejected >= 0),
    rejections_json TEXT NOT NULL,
    source_ref TEXT NOT NULL,
    extracted_at TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision > 0),
    UNIQUE(turn_id, source_kind)
);

CREATE INDEX IF NOT EXISTS ecs_turn_extractions_scope_idx
    ON ecs_turn_extractions(entity_id, thread_id, source_kind, extracted_at);
