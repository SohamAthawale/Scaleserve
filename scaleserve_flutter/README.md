# ScaleServe Flutter

Cross-platform Flutter desktop app to control Tailscale on macOS and Windows.

## Features

- View live Tailscale state (`tailscale status --json`)
- Toggle on and off (`tailscale up` / `tailscale down`)
- Start new connections with optional auth key (`tailscale up --auth-key ...`)
- View connected peer devices from status output

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
