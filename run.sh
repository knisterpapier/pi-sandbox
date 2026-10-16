#!/bin/bash
set -e

# This script's own folder (the tooling subfolder, e.g. "pi-sandbox")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The parent folder = your actual project
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_NAME="$(basename "$PROJECT_ROOT")"

IMAGE_NAME="pi-sandbox"

# ---------------------------------------------------------------------------
# Config lives OUTSIDE the project, so the agent can neither read nor rewrite
# its own settings and credentials. Two layers, both optional, sourced in order:
#
#   ~/.config/pi-sandbox/defaults.env          system-wide, shared by every project
#   ~/.config/pi-sandbox/<project-name>/.env   optional per-project overrides
#
# So the server URL and key are filled in once and every project on this machine
# uses them; a project only repeats what differs. PI_SANDBOX_ENV replaces the
# project layer with a file of your own (CI, or two projects sharing a name).
# ---------------------------------------------------------------------------
CONFIG_ROOT="${PI_SANDBOX_CONFIG_ROOT:-$HOME/.config/pi-sandbox}"
DEFAULTS_FILE="$CONFIG_ROOT/defaults.env"

if [ -n "$PI_SANDBOX_ENV" ]; then
  ENV_FILE="$PI_SANDBOX_ENV"
  ENV_DIR="$(dirname "$ENV_FILE")"
else
  ENV_DIR="$CONFIG_ROOT/$PROJECT_NAME"
  if [ -f "$ENV_DIR/.project" ] && [ "$(cat "$ENV_DIR/.project")" != "$PROJECT_ROOT" ]; then
    # Another project folder shares this name — keep both configs apart.
    hash_of() { printf '%s' "$1" | (md5 -q 2>/dev/null || md5sum | cut -d' ' -f1) | cut -c1-8; }
    ENV_DIR="$CONFIG_ROOT/$PROJECT_NAME-$(hash_of "$PROJECT_ROOT")"
  fi
  ENV_FILE="$ENV_DIR/.env"
fi

# Write "NAME='value'" safely: single quotes stop the shell from expanding $,
# backticks etc. in keys and tokens.
env_put() {
  printf "%s='%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"
}

usage() {
  cat <<USAGE
Usage: ./run.sh [pi-sandbox flags] [pi flags...]

  --no-build         skip the image build
  --edit-defaults    edit the system-wide config:   $DEFAULTS_FILE
  --edit-config      edit this project's overrides: $ENV_FILE
  --help             this text

Config: $DEFAULTS_FILE applies to every pi-sandbox on this machine;
$ENV_FILE overrides it for this project only.
Anything else is passed through to pi, e.g. ./run.sh --no-build -p "summarize README.md"
USAGE
}

# ---------------------------------------------------------------------------
# Flags: the ones below are ours, everything else goes to pi.
# ---------------------------------------------------------------------------
NO_BUILD=false
EDIT_FILE=""
PI_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) NO_BUILD=true ;;
    --edit-defaults) EDIT_FILE="$DEFAULTS_FILE" ;;
    --edit-config) EDIT_FILE="$ENV_FILE" ;;
    --hindsight)
      echo "--hindsight was removed from pi-sandbox: the memory server and its" >&2
      echo "data are gone, so there is nothing left to start, stop, or check." >&2
      exit 2 ;;
    -h|--help) usage; exit 0 ;;
    *) PI_ARGS+=("$1") ;;
  esac
  shift
done

if [ -n "$EDIT_FILE" ]; then
  if [ ! -f "$EDIT_FILE" ]; then
    if [ "$EDIT_FILE" = "$DEFAULTS_FILE" ]; then
      echo "No system-wide config yet — run ./run.sh once to create $DEFAULTS_FILE"
      exit 1
    fi
    # First override for this project: create a stub worth editing.
    mkdir -p "$ENV_DIR"
    chmod 700 "$ENV_DIR"
    printf '%s\n' "$PROJECT_ROOT" > "$ENV_DIR/.project"
    {
      echo "# Overrides for $PROJECT_NAME only; anything left out comes from"
      echo "# $DEFAULTS_FILE"
      echo "# Uncomment and change what this project should do differently."
      echo "# PI_PROVIDER_BASE_URL='http://192.168.1.10:8000/v1'"
      echo "# PI_PROVIDER_API_KEY='not-needed'"
      echo "# PI_MODEL_ID='some-other-model'"
      echo "# PI_MCP_1_NAME=''"
    } > "$EDIT_FILE"
    chmod 600 "$EDIT_FILE"
    echo "Created $EDIT_FILE"
  fi
  exec "${EDITOR:-nano}" "$EDIT_FILE"
