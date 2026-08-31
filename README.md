# pi-sandbox

A minimal, reproducible Podman setup for running the [pi coding harness](https://github.com/earendil-works/pi)
against a remote/self-hosted LLM server, with filesystem access locked to
this project folder.

## Platform support

- **Linux** — native, no extra steps.
- **macOS** — native; `run.sh` is a bash script, which macOS ships with.
- **Windows** — run everything **inside WSL2**, not from PowerShell/cmd.exe
  (`run.sh` won't run there). Install Podman directly inside your WSL2
  distro (`sudo apt install podman` in Ubuntu, etc.) rather than using
  Podman Desktop's separately-managed VM — that way it behaves exactly like
  native Linux, and `./run.sh` needs no Windows-specific handling. The one
  common WSL2 gotcha: rootless Podman needs systemd enabled for the distro.
  If `podman info` fails, `run.sh` will tell you to add `systemd=true`
  under `[boot]` in `/etc/wsl.conf` and run `wsl --shutdown` from Windows to
  restart it.

## Setup

1. Copy this whole `pi-sandbox` folder as a **subfolder inside your actual
   project**, e.g.:
   ```
   my-actual-project/
   ├── main.py
   ├── src/
   └── pi-sandbox/       <- this project, copied in here
   ```
2. Install Podman -> [link to podman manual](https://github.com/earendil-works/pi)
3. Run:
   ```bash
   ./run.sh
   ```

   If Podman isn't reachable, `run.sh` handles it: on macOS it runs
   `podman machine init`/`start` for you (one-time VM setup); on Linux it
   just points you at `podman system connection list` and exits.

   The first time, if no `.env` exists yet, `run.sh` also asks for your
   model server's URL, an optional API key/password, model id, context
   window, and max output tokens — and writes them to a gitignored `.env`
   in `pi-sandbox/`. On every later run, since `.env` already exists, none
   of this is asked again; delete `pi-sandbox/.env` and re-run to change
   any of it.

   `run.sh` then builds the image (first run only, or whenever
   `Containerfile` changes) and drops you into pi's interactive prompt,
   already pointed at your server as the default provider *and* model — no
   `--provider`/`--model` flags or `/model` picking needed.

   It mounts **the parent folder** of `pi-sandbox/` (i.e.
   `my-actual-project/`) as `/workspace` — so pi can see and edit your real
   project files *and* the `pi-sandbox/` tooling folder itself. Before pi
   starts, the container prints exactly what it can see under `/workspace`
   — that's your proof of what's exposed.

   To skip the rebuild step on later runs: `./run.sh --no-build`

## What's sandboxed

- Only the parent of this folder (your actual project, including this
  `pi-sandbox/` subfolder) is mounted into the container. pi cannot see or
  touch anything else on the host filesystem — not the rest of your
  filesystem, not sibling project folders.
- The container's own root filesystem is read-only (`--read-only` + `--tmpfs /tmp`).
- All Linux capabilities are dropped (`--cap-drop=ALL`).
- Runs as your own UID via `--userns=keep-id`, so files created in the project
  folder are owned by you, not root.
- Networking uses Podman's default rootless network — outbound connections
  (to your model server and the internet) work normally; no inbound access
  to the container is exposed.

## Files

- `Containerfile` — defines the image: `node:22-slim` (pi's latest release
  needs Node ≥22.19; older Node silently installs a legacy build) with
  `@earendil-works/pi-coding-agent` installed globally, running as the
  base image's built-in non-root `node` user. No addresses or secrets
  baked in, so it's safe to share as-is.
- `.env` — holds every user-specific setting (server URL, key, model id,
  context window, max tokens); created interactively by `run.sh` on first
  run only. Gitignored, never committed.
- `run.sh` — checks Podman is reachable (starting it on macOS if not, or
  pointing out the systemd-in-WSL2 fix on Windows), prompts for all `.env`
  values only when `.env` doesn't exist yet, then builds (optionally) and
  launches the sandboxed container, mounting its parent folder as
  `/workspace` and passing the `.env` values in as environment variables.
- `entrypoint.sh` — runs inside the container before pi starts. Generates
  pi's [`models.json`/`settings.json`](https://pi.dev/docs/latest/models)
  from those env vars into `/tmp/pi-agent` (tmpfs — writable, wiped on
  exit, never touches the repo), registering your server as a provider
  named `sandbox` and setting it — and your configured model — as pi's
  default. Then it prints the full contents of `/workspace` as proof of
  exactly what's exposed, and hands off to `pi`.

## Sharing this project

Commit everything except `.env` (already gitignored). Anyone who clones the
repo just needs to run `./run.sh` and answer the prompts for their own
server on first run.
