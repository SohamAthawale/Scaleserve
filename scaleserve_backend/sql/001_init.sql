CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS app_users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username TEXT NOT NULL UNIQUE,
  email TEXT,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'operator',
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  mfa_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_login_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS auth_otp_challenges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  purpose TEXT NOT NULL,
  otp_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  max_attempts INTEGER NOT NULL DEFAULT 5,
  consumed_at TIMESTAMPTZ,
  CONSTRAINT chk_auth_otp_purpose CHECK (purpose IN ('login_mfa', 'password_reset'))
);

CREATE INDEX IF NOT EXISTS idx_auth_otp_active
ON auth_otp_challenges (user_id, purpose, created_at DESC)
WHERE consumed_at IS NULL;

-- App-level key/value settings persisted by the operator app/backend.
CREATE TABLE IF NOT EXISTS app_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Discovered Tailscale machines and their latest observed state.
CREATE TABLE IF NOT EXISTS machine_inventory (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dns_name TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  ip_address TEXT NOT NULL,
  operating_system TEXT NOT NULL,
  is_online BOOLEAN NOT NULL DEFAULT FALSE,
  is_self BOOLEAN NOT NULL DEFAULT FALSE,
  tailnet_name TEXT,
  login_name TEXT,
  backend_state TEXT,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata_json JSONB,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_machine_inventory_online
ON machine_inventory (is_online);

CREATE INDEX IF NOT EXISTS idx_machine_inventory_seen
ON machine_inventory (last_seen_at DESC);

-- Latest remote execution connection profile per target machine.
CREATE TABLE IF NOT EXISTS remote_device_profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dns_name TEXT NOT NULL UNIQUE,
  remote_user TEXT NOT NULL,
  key_path TEXT NOT NULL,
  bootstrap_key_path TEXT NOT NULL,
  default_command TEXT NOT NULL,
  owner_user_id UUID REFERENCES app_users(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_remote_device_profiles_owner
ON remote_device_profiles (owner_user_id);

-- Detailed remote run history.
CREATE TABLE IF NOT EXISTS remote_run_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  started_at TIMESTAMPTZ NOT NULL,
  finished_at TIMESTAMPTZ,
  device_dns_name TEXT NOT NULL,
  remote_user TEXT NOT NULL,
  command TEXT NOT NULL,
  safe_command_text TEXT,
  event_hash TEXT,
  exit_code INTEGER NOT NULL,
  success BOOLEAN NOT NULL,
  run_type TEXT NOT NULL DEFAULT 'remote_command',
  local_file_path TEXT,
  stdout TEXT,
  stderr TEXT,
  metadata_json JSONB,
  initiated_by_user_id UUID REFERENCES app_users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_remote_run_type CHECK (
    run_type IN ('remote_command', 'stream_file', 'stream_script', 'ssh_setup', 'diagnostic', 'other')
  )
);

CREATE INDEX IF NOT EXISTS idx_remote_run_logs_started
ON remote_run_logs (started_at DESC);

CREATE INDEX IF NOT EXISTS idx_remote_run_logs_device
ON remote_run_logs (device_dns_name);

CREATE INDEX IF NOT EXISTS idx_remote_run_logs_user
ON remote_run_logs (initiated_by_user_id, started_at DESC);

-- Local/remote shell command execution logs.
CREATE TABLE IF NOT EXISTS command_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  command_text TEXT NOT NULL,
  safe_command_text TEXT NOT NULL,
  event_hash TEXT,
  exit_code INTEGER NOT NULL,
  success BOOLEAN NOT NULL,
  stdout TEXT NOT NULL,
  stderr TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'app',
  initiated_by_user_id UUID REFERENCES app_users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_command_logs_created
ON command_logs (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_command_logs_user
ON command_logs (initiated_by_user_id, created_at DESC);

-- Optional authentication and security audit trail.
CREATE TABLE IF NOT EXISTS auth_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES app_users(id) ON DELETE SET NULL,
  username TEXT,
  event_type TEXT NOT NULL,
  status TEXT NOT NULL,
  ip_address INET,
  user_agent TEXT,
  details_json JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_auth_event_type CHECK (
    event_type IN (
      'bootstrap',
      'login',
      'login_mfa_request',
      'login_mfa_verify',
      'forgot_password_request',
      'forgot_password_reset'
    )
  ),
  CONSTRAINT chk_auth_event_status CHECK (status IN ('success', 'failure'))
);

CREATE INDEX IF NOT EXISTS idx_auth_events_created
ON auth_events (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_auth_events_user
ON auth_events (user_id, created_at DESC);

-- Optional raw tailscale snapshots for full-fidelity forensic history.
CREATE TABLE IF NOT EXISTS tailscale_snapshot_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  captured_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  source_machine_dns_name TEXT,
  snapshot_json JSONB NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tailscale_snapshot_logs_captured
ON tailscale_snapshot_logs (captured_at DESC);

-- Compatibility updates for existing databases.
ALTER TABLE IF EXISTS remote_run_logs
  ADD COLUMN IF NOT EXISTS event_hash TEXT;

ALTER TABLE IF EXISTS command_logs
  ADD COLUMN IF NOT EXISTS event_hash TEXT;

ALTER TABLE IF EXISTS remote_run_logs
  DROP CONSTRAINT IF EXISTS chk_remote_run_type;

ALTER TABLE IF EXISTS remote_run_logs
  ADD CONSTRAINT chk_remote_run_type CHECK (
    run_type IN ('remote_command', 'stream_file', 'stream_script', 'ssh_setup', 'diagnostic', 'other')
  );

DROP INDEX IF EXISTS idx_remote_run_logs_event_hash;
CREATE UNIQUE INDEX IF NOT EXISTS idx_remote_run_logs_event_hash
ON remote_run_logs (event_hash);

DROP INDEX IF EXISTS idx_command_logs_event_hash;
CREATE UNIQUE INDEX IF NOT EXISTS idx_command_logs_event_hash
ON command_logs (event_hash);