fi

# ---------------------------------------------------------------------------
# Podman must be installed and reachable.
# ---------------------------------------------------------------------------
if ! command -v podman >/dev/null 2>&1; then
  echo "Ohno! Podman isn't installed."
  case "$(uname)" in
    Darwin)
      echo "Install it with: brew install podman"
      ;;
    Linux)
      if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
        echo "You're in WSL2 — install Podman inside this distro (not Podman"
        echo "Desktop's separate VM), e.g.: sudo apt install podman"
      else
        echo "Install it with your package manager, e.g.:"
        echo "  sudo apt install podman   (Debian/Ubuntu)"
        echo "  sudo dnf install podman   (Fedora/RHEL)"
        echo "  sudo pacman -S podman     (Arch)"
      fi
      ;;
    *)
      echo "See https://podman.io/docs/installation for your platform."
      ;;
  esac
  exit 1
fi

if ! podman info >/dev/null 2>&1; then
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "Podman isn't reachable — starting its Linux VM (one-time setup on macOS)..."
    if ! podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then
      podman machine init
    fi
    podman machine start
    if ! podman info >/dev/null 2>&1; then
      echo "Still can't reach Podman after starting the machine. Check 'podman machine list' / 'podman machine start'."
      exit 1
    fi
  else
    echo "Cannot connect to Podman. Check 'podman system connection list', or start your Podman service, then re-run this script."
    if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
      echo "Running under WSL2: this usually means systemd isn't enabled for" \
           "the distro yet, which rootless Podman needs. Add '[boot]' /" \
           "'systemd=true' to /etc/wsl.conf inside this distro, then run" \
           "'wsl --shutdown' from Windows and reopen it."
    fi
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# No config anywhere yet: ask for everything and write the SYSTEM-WIDE file, so
# every later project on this machine starts from it. Change a value later with
# --edit-defaults, or --edit-config for a project-only override; delete the file
# to answer the prompts again.
# ---------------------------------------------------------------------------
if [ ! -f "$DEFAULTS_FILE" ] && [ ! -f "$ENV_FILE" ]; then
  # Older sandboxes kept the file inside the project folder; move it out
  # instead of making you answer the questions again.
  if [ -f "$SCRIPT_DIR/.env" ]; then
    mkdir -p "$ENV_DIR"
    chmod 700 "$ENV_DIR"
    mv "$SCRIPT_DIR/.env" "$ENV_FILE"
    printf '%s\n' "$PROJECT_ROOT" > "$ENV_DIR/.project"
    chmod 600 "$ENV_FILE"
    echo "Moved $SCRIPT_DIR/.env -> $ENV_FILE"
    echo "(the config now lives outside /workspace, so pi can't read or rewrite it)"
    echo ""
  fi
fi

