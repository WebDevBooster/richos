DELETE FROM ecs_checkpoints;

UPDATE ecs_actions
SET state='reconciliation_required', receipt_id=NULL
WHERE state='effect_verified';

UPDATE ecs_receipts
SET verified_at=NULL, verifier=NULL, authority_id=NULL, verifier_contract=NULL;

UPDATE ecs_trusted_authorities SET enabled=0;
