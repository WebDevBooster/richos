ALTER TABLE ecs_events ADD COLUMN active_context_revision INTEGER;

CREATE TABLE ecs_trusted_authorities (
    authority_id TEXT PRIMARY KEY,
    verifier_contract TEXT NOT NULL,
    description TEXT NOT NULL,
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    source_ref TEXT NOT NULL
);

INSERT INTO ecs_trusted_authorities(
    authority_id, verifier_contract, description, enabled, source_ref
) VALUES
    ('git', 'git-cli-v1', 'Git object database verifier contract declaration', 0,
     'architecture:ecs-trusted-authorities-v1'),
    ('claude-code-task-store', 'claude-task-hook-v1',
     'Claude Code TaskCompleted lifecycle event declaration', 0,
     'architecture:ecs-trusted-authorities-v1'),
    ('live-system', 'live-authority-v1', 'Named live system verifier declaration', 0,
     'architecture:ecs-trusted-authorities-v1');

ALTER TABLE ecs_receipts ADD COLUMN authority_id TEXT;
ALTER TABLE ecs_receipts ADD COLUMN verifier_contract TEXT;
UPDATE ecs_actions
SET state='reconciliation_required', receipt_id=NULL
WHERE state='effect_verified';
UPDATE ecs_receipts
SET verified_at=NULL, verifier=NULL, authority_id=NULL, verifier_contract=NULL;

ALTER TABLE ecs_work_units RENAME TO ecs_work_units_v1;
CREATE TABLE ecs_work_units (
    work_unit_id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL,
    entity_id TEXT NOT NULL REFERENCES ecs_entities(entity_id),
    thread_id TEXT REFERENCES ecs_threads(thread_id),
    authority TEXT NOT NULL,
    external_id TEXT NOT NULL,
    title TEXT NOT NULL,
    owner TEXT,
    status TEXT NOT NULL CHECK (status IN (
        'unknown', 'created', 'assigned', 'started', 'blocked', 'completed', 'cancelled'
    )),
    output_ref TEXT,
    evidence_ref TEXT,
    evidence_observed_at TEXT,
    source_ref TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision > 0),
    UNIQUE(entity_id, authority, external_id)
);
INSERT INTO ecs_work_units SELECT * FROM ecs_work_units_v1;
DROP TABLE ecs_work_units_v1;

ALTER TABLE ecs_checkpoints RENAME TO ecs_checkpoints_v1;
CREATE TABLE ecs_checkpoints (
    checkpoint_id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL,
    entity_id TEXT NOT NULL REFERENCES ecs_entities(entity_id),
    thread_id TEXT NOT NULL REFERENCES ecs_threads(thread_id),
    session_id TEXT,
    input_event_sequence INTEGER NOT NULL,
    compiled_at TEXT NOT NULL,
    budget_chars INTEGER NOT NULL,
    audience TEXT NOT NULL CHECK (audience IN ('rich', 'worker', 'ceo')),
    document_text TEXT NOT NULL,
    digest TEXT NOT NULL,
    source_ref TEXT NOT NULL,
    UNIQUE(entity_id, thread_id, input_event_sequence, budget_chars, audience)
);
DROP TABLE ecs_checkpoints_v1;
