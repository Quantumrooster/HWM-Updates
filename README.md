# Headline Workstation Monitor Update Feed

Public HTTPS update feed for Headline Workstation Monitor managed clients.

This repository contains **compiled update payloads and manifests only**. The HWM source code remains private in `Quantumrooster/HWM`.

## Channels

- `feed/dev/` — Headline development ring
- `feed/pilot/` — selected pilot workstations
- `feed/stable/` — production fleet

Each channel exposes a manifest (`dev.json`, `pilot.json`, or `stable.json`) and the exact release payload referenced by that manifest.

## Safety

HWM clients verify the manifest target, package size and SHA256 hash before installation. The managed updater backs up the installed version, stops the HWM service, waits for the executable to unlock, installs the payload, requires a fresh health heartbeat, and rolls back automatically if verification fails.

No HWM source code, GitHub credentials, client secrets or tenant credentials belong in this repository.
