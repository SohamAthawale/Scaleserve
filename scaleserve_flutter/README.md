# ScaleServe Flutter

Cross-platform Flutter desktop app to control Tailscale on macOS and Windows.

## Full Manual

- [ScaleServe Manual](docs/SCALESERVE_MANUAL.md)

## Features

- View live Tailscale state (`tailscale status --json`)
- Toggle on and off (`tailscale up` / `tailscale down`)
- Start new connections with optional auth key (`tailscale up --auth-key ...`)
- One-click setup for a new laptop (`tailscale up --reset --ssh --auth-key ...`)
- View connected peer devices from status output
- Generate onboarding commands for macOS/Windows/Linux devices
- Run remote SSH commands on selected tailnet devices with saved profiles
- Generate SSH keypair, copy target-OS SSH bootstrap command, and auto-detect working SSH user
- Install your ScaleServe SSH public key on a remote target directly from the app using an existing bootstrap key
- Stream local files over SSH stdin into Python, shell, Node.js, PowerShell, Ruby, Perl, or any custom stdin-reading command without permanent upload
- Built-in command presets for GPU checks, PyTorch/CUDA visibility, Ollama, OpenAI API calls, and local OpenAI-compatible endpoints
- Optional targeted auto-cleanup for Windows stream runs (kills only matching `python.exe`/`py.exe` command lines)
- Stop an in-progress remote SSH run directly from the app
- Track remote command history in-app
- Backend API + PostgreSQL login with first-user bootstrap
- Forgot-password OTP reset and login MFA OTP (delivered by backend Gmail SMTP)
- Runtime sync to backend PostgreSQL for settings, machine inventory, remote profiles, run logs, and command logs
- Lightweight local JSON cache for offline resilience (no local database engine)

## Requirements

- Flutter 3.x+
- Tailscale installed on the same machine as the app
- `tailscale` CLI available from PATH (or default install path)
- ScaleServe backend running (`../scaleserve_backend`) with PostgreSQL

## Run

```bash
# terminal 1
cd ../scaleserve_backend
cp .env.example .env
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn src.main:app --host 0.0.0.0 --port 8080

# terminal 2
cd scaleserve_flutter
flutter run -d macos
```

For Windows:

```bash
# terminal 1
cd ..\scaleserve_backend
copy .env.example .env
py -m venv .venv
.\.venv\Scripts\activate
pip install -r requirements.txt
uvicorn src.main:app --host 0.0.0.0 --port 8080

# terminal 2
cd ..\scaleserve_flutter
flutter run -d windows
```

## Notes

- If auth key is blank, the app runs regular `tailscale up` and Tailscale may open browser login.
- On first run, make sure you can run `tailscale status` in your terminal successfully.
- For remote command execution, target machines must have your public key in their OpenSSH `authorized_keys` file.
- On Windows targets, SSH key setup also depends on OpenSSH ACLs and often `administrators_authorized_keys`; the app now handles these in its generated setup command.
- Authentication and runtime data are validated/persisted by backend PostgreSQL.
- Optional local cache files are stored in project-local:
  - `<repo>/scaleserve_runtime/`
