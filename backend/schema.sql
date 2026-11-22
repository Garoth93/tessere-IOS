-- Tessere D1 schema (idempotent).
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  space_id TEXT,
  created_at INTEGER NOT NULL,
  last_seen INTEGER
);
CREATE TABLE IF NOT EXISTS spaces (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  owner_device_id TEXT NOT NULL,
  seq INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS invites (
  code TEXT PRIMARY KEY,
  space_id TEXT NOT NULL,
  created_by TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  used_by TEXT,
  used_at INTEGER
);
-- One row per card; payload is end-to-end encrypted by the app.
CREATE TABLE IF NOT EXISTS records (
  space_id TEXT NOT NULL,
  id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  payload TEXT,
  device_id TEXT,
  PRIMARY KEY (space_id, id)
);
CREATE INDEX IF NOT EXISTS records_by_seq ON records (space_id, seq);
CREATE INDEX IF NOT EXISTS devices_by_space ON devices (space_id);