if [ ! -f "$DEFAULTS_FILE" ] && [ ! -f "$ENV_FILE" ]; then
  echo "No config yet. Let's set up your model server — this one file will be"
  echo "used by every pi-sandbox on this machine."
  echo ""

  read -rp "Model server URL (e.g. http://192.168.1.10:8000/v1): " PI_PROVIDER_BASE_URL
  if [ -z "$PI_PROVIDER_BASE_URL" ]; then
    echo "A server URL is required. Aborting."
    exit 1
  fi

  read -rsp "API key / password (optional, press Enter to skip): " PI_PROVIDER_API_KEY
  echo ""

  read -rp "Model id [default]: " PI_MODEL_ID
  PI_MODEL_ID="${PI_MODEL_ID:-default}"

  read -rp "Context window in tokens [128000]: " PI_CONTEXT_WINDOW
  PI_CONTEXT_WINDOW="${PI_CONTEXT_WINDOW:-128000}"

  read -rp "Max output tokens [4096]: " PI_MAX_TOKENS
  PI_MAX_TOKENS="${PI_MAX_TOKENS:-4096}"

  mkdir -p "$CONFIG_ROOT"
  chmod 700 "$CONFIG_ROOT"

  {
    env_put PI_PROVIDER_BASE_URL "$PI_PROVIDER_BASE_URL"
    [ -n "$PI_PROVIDER_API_KEY" ] && env_put PI_PROVIDER_API_KEY "$PI_PROVIDER_API_KEY"
    env_put PI_MODEL_ID "$PI_MODEL_ID"
    env_put PI_CONTEXT_WINDOW "$PI_CONTEXT_WINDOW"
    env_put PI_MAX_TOKENS "$PI_MAX_TOKENS"
  } > "$DEFAULTS_FILE"
  chmod 600 "$DEFAULTS_FILE"

  # MCP servers, using pi's built-in MCP client. Stored as flat PI_MCP_<n>_*
  # vars here and turned into <pi-config-dir>/mcp.json on every container start
  # by entrypoint.sh. Optional PI_MCP_<n>_EXPOSURE picks how their tools reach
  # the model (direct | deferred | codemode | hidden); default is direct.
  echo ""
  read -rp "Add MCP servers for pi to use? [y/N]: " ADD_MCP
  echo ""

  if [[ "$ADD_MCP" =~ ^[Yy] ]]; then
    N=1
    while true; do
      read -rp "MCP server name (blank to stop adding): " MCP_NAME
      [ -z "$MCP_NAME" ] && break

      read -rp "  [1] Local command (stdio, default)  [2] Remote URL: " MCP_TYPE
      echo ""

      env_put "PI_MCP_${N}_NAME" "$MCP_NAME" >> "$DEFAULTS_FILE"
      if [ "$MCP_TYPE" = "2" ]; then
        read -rp "  Server URL: " MCP_URL
        read -rsp "  Bearer token (optional, press Enter to skip): " MCP_TOKEN
        echo ""
        env_put "PI_MCP_${N}_URL" "$MCP_URL" >> "$DEFAULTS_FILE"
        [ -n "$MCP_TOKEN" ] && env_put "PI_MCP_${N}_TOKEN" "$MCP_TOKEN" >> "$DEFAULTS_FILE"
      else
        read -rp "  Command (e.g. npx): " MCP_CMD
        read -rp "  Args (space-separated, e.g. -y @scope/some-mcp-server): " MCP_ARGS
        env_put "PI_MCP_${N}_COMMAND" "$MCP_CMD" >> "$DEFAULTS_FILE"
        [ -n "$MCP_ARGS" ] && env_put "PI_MCP_${N}_ARGS" "$MCP_ARGS" >> "$DEFAULTS_FILE"
      fi
      N=$((N + 1))
      echo ""
    done
  fi

  echo "Wrote $DEFAULTS_FILE (system-wide)"
  echo "(--edit-defaults changes it later; delete it to go through the prompts again)"
  echo ""
fi

# Source both layers, project overrides last. As before, only the -e flags below
# decide what actually crosses into the container.
CONFIG_SOURCES=()
for f in "$DEFAULTS_FILE" "$ENV_FILE"; do
  [ -f "$f" ] || continue
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
  if [ "$f" = "$DEFAULTS_FILE" ]; then
    CONFIG_SOURCES+=("$f  (system-wide)")
  else
    CONFIG_SOURCES+=("$f  (overrides for this project)")
  fi
done

if [ -z "${PI_PROVIDER_BASE_URL:-}" ]; then
  echo "No PI_PROVIDER_BASE_URL in the config file(s) — add it there, or delete"
  echo "them and re-run ./run.sh to answer the prompts again:"
  [ "${#CONFIG_SOURCES[@]}" -gt 0 ] && printf '  %s\n' "${CONFIG_SOURCES[@]}"
  exit 1
fi

echo "Config:"
printf '  %s\n' "${CONFIG_SOURCES[@]}"

# Inside the container, 127.0.0.1/localhost is the container itself. Rewrite
# them to host.containers.internal, which Podman routes to this machine's
# localhost — so a server on your own machine is reachable as typed.
PI_PROVIDER_BASE_URL="$(printf '%s' "$PI_PROVIDER_BASE_URL" \
  | sed -E 's#://(127\.0\.0\.1|localhost)([:/]|$)#://host.containers.internal\2#')"
