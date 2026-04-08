-- Workspace / multi-tenant model.
--
-- NOTE:
-- - Uses a stable default workspace id for deterministic migration.
-- - Scopes runtime data to workspace_id.
-- - Keeps legacy app_settings table untouched, and introduces workspace_settings.

CREATE TABLE IF NOT EXISTS workspaces (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT,
  is_system BOOLEAN NOT NULL DEFAULT FALSE,
  created_by_user_id UUID REFERENCES app_users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO workspaces (
  id, slug, name, description, is_system, created_at, updated_at
)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  'default',
  'Default Workspace',
  'System default workspace',
  TRUE,
  NOW(),
  NOW()
)
ON CONFLICT (id) DO UPDATE SET
  slug = EXCLUDED.slug,
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  updated_at = NOW();

CREATE TABLE IF NOT EXISTS workspace_users (
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'member',
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  invited_by_user_id UUID REFERENCES app_users(id) ON DELETE SET NULL,
  PRIMARY KEY (workspace_id, user_id),
  CONSTRAINT chk_workspace_user_role CHECK (
    role IN ('owner', 'admin', 'member', 'viewer')
  )
);

CREATE INDEX IF NOT EXISTS idx_workspace_users_user
ON workspace_users (user_id, workspace_id);

ALTER TABLE app_users
  ADD COLUMN IF NOT EXISTS active_workspace_id UUID;

UPDATE app_users
SET active_workspace_id = '00000000-0000-0000-0000-000000000001'
WHERE active_workspace_id IS NULL;

ALTER TABLE app_users
  ALTER COLUMN active_workspace_id SET DEFAULT '00000000-0000-0000-0000-000000000001';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fk_app_users_active_workspace'
  ) THEN
    ALTER TABLE app_users
      ADD CONSTRAINT fk_app_users_active_workspace
      FOREIGN KEY (active_workspace_id)
      REFERENCES workspaces(id)
      ON DELETE SET NULL;
  END IF;
END $$;

INSERT INTO workspace_users (
  workspace_id,
  user_id,
  role,
  is_active,
  joined_at
)
SELECT
  '00000000-0000-0000-0000-000000000001',
  u.id,
  CASE WHEN u.role = 'admin' THEN 'owner' ELSE 'member' END,
  TRUE,
  COALESCE(u.created_at, NOW())
FROM app_users u
ON CONFLICT (workspace_id, user_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS workspace_settings (
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (workspace_id, key)
);

INSERT INTO workspace_settings (workspace_id, key, value, updated_at)
SELECT
  '00000000-0000-0000-0000-000000000001',
  a.key,
  a.value,
  a.updated_at
FROM app_settings a
ON CONFLICT (workspace_id, key) DO UPDATE SET
  value = EXCLUDED.value,
  updated_at = EXCLUDED.updated_at;

ALTER TABLE machine_inventory
  ADD COLUMN IF NOT EXISTS workspace_id UUID;

UPDATE machine_inventory
SET workspace_id = '00000000-0000-0000-0000-000000000001'
WHERE workspace_id IS NULL;

ALTER TABLE machine_inventory
  ALTER COLUMN workspace_id SET NOT NULL;

ALTER TABLE machine_inventory
  ALTER COLUMN workspace_id SET DEFAULT '00000000-0000-0000-0000-000000000001';

ALTER TABLE machine_inventory
  DROP CONSTRAINT IF EXISTS machine_inventory_dns_name_key;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fk_machine_inventory_workspace'
  ) THEN
    ALTER TABLE machine_inventory
      ADD CONSTRAINT fk_machine_inventory_workspace
      FOREIGN KEY (workspace_id)
      REFERENCES workspaces(id)
      ON DELETE CASCADE;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_machine_inventory_workspace_seen
ON machine_inventory (workspace_id, last_seen_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS ux_machine_inventory_workspace_dns
ON machine_inventory (workspace_id, dns_name);

ALTER TABLE remote_device_profiles
  ADD COLUMN IF NOT EXISTS workspace_id UUID;

UPDATE remote_device_profiles
SET workspace_id = '00000000-0000-0000-0000-000000000001'
WHERE workspace_id IS NULL;

ALTER TABLE remote_device_profiles
  ALTER COLUMN workspace_id SET NOT NULL;

ALTER TABLE remote_device_profiles
  ALTER COLUMN workspace_id SET DEFAULT '00000000-0000-0000-0000-000000000001';

ALTER TABLE remote_device_profiles
  DROP CONSTRAINT IF EXISTS remote_device_profiles_dns_name_key;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fk_remote_device_profiles_workspace'
  ) THEN
    ALTER TABLE remote_device_profiles
      ADD CONSTRAINT fk_remote_device_profiles_workspace
      FOREIGN KEY (workspace_id)
      REFERENCES workspaces(id)
      ON DELETE CASCADE;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS ux_remote_profiles_workspace_dns
