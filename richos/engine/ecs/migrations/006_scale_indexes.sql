
CREATE INDEX IF NOT EXISTS ecs_events_entity_thread_idx
    ON ecs_events(entity_id, thread_id, event_type, sequence);

CREATE INDEX IF NOT EXISTS ecs_events_session_idx
    ON ecs_events(session_id, sequence);

CREATE INDEX IF NOT EXISTS ecs_work_units_scope_idx
    ON ecs_work_units(entity_id, thread_id, status);

CREATE INDEX IF NOT EXISTS ecs_actions_scope_idx
    ON ecs_actions(entity_id, thread_id, state);