# OpenAI-compatible servers live under /v1 — add it if only host:port was given.
if [[ "$PI_PROVIDER_BASE_URL" =~ ^https?://[^/]+/?$ ]]; then
  PI_PROVIDER_BASE_URL="${PI_PROVIDER_BASE_URL%/}/v1"
fi
export PI_PROVIDER_BASE_URL

# pi needs *an* apiKey or it hides the model from /model, even when the server
# doesn't check one. Never let it be empty.
export PI_PROVIDER_API_KEY="${PI_PROVIDER_API_KEY:-sandbox}"

# Host-side bounded runner: macOS ships neither timeout(1) nor gtimeout by
# default, so fall back to running it unbounded rather than failing.
timeout_cmd() {
  if command -v timeout >/dev/null 2>&1; then timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"
  else shift; "$@"
  fi
}

# Resource caps. Override in the config file if a build needs more.
MEMORY_LIMIT="${PI_SANDBOX_MEMORY:-4g}"
PIDS_LIMIT="${PI_SANDBOX_PIDS:-4096}"

# A plain ./run.sh checks for updates on every start, in two halves: the image
# here (base image + system tools), and pi plus its packages inside the
# container (see entrypoint.sh). --no-build skips this half and only the
# in-container check runs.
if [ "$NO_BUILD" = false ]; then
  echo "Checking base images for updates..."
  for base in docker.io/library/node:22-slim ghcr.io/astral-sh/uv:latest; do
    if ! timeout_cmd 120 podman pull -q "$base" >/dev/null 2>&1; then
      echo "  Couldn't check $base — continuing with the cached copy."
    fi
  done

  # If a pull changed the parent image, the layers below it (apt packages like
  # fd/rg, node itself) rebuild automatically. For a forced refresh of an
  # unchanged base: podman build --no-cache.
  #
  # PI_VERSION (Containerfile ARG) is the pi the image starts from, not a
  # ceiling: entrypoint.sh upgrades to npm's latest into data/pi-runtime.
  podman build --build-arg "PI_VERSION=${PI_VERSION:-1.3.0}" \
    -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"
fi

# Forward every PI_MCP_<n>_* var the config defines, so entrypoint.sh can
# rebuild mcp.json from them — works the same whether the file was just written
# or already existed.
MCP_ENV_FLAGS=()
for v in "${!PI_MCP_@}"; do
  MCP_ENV_FLAGS+=(-e "$v")
done

# Optional settings: only forwarded when the config file actually sets them, so
# the image defaults apply otherwise. Setting one to an empty value does count
# (that's how PI_PACKAGES='' installs nothing). The first three are set in the
# Containerfile to keep pi off the network at startup — setting any of them
# here overrides that.
OPTIONAL_VARS=(PI_OFFLINE PI_SKIP_VERSION_CHECK PI_TELEMETRY PI_UPDATE_CHECK
               PI_MODEL_INPUT PI_MODEL_REASONING PI_EXTRA_MODELS PI_PACKAGES)
EXTRA_FLAGS=()
for v in "${OPTIONAL_VARS[@]}"; do
  if declare -p "$v" >/dev/null 2>&1; then EXTRA_FLAGS+=(-e "$v"); fi
done

echo "Mounting project root: $PROJECT_ROOT -> /workspace"

# --user + --userns=keep-id:uid=1000,gid=1000 map the container's node user
# (UID 1000) onto your own host UID, so files pi creates are owned by you.
# Anything after the image name goes straight to pi, e.g.:
#   ./run.sh --no-build -p "summarize the project"
podman run --rm -it \
  --userns=keep-id:uid=1000,gid=1000 \
  --user 1000:1000 \
  --security-opt=no-new-privileges \
  --cap-drop=ALL \
  --read-only \
  --tmpfs /tmp \
  --memory "$MEMORY_LIMIT" \
  --pids-limit "$PIDS_LIMIT" \
  -v "$PROJECT_ROOT:/workspace:Z" \
  -e PI_SANDBOX_SUBDIR="$(basename "$SCRIPT_DIR")" \
  -e PI_SANDBOX_HOST_PROJECT="$PROJECT_ROOT" \
  -e PI_PROVIDER_BASE_URL \
  -e PI_PROVIDER_API_KEY \
  -e PI_MODEL_ID \
  -e PI_CONTEXT_WINDOW \
  -e PI_MAX_TOKENS \
  "${MCP_ENV_FLAGS[@]}" \
  "${EXTRA_FLAGS[@]}" \
  "$IMAGE_NAME" "${PI_ARGS[@]}"