ON remote_device_profiles (workspace_id, dns_name);

ALTER TABLE remote_run_logs
  ADD COLUMN IF NOT EXISTS workspace_id UUID;

UPDATE remote_run_logs
SET workspace_id = '00000000-0000-0000-0000-000000000001'
WHERE workspace_id IS NULL;

ALTER TABLE remote_run_logs
  ALTER COLUMN workspace_id SET NOT NULL;

ALTER TABLE remote_run_logs
  ALTER COLUMN workspace_id SET DEFAULT '00000000-0000-0000-0000-000000000001';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fk_remote_run_logs_workspace'
  ) THEN
    ALTER TABLE remote_run_logs
      ADD CONSTRAINT fk_remote_run_logs_workspace
      FOREIGN KEY (workspace_id)
      REFERENCES workspaces(id)
      ON DELETE CASCADE;
  END IF;
END $$;

DROP INDEX IF EXISTS idx_remote_run_logs_event_hash;
CREATE UNIQUE INDEX IF NOT EXISTS idx_remote_run_logs_workspace_event_hash
ON remote_run_logs (workspace_id, event_hash);

CREATE INDEX IF NOT EXISTS idx_remote_run_logs_workspace_started
ON remote_run_logs (workspace_id, started_at DESC);

ALTER TABLE command_logs
  ADD COLUMN IF NOT EXISTS workspace_id UUID;

UPDATE command_logs
SET workspace_id = '00000000-0000-0000-0000-000000000001'
WHERE workspace_id IS NULL;

ALTER TABLE command_logs
  ALTER COLUMN workspace_id SET NOT NULL;

ALTER TABLE command_logs
  ALTER COLUMN workspace_id SET DEFAULT '00000000-0000-0000-0000-000000000001';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fk_command_logs_workspace'
  ) THEN
    ALTER TABLE command_logs
      ADD CONSTRAINT fk_command_logs_workspace
      FOREIGN KEY (workspace_id)
      REFERENCES workspaces(id)
      ON DELETE CASCADE;
  END IF;
END $$;

DROP INDEX IF EXISTS idx_command_logs_event_hash;
CREATE UNIQUE INDEX IF NOT EXISTS idx_command_logs_workspace_event_hash
ON command_logs (workspace_id, event_hash);

CREATE INDEX IF NOT EXISTS idx_command_logs_workspace_created
ON command_logs (workspace_id, created_at DESC);

ALTER TABLE tailscale_snapshot_logs
  ADD COLUMN IF NOT EXISTS workspace_id UUID;

UPDATE tailscale_snapshot_logs
SET workspace_id = '00000000-0000-0000-0000-000000000001'
WHERE workspace_id IS NULL;

ALTER TABLE tailscale_snapshot_logs
  ALTER COLUMN workspace_id SET NOT NULL;

ALTER TABLE tailscale_snapshot_logs
  ALTER COLUMN workspace_id SET DEFAULT '00000000-0000-0000-0000-000000000001';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fk_tailscale_snapshot_logs_workspace'
  ) THEN
    ALTER TABLE tailscale_snapshot_logs
      ADD CONSTRAINT fk_tailscale_snapshot_logs_workspace
      FOREIGN KEY (workspace_id)
      REFERENCES workspaces(id)
      ON DELETE CASCADE;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_tailscale_snapshots_workspace_captured
ON tailscale_snapshot_logs (workspace_id, captured_at DESC);

ALTER TABLE auth_events
  ADD COLUMN IF NOT EXISTS workspace_id UUID;

UPDATE auth_events
SET workspace_id = '00000000-0000-0000-0000-000000000001'
WHERE workspace_id IS NULL;

ALTER TABLE auth_events
  ALTER COLUMN workspace_id SET NOT NULL;

ALTER TABLE auth_events
  ALTER COLUMN workspace_id SET DEFAULT '00000000-0000-0000-0000-000000000001';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fk_auth_events_workspace'
  ) THEN
    ALTER TABLE auth_events
      ADD CONSTRAINT fk_auth_events_workspace
      FOREIGN KEY (workspace_id)
      REFERENCES workspaces(id)
      ON DELETE CASCADE;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_auth_events_workspace_created
ON auth_events (workspace_id, created_at DESC);
