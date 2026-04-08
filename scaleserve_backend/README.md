# ScaleServe Backend (PostgreSQL + Auth API)

This service provides:

- User bootstrap and Gmail-based sign-in
- MFA OTP over Gmail SMTP
- Forgot-password OTP reset
- JWT issue for authenticated sessions
- PostgreSQL-backed credential + OTP challenge storage

## 1) Setup

```bash
cd scaleserve_backend
cp .env.example .env
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Update `.env` with:

- `DATABASE_URL`
- `JWT_SECRET`
- `SMTP_GMAIL_USER`
- `SMTP_GMAIL_APP_PASSWORD`

## 2) Run

```bash
source .venv/bin/activate
uvicorn src.main:app --host 0.0.0.0 --port 8080
```

Default API URL: `http://localhost:8080`

## 3) Database Schema

Schema file:

- `sql/001_init.sql`

Tables:

- `workspaces`
- `workspace_users`
- `workspace_settings`
- `app_users`
- `auth_otp_challenges`
- `app_settings`
- `machine_inventory`
- `remote_device_profiles`
- `remote_run_logs`
- `command_logs`
- `auth_events`
- `tailscale_snapshot_logs`

`AUTO_MIGRATE=true` applies all SQL migrations from `sql/*.sql` automatically on startup.

## 4) API Endpoints

- `GET /health`
- `GET /auth/status`
- `POST /auth/bootstrap`
- `POST /auth/login`
- `POST /auth/login/mfa/request`
- `POST /auth/login/mfa/verify`
- `POST /auth/forgot-password/request`
- `POST /auth/forgot-password/reset`
- `POST /sync/settings`
- `POST /sync/machine-snapshot`
- `POST /sync/command-log`
- `POST /sync/remote-state`

Auth payload keys are email-based:

- `/auth/bootstrap`: `email`, `password`, `mfaEnabled` (optional `username` alias)
- `/auth/login`: `email`, `password`
- MFA / forgot-password routes: `email`, `otp` (where applicable)

## 5) Clear Existing DB Data (Keep Schema)

If you want a clean start (remove old users/machines/logs but keep tables), run:

```sql
TRUNCATE TABLE
  auth_otp_challenges,
  workspace_users,
  workspace_settings,
  remote_run_logs,
  command_logs,
  remote_device_profiles,
  machine_inventory,
  tailscale_snapshot_logs,
  auth_events,
  app_settings,
  app_users,
  workspaces
RESTART IDENTITY CASCADE;
```

Then reinsert the default workspace row:

```sql
INSERT INTO workspaces (id, slug, name, description, is_system, created_at, updated_at)
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
```
