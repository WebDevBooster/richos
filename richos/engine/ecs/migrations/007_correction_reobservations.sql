ALTER TABLE ecs_corrections ADD COLUMN reobserved_count INTEGER NOT NULL DEFAULT 0
    CHECK (reobserved_count >= 0);
ALTER TABLE ecs_corrections ADD COLUMN last_observed_turn TEXT;
