ALTER TABLE ecs_events ADD COLUMN authority_verification_json TEXT;

UPDATE ecs_actions
SET state='reconciliation_required', receipt_id=NULL
WHERE state='effect_verified';

UPDATE ecs_receipts
SET verified_at=NULL, verifier=NULL, authority_id=NULL, verifier_contract=NULL;

UPDATE ecs_sessions
SET status=COALESCE((
    SELECT json_extract(e.payload_json, '$.status')
    FROM ecs_events e
    WHERE e.event_type='session.observed'
      AND e.session_id=ecs_sessions.session_id
      AND e.source_ref NOT LIKE 'claude-hook:TaskCompleted:%'
      AND e.source_ref NOT LIKE 'claude-hook:TeammateIdle:%'
    ORDER BY e.sequence DESC
    LIMIT 1
), 'unknown'),
last_observed_at=COALESCE((
    SELECT e.occurred_at
    FROM ecs_events e
    WHERE e.event_type='session.observed'
      AND e.session_id=ecs_sessions.session_id
      AND e.source_ref NOT LIKE 'claude-hook:TaskCompleted:%'
      AND e.source_ref NOT LIKE 'claude-hook:TeammateIdle:%'
    ORDER BY e.sequence DESC
    LIMIT 1
), last_observed_at),
source_ref=COALESCE((
    SELECT e.source_ref
    FROM ecs_events e
    WHERE e.event_type='session.observed'
      AND e.session_id=ecs_sessions.session_id
      AND e.source_ref NOT LIKE 'claude-hook:TaskCompleted:%'
      AND e.source_ref NOT LIKE 'claude-hook:TeammateIdle:%'
    ORDER BY e.sequence DESC
    LIMIT 1
), source_ref),
revision=CASE WHEN (
    SELECT COUNT(*)
    FROM ecs_events e
    WHERE e.event_type='session.observed'
      AND e.session_id=ecs_sessions.session_id
      AND e.source_ref NOT LIKE 'claude-hook:TaskCompleted:%'
      AND e.source_ref NOT LIKE 'claude-hook:TeammateIdle:%'
) > 0 THEN (
    SELECT COUNT(*)
    FROM ecs_events e
    WHERE e.event_type='session.observed'
      AND e.session_id=ecs_sessions.session_id
      AND e.source_ref NOT LIKE 'claude-hook:TaskCompleted:%'
      AND e.source_ref NOT LIKE 'claude-hook:TeammateIdle:%'
) ELSE revision END;
