# ScaleServe Flutter

Cross-platform Flutter desktop app to control Tailscale on macOS and Windows.

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
- Stream a local file over SSH stdin and execute it on remote compute without permanent upload
- Optional targeted auto-cleanup for Windows stream runs (kills only matching `python.exe`/`py.exe` command lines)
- Stop an in-progress remote SSH run directly from the app
- Track remote command history in-app

## Requirements

- Flutter 3.x+
- Tailscale installed on the same machine as the app
- `tailscale` CLI available from PATH (or default install path)

## Run

```bash
cd scaleserve_flutter
flutter run -d macos
```

For Windows:

```bash
cd scaleserve_flutter
flutter run -d windows
```

## Notes

- If auth key is blank, the app runs regular `tailscale up` and Tailscale may open browser login.
- On first run, make sure you can run `tailscale status` in your terminal successfully.
- For remote command execution, target machines must have your public key in their OpenSSH `authorized_keys` file.
- On Windows targets, SSH key setup also depends on OpenSSH ACLs and often `administrators_authorized_keys`; the app now handles these in its generated setup command.
