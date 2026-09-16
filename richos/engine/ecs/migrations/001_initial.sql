CREATE TABLE IF NOT EXISTS ecs_events (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT NOT NULL UNIQUE,
    schema_version INTEGER NOT NULL CHECK (schema_version = 1),
    event_type TEXT NOT NULL,
    occurred_at TEXT NOT NULL,
    person_id TEXT NOT NULL,
    entity_id TEXT,
    thread_id TEXT,
    session_id TEXT,
    actor_kind TEXT NOT NULL,
    actor_id TEXT NOT NULL,
    source_ref TEXT NOT NULL,
    idempotency_key TEXT NOT NULL UNIQUE,
    expected_revision INTEGER,
    payload_json TEXT NOT NULL,
    CHECK (entity_id IS NOT NULL OR person_id <> '')
);

CREATE INDEX IF NOT EXISTS ecs_events_scope_idx
    ON ecs_events(person_id, entity_id, thread_id, sequence);

CREATE TABLE IF NOT EXISTS ecs_entities (
    entity_id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    canonical_root TEXT NOT NULL UNIQUE,
    git_common_dir TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL CHECK (status IN ('active', 'inactive')),
    source_ref TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision > 0)
);

CREATE TABLE IF NOT EXISTS ecs_threads (
    thread_id TEXT PRIMARY KEY,
    entity_id TEXT NOT NULL REFERENCES ecs_entities(entity_id),
    title TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('open', 'closed')),
    created_at TEXT NOT NULL,
    last_activity_at TEXT NOT NULL,
    source_ref TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision > 0)
);

CREATE TABLE IF NOT EXISTS ecs_sessions (
    session_id TEXT PRIMARY KEY,
    entity_id TEXT NOT NULL REFERENCES ecs_entities(entity_id),
    thread_id TEXT NOT NULL REFERENCES ecs_threads(thread_id),
    vendor TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('active', 'stopped', 'unknown')),
    started_at TEXT NOT NULL,
    last_observed_at TEXT NOT NULL,
    source_ref TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision > 0)
);

CREATE TABLE IF NOT EXISTS ecs_active_context (
    person_id TEXT PRIMARY KEY,
    entity_id TEXT NOT NULL REFERENCES ecs_entities(entity_id),
    thread_id TEXT NOT NULL REFERENCES ecs_threads(thread_id),
    session_id TEXT,
    turn_id TEXT,
    audience TEXT NOT NULL CHECK (audience IN ('rich', 'worker', 'ceo')),
    source_ref TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision > 0)
);

CREATE TABLE IF NOT EXISTS ecs_continuity_items (
    item_id TEXT PRIMARY KEY,
    item_type TEXT NOT NULL CHECK (item_type IN (
        'priority', 'initiative', 'open_loop', 'commitment', 'decision',
        'deadline', 'blocker'
    )),
    person_id TEXT NOT NULL,
    entity_id TEXT NOT NULL REFERENCES ecs_entities(entity_id),
    thread_id TEXT REFERENCES ecs_threads(thread_id),
    title TEXT NOT NULL,
    details TEXT NOT NULL,
    owner TEXT,
    beneficiary TEXT,
    next_action TEXT,
    due_at TEXT,
    rank INTEGER,
    status TEXT NOT NULL CHECK (status IN (
        'candidate', 'accepted', 'active', 'blocked', 'completed', 'rejected',
        'cancelled', 'superseded', 'pending'
    )),
    visibility TEXT NOT NULL CHECK (visibility IN ('rich', 'worker', 'ceo_private')),
    source_ref TEXT NOT NULL,
    evidence_ref TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision > 0)
);

CREATE INDEX IF NOT EXISTS ecs_continuity_scope_idx
    ON ecs_continuity_items(entity_id, item_type, status, rank, item_id);

CREATE TABLE IF NOT EXISTS ecs_work_units (
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
    UNIQUE(authority, external_id)
);

CREATE TABLE IF NOT EXISTS ecs_actions (
    action_id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL,
    entity_id TEXT NOT NULL REFERENCES ecs_entities(entity_id),
    thread_id TEXT REFERENCES ecs_threads(thread_id),
    action_type TEXT NOT NULL,
    target_ref TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN (
        'intent', 'attempt_started', 'effect_observed', 'effect_verified',
        'failed', 'reconciliation_required'
    )),
    evidence_ref TEXT,
    receipt_id TEXT,
    source_ref TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision > 0)
);

CREATE TABLE IF NOT EXISTS ecs_receipts (
    receipt_id TEXT PRIMARY KEY,
    action_id TEXT NOT NULL REFERENCES ecs_actions(action_id),
    receipt_type TEXT NOT NULL,
    authority_ref TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    verified_at TEXT,
    verifier TEXT,
    source_ref TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS ecs_corrections (
    correction_id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL,
    entity_id TEXT NOT NULL REFERENCES ecs_entities(entity_id),
    thread_id TEXT REFERENCES ecs_threads(thread_id),
    mode TEXT NOT NULL CHECK (mode IN ('explicit', 'inferred')),
    classification TEXT NOT NULL CHECK (classification IN (
        'architecture', 'hook_test', 'skill_rule', 'wiki_loro', 'ecs', 'principle'
    )),
    destination TEXT,
    content TEXT NOT NULL,
    apply_state TEXT NOT NULL CHECK (apply_state IN (
        'candidate', 'accepted', 'applied', 'verified', 'reported',
        'queued_for_enforcement', 'failed', 'repair_required', 'rejected'
    )),
    report TEXT,
    source_ref TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision > 0)
);

CREATE TABLE IF NOT EXISTS ecs_dependency_health (
    dependency_id TEXT NOT NULL,
    entity_id TEXT NOT NULL REFERENCES ecs_entities(entity_id),
    status TEXT NOT NULL CHECK (status IN ('healthy', 'degraded', 'unknown')),
    detail TEXT NOT NULL,
    checked_at TEXT,
    source_ref TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision > 0),
    PRIMARY KEY(dependency_id, entity_id)
);

CREATE TABLE IF NOT EXISTS ecs_checkpoints (
    checkpoint_id TEXT PRIMARY KEY,
    person_id TEXT NOT NULL,
    entity_id TEXT NOT NULL REFERENCES ecs_entities(entity_id),
    thread_id TEXT NOT NULL REFERENCES ecs_threads(thread_id),
    session_id TEXT,
    input_event_sequence INTEGER NOT NULL,
    compiled_at TEXT NOT NULL,
    budget_chars INTEGER NOT NULL,
    document_text TEXT NOT NULL,
    digest TEXT NOT NULL,
    source_ref TEXT NOT NULL,
    UNIQUE(entity_id, thread_id, input_event_sequence, budget_chars)
);
