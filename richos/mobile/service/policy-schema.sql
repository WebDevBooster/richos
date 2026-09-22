-- Hosted RichOS update policy (D1 database richos-update-policy).
-- Append-only: every publication, withdrawal and rollback is a new, higher revision row that
-- carries its operator audit record. The Worker only reads; the operator CLI only inserts.
CREATE TABLE IF NOT EXISTS revisions (
  revision INTEGER PRIMARY KEY CHECK (revision > 0),
  policy TEXT NOT NULL CHECK (json_valid(policy)),
  digest TEXT NOT NULL CHECK (length(digest) = 64),
  audit TEXT NOT NULL CHECK (json_valid(audit)),
  published_at TEXT NOT NULL
) STRICT;
CREATE TRIGGER IF NOT EXISTS revisions_no_update BEFORE UPDATE ON revisions
BEGIN SELECT RAISE(ABORT, 'revisions are append-only'); END;
CREATE TRIGGER IF NOT EXISTS revisions_no_delete BEFORE DELETE ON revisions
BEGIN SELECT RAISE(ABORT, 'revisions are append-only'); END;
