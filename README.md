# pi-sandbox

A minimal, reproducible Podman setup for running the
[pi coding harness](https://github.com/earendil-works/pi) against a
remote/self-hosted LLM server, with filesystem access locked to this project
folder.

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
2. Install Podman -> [podman installation](https://podman.io/docs/installation)
3. Run:
   ```bash
   ./run.sh
   ```

   If Podman isn't reachable, `run.sh` handles it: on macOS it runs
   `podman machine init`/`start` for you (one-time VM setup); on Linux it
   just points you at `podman system connection list` and exits.

   The first time, `run.sh` asks for your model server's URL, an optional API
   key/password, model id, context window, max output tokens, and any MCP
   servers you want (see [MCP servers](#mcp-servers)), then writes them to the
   system-wide `~/.config/pi-sandbox/defaults.env`. Later runs — and later
   projects — read that file and ask nothing. It then builds the image (first
   run only, or whenever `Containerfile` changes) and drops you into pi's
   interactive prompt, already pointed at your server as the default provider
   *and* model — no `--provider`/`--model` flags or `/model` picking needed.

   It mounts **the parent folder** of `pi-sandbox/` (i.e.
   `my-actual-project/`) as `/workspace` — so pi can see and edit your real
   project files *and* the `pi-sandbox/` tooling folder itself. Before pi
   starts, the container prints exactly what it can see under `/workspace` —
   that's your proof of what's exposed.

## Commands

| Command | What it does |
|---|---|
| `./run.sh` | build if needed, then start pi interactively |
| `./run.sh --no-build` | skip the build step |
| `./run.sh --edit-defaults` | edit the **system-wide** config in `$EDITOR` (falls back to `nano`) |
| `./run.sh --edit-config` | edit **this project's** overrides in `$EDITOR` |
| `./run.sh --hindsight start\|stop\|status` | manage the optional memory server without starting pi |
| `./run.sh --help` | flags plus the resolved paths of both config files |
| `./run.sh --no-build -p "summarize the project"` | anything not recognised above goes straight to pi, e.g. print mode |

## Where your settings live

Two config files, both **outside the project**, sourced in this order:

```
~/.config/pi-sandbox/defaults.env           # system-wide: every project uses it
~/.config/pi-sandbox/<project-name>/.env    # optional overrides for one project
```

The system-wide file is what the first run asks for, so you fill in the server
URL and key **once per machine**; every other project you drop a `pi-sandbox/`
into just works and asks nothing. A project that needs a different server, key
or model gets its own file: `./run.sh --edit-config` creates one with commented
examples if it doesn't exist yet, and you uncomment only what differs. `run.sh`
prints which files it read on every start.

Keeping both outside the project means the agent can neither read nor rewrite
its own credentials and provider config, and `git add .` can never commit a
secret. `PI_SANDBOX_ENV=/path/to/file` replaces the per-project layer (CI, or
two projects sharing a folder name); `PI_SANDBOX_CONFIG_ROOT` moves the whole
tree. Delete `defaults.env` to answer the prompts again.

Two projects with the *same folder name* also stay apart without any extra
setup: the first `--edit-config` records the project's full path next to its
`.env`, and a run from a different folder with the same name automatically
uses `~/.config/pi-sandbox/<project-name>-<hash>/` instead, so the two never
share (or overwrite) one config.

One quirk of flat `PI_MCP_<n>_*` variables: an override replaces the slot it
names, not the whole list. Setting `PI_MCP_1_COMMAND` in a project file changes
server #1 and keeps its name and everything from `defaults.env`; to define a
completely different set, override all of that project's `PI_MCP_*` slots.

**`pi-sandbox/data/`** (gitignored) — everything pi generates: its config dir
(`settings.json`, `models.json`, `mcp.json`, saved trust decision), session
history, and `data/home` with the npm and uv caches. Keeping this inside the
project is what makes `pi --continue`, `/tree` and a one-time `/trust` work
across runs, and stops `npx` from re-downloading your MCP servers on every
start. Unlike the config file, this folder *is* inside `/workspace`: pi can
read and edit its own config and sessions here. On each start `entrypoint.sh`
rewrites only the parts `.env` defines — your own edits to those files, and
servers you added with `pi mcp add`, survive.

### Model knobs

Next to `PI_MODEL_ID`, all optional:

| Variable | Effect |
|---|---|
| `PI_MODEL_INPUT` | `text` (default) or `text image`. pi only sends images to a model whose entry says it takes them, so a vision server needs this. |
| `PI_MODEL_REASONING` | `1` marks the model reasoning-capable, which is what makes `/thinking` levels appear. Only set it if your server accepts the extra request field. |
| `PI_EXTRA_MODELS` | more model ids served by the same URL, space- or comma-separated; they inherit the context/max-output values. |

Only the models named in the config file are regenerated on each start. A model
you add by hand to `data/agent/models.json` (per-model `samplingParams`,
`promptCache`, …) is left alone, so `/model` can offer things `.env` doesn't
know about.

## MCP servers

pi has a built-in MCP client, so no adapter package is installed and nothing
is fetched at startup. Everything lives in the config file as flat vars:

```
PI_MCP_1_NAME="localsrv"
PI_MCP_1_COMMAND="npx"
PI_MCP_1_ARGS="-y @scope/local-mcp"
PI_MCP_2_NAME="remotesrv"
PI_MCP_2_URL="http://mcp.example.local/mcp"
PI_MCP_2_TOKEN="secrettoken123"
```

On every container start `entrypoint.sh` turns those `PI_MCP_<n>_*` vars into
`data/agent/mcp.json` in pi's own format. Two details worth knowing:

- **Tokens are referenced, not copied.** A remote server's entry gets
  `"headers": {"Authorization": "Bearer ${PI_MCP_2_TOKEN}"}`, so the secret
  itself stays in the environment and never lands in a file inside your
  project.
- **`exposure` defaults to `direct`**, i.e. tools are declared to the model
  like built-in ones. pi's own default (`codemode`) additionally pulls in the
  `codemode` tool; for a couple of hand-picked single-purpose servers the
  explicit version is more predictable. Set `PI_MCP_<n>_EXPOSURE` to
  `codemode`, `deferred` or `hidden` to change it.

To add, remove, or edit servers: `./run.sh --edit-defaults` (every project) or
`./run.sh --edit-config` (this one), or delete `defaults.env` and re-run to go
through all the prompts again (server, model, and MCP servers together).

## Pi packages

The image ships a default list of pi packages (extensions, skills, prompt
templates) that `entrypoint.sh` makes sure are installed:

```
PI_PACKAGES='npm:pi-background-tasks npm:@juicesharp/rpiv-todo npm:pi-web-access npm:@companion-ai/feynman npm:@juicesharp/rpiv-ask-user-question'
```

- **`pi-background-tasks`** — durable background shell tasks and delegated child
  pi processes (`bg_run`, `bg_status`, `bg_logs`, `bg_kill`, `fusion_*`).
- **`@juicesharp/rpiv-todo`** — a todo list for the model, rendered as a live
  overlay that survives `/reload` and conversation compaction.
- **`pi-web-access`** — `web_search`, `fetch_content`, `source_check`,
  `get_search_content`, plus GitHub cloning and PDF/video extraction. Works
  keyless (Exa-backed search, direct fetching); more providers need keys in
  `data/agent/web-search.json`, which is inside the mount and therefore
  readable by the agent. Keyless Exa search is rate limited on a shared
  anonymous pool — see [Search quotas](#search-quotas).
- **`@companion-ai/feynman`** — research agent: brings its own skills, prompts,
  themes and subagents for literature-review style work.
- **`@juicesharp/rpiv-ask-user-question`** — a structured questionnaire the model
  can put to you with typed options instead of guessing.

That second one overlaps the `duckduckgo` MCP server (`search` / `fetch_content`).
Both can stay — pi just has two ways to do the same thing — but if you want the
smallest tool set, drop the MCP entry and keep `pi-web-access`, or the other way
round.

Unlike the old MCP adapter, these are installed **once per project**
into the persistent `data/agent` dir, so the first start downloads them and every
later start is a no-op — nothing is fetched from npm at every container start.

To change the list, set `PI_PACKAGES` in `~/.config/pi-sandbox/defaults.env`
(space-separated, any `npm:` / `git:` / `file:` source pi accepts) or per project
with `--edit-config`. `PI_PACKAGES=''` installs none. Upgrades ride along with
the image: `pi update` inside a session, or `pi uninstall npm:<pkg>` to drop one.

### Search quotas

`pi-web-access` searches through Exa's hosted MCP endpoint when no key is
configured, and that keyless tier shares one anonymous quota (Exa returns a
`rateLimited` marker rather than an error once it's spent — which the extension
hands to the model as if it were the results, so a throttled search looks like a
weak answer rather than a failure). `fetch_content` is unaffected: it fetches
directly. To remove the ceiling, put `exaApiKey` in `data/agent/web-search.json`
(free account, 10 QPS on `/search`), or point it at your own SearXNG — which
`auto` mode already prefers when configured. Both keys and the SearXNG URL live
inside the mount, so the agent can read them.

## Project memory (Hindsight, optional)

Set `PI_HINDSIGHT=1` in the config file (or answer `y` to the first-run
prompt) and `run.sh` also runs [Hindsight](https://github.com/vectorize-io/hindsight)
— a local memory server — as one detached Podman container per project. On
the next start, `entrypoint.sh` installs the official
`@vectorize-io/hindsight-coding-agents` extension into pi; from then on
relevant memories are recalled into every turn and every turn is retained in
the background. The repo's git history is ingested too, so decisions that
only live in old commit messages become searchable. What pi knows about the
project survives sessions and context compaction.

- **Data.** The embedded PostgreSQL lives in `pi-sandbox/data/hindsight/`
  (gitignored) — the memory travels with the project folder, and deleting it
  means the project starts knowing nothing. On macOS, Postgres on a virtiofs
  bind mount can misbehave; `PI_HINDSIGHT_VOLUME=1` switches to a named
  volume instead (everything else unchanged).
- **Models.** Fact extraction reuses `PI_PROVIDER_BASE_URL` /
  `PI_PROVIDER_API_KEY` with `PI_HINDSIGHT_LLM_MODEL` (default:
  `PI_MODEL_ID`) — point it at a cheap model if your server serves several.
  Embeddings and reranking run locally inside the Hindsight container, no API
  key needed.
- **Ports.** API `http://localhost:8888`, memory browser UI
  `http://localhost:9999`, both bound to `127.0.0.1` only. Two projects with
  memory running at once need distinct `PI_HINDSIGHT_PORT` /
  `PI_HINDSIGHT_UI_PORT` values.
- **Control.** The memory server stops when pi exits — the sandbox leaves
  nothing behind. Set `PI_HINDSIGHT_KEEP=1` to instead keep it up between
  sessions (faster restarts), and stop it manually with
  `./run.sh --hindsight stop`; `start`/`status` manage it without needing pi.
  `PI_HINDSIGHT=0` turns the feature off. If the server can't be reached, pi
  starts anyway without memory — a warning, never a failure.
- **The extension** is wired natively, not as a pi package (the upstream
  package deliberately supports only its installer for pi): the installer
  runs once into `data/home/.hindsight`, and `~/.pi/agent` is symlinked into
  `data/agent` so its settings wiring lands in the very `settings.json` pi
  reads. pi's own daily auto-update keeps the runtime fresh afterwards.
- **Nothing is redacted.** Everything pi says lands in the memory DB — treat
  `data/hindsight/` like a transcript of the whole collaboration (it is
  one). It sits inside the mount, so the agent can read it.

## Updates

Nothing is pinned-and-forgotten, and nothing changes behind your back at some
random moment: every check runs when the container starts, where you can see it
happen.

| What | Checked on every start | How it gets updated |
|---|---|---|
| pi itself | npm's latest vs what's running | installed into `data/pi-runtime` and shadowed via PATH — the root filesystem is read-only, so the image's own copy can't replace itself. Pruned again automatically once a rebuild catches up with it. |
| pi packages | npm's latest vs `data/agent/npm` | `pi update --extension`, falling back to an explicit `npm install <pkg>@<version>` when the stored spec is pinned and `npm update` can't move it |
| base image, apt tools, uv | `podman pull` before the build (skipped by `--no-build`) | a changed parent image id invalidates the layers beneath it, so `node`, `fd`, `ripgrep` and friends rebuild too |
| model catalog | not checked | `PI_OFFLINE=1` on purpose — the only provider is the one in `models.json` |

A start costs about **4–6 s** with `--no-build`, and 40–60 s on the days a base
image or pi actually changed (rebuilding the pi layer is the slow part). An
unreachable npm registry is a warning, not a failure: the session starts on what
is already installed.

| Knob (in the config file) | Effect |
|---|---|
| `PI_UPDATE_CHECK=always` *(default)* | check every start |
| `PI_UPDATE_CHECK=daily` | at most once a day, stamped in `data/.last-update-check` |
| `PI_UPDATE_CHECK=never` | still install missing packages, otherwise change nothing |
| `PI_VERSION` (Containerfile `ARG`) | the pi the **image** starts from — a floor, not a ceiling |

To force a refresh even when the base image tag hasn't moved:

```bash
podman build --no-cache -t pi-sandbox -f Containerfile .
```

Inside a session, `pi update --all` does the same job on demand.

## Python packages

`python3` and `uv` are installed in the image, and pi can freely run
`uv venv`, `uv add`, `uv pip install`, etc. This works fine even though the
container's own root filesystem is `--read-only`: `uv`'s default venv
location is `.venv` in the current directory, which is under `/workspace`
— the bind-mounted, writable project folder — not on the rootfs. So a
`.venv` created this way lands in your real project (gitignore it there if
you don't want it committed) and survives across container restarts, the
same way `node_modules` would. `uv`'s cache lives in `pi-sandbox/data/home`,
so it is reused between runs and never touches the rootfs either.

## Network tools

`curl`, `wget`, `nmap`, `ping`, `dig`/`nslookup`, `nc`, and `traceroute` are
installed for network investigation. One caveat: `--cap-drop=ALL` removes
`CAP_NET_RAW`, so `nmap` can't do raw-socket scans (e.g. `-sS` SYN scans) —
it automatically falls back to a TCP connect scan instead, which still
works but is slower and more easily logged by the target.

## What's sandboxed

- Only the parent of this folder (your actual project, including this
  `pi-sandbox/` subfolder) is mounted. pi cannot reach any other **host**
  files — not the rest of your filesystem, not sibling project folders. (The
  container does have its own root filesystem, `/tmp` and `/proc`; they just
  contain nothing of yours.)
- The mount is read-write: edits under `/workspace` land on your real files.
  Use version control, or a read-only mount, for work you don't want written
  back.
- The container's own root filesystem is read-only (`--read-only` + `--tmpfs /tmp`).
- All Linux capabilities are dropped (`--cap-drop=ALL`), and
  `--security-opt=no-new-privileges` stops setuid helpers from gaining rights.
- `--memory` (default 4g) and `--pids-limit` (default 4096) cap what a runaway
  command can eat. Set `PI_SANDBOX_MEMORY` / `PI_SANDBOX_PIDS` in the config
  file to change them.
- Runs as UID 1000 in the container, mapped to your own UID via
  `--user 1000:1000 --userns=keep-id:uid=1000,gid=1000`, so files created in
  the project folder are owned by you, not root.
- Networking uses Podman's default rootless network — outbound connections
  (to your model server and the internet) work normally; nothing is exposed
  inbound. pi starts with `PI_OFFLINE=1`, `PI_SKIP_VERSION_CHECK=1` and
  `PI_TELEMETRY=0` so it doesn't call `pi.dev` on startup; set any of them in
  the config file to override.

### What that does *not* buy you

pi deliberately has no built-in sandbox — with this setup the container *is*
the boundary, which is what pi's own
[containerization guide](https://pi.dev/docs/latest/containerization)
recommends. But pi also doesn't ask before running a tool call, so treat
anything inside as "as powerful as this container":

- **Outbound network is open**, which is the exfiltration path for prompt
  injection. Restricting the container to just your model server (an
  `--internal` Podman network, or a proxy) is the single biggest hardening
  step left, and matters far more than where the API key is stored.
- **The key is in the container's environment**, so a command pi runs can
  still print it. Moving the config file out of `/workspace` stops the agent
  reading or rewriting *the file* (and keeps secrets out of git), but the
  real key boundary would be a header-injecting sidecar in a pod, which keeps
  the secret out of the agent's container entirely. Until then, use a narrowly
  scoped key.
- Anything under `pi-sandbox/data/` is inside the mount, so pi can edit its
  own sessions and generated config. That includes `data/agent/auth.json` and
  `data/agent/web-search.json`: run `/login` with a subscription provider, or
  give `pi-web-access` provider keys, and whatever is stored there is readable
  by the agent. The `models.json` setup described above keeps no credential on
  disk at all.

## Files

- `Containerfile` — defines the image: `node:22-slim` (pi's latest release
  needs Node ≥22.19; older Node silently installs a legacy build) with
  `@earendil-works/pi-coding-agent` installed globally at the pinned
  `PI_VERSION`, plus `git`, `ripgrep` (pi's grep tool uses it), `fd-find` (pi's
  find tool shells out to `fd`, and offline mode stops it downloading one), `curl`,
  `wget`, `nmap`, `ping`, `dig`/`nslookup`, `nc`, `traceroute` for network
  investigation, and `python3` + [`uv`](https://docs.astral.sh/uv/) for Python
  work. Runs as the base image's built-in non-root `node` user. No addresses
  or secrets baked in, so it's safe to share as-is.
- `run.sh` — checks Podman is installed and reachable (starting it on macOS
  if not, or pointing out the systemd-in-WSL2 fix on Windows), prompts for the
  system-wide config on first run (and migrates a `pi-sandbox/.env` from an
  older setup), sources it plus this project's override file, rewrites
  `localhost`/`127.0.0.1` in your server URL to `host.containers.internal` so a
  server on your own machine works, appends `/v1` to a bare `host:port` (where
  OpenAI-compatible servers live), starts the optional Hindsight memory
  server when `PI_HINDSIGHT=1`, builds, and launches the sandboxed
  container. `--no-build`, `--edit-defaults`, `--edit-config`,
  `--hindsight start|stop|status`, `--help` are its own; anything else goes
  to pi.
- `entrypoint.sh` — runs inside the container before pi starts. Points pi's
  config dir and `$HOME` at `pi-sandbox/data/`, then regenerates pi's
  [`models.json`](https://pi.dev/docs/latest/models) / `settings.json` /
  [`mcp.json`](https://pi.dev/docs/latest/mcp) from the forwarded variables,
  merging with what's already there so your own edits and `pi mcp add`
  servers are kept. Registers your server as a provider named `sandbox` and
  sets it — and your configured model — as pi's default. Installs the
  Hindsight memory extension once when memory is enabled. Then it prints what's
  visible under `/workspace` and hands off to pi.
- `extensions/welcome.ts` — small glue loaded via `settings.json` (wired by
  `entrypoint.sh`): the feynman package replaces pi's built-in welcome header
  with its own research card after an async build, so this extension restores
  pi's stock header once feynman's chain settles, and adds a `/sandbox`
  command showing model, mount, memory, and MCP facts. Edit freely; plain
  TypeScript loaded by pi's `jiti`.

## Updating pi

The pinned version is the `PI_VERSION` build arg, so a cached build is always
a known version. To move forward:

```bash
PI_VERSION=1.4.0 ./run.sh          # one-off
# or edit the ARG line in Containerfile to make it the new default
```

## Sharing this project

Nothing secret is in here at all: the config lives in
`~/.config/pi-sandbox/defaults.env` (one per machine, created on first run) and
generated state in the gitignored `data/`. Commit `Containerfile`, `run.sh`,
`entrypoint.sh`, `README.md`, `.gitignore`. Anyone who clones just runs
`./run.sh` and answers the prompts for their own server.
