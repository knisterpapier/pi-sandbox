#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# Persistent pi home.
#
# pi keeps its config (settings.json / models.json / mcp.json / auth.json),
# sessions, saved project-trust decisions and packages in its "agent dir".
# Keeping that under the (writable) project mount means it survives container
# restarts, so `pi --continue`, /tree and a saved /trust decision all work
# across runs — while staying inside one gitignored folder. The agent can read
# and edit its own config here; that is deliberate.
# If the mount isn't writable, fall back to tmpfs so pi still starts.
# ---------------------------------------------------------------------------
SANDBOX_DIR="/workspace/${PI_SANDBOX_SUBDIR:-pi-sandbox}"
DATA_DIR="$SANDBOX_DIR/data"

# `mkdir -p` succeeds on an existing read-only folder, so check writability
# explicitly before committing to the persistent location.
if mkdir -p "$DATA_DIR/agent" 2>/dev/null && [ -w "$DATA_DIR/agent" ]; then
  # HOME also lives there, so npm's (npx) and uv's caches are reused between
  # runs instead of re-downloading every MCP server on every start.
  export HOME="$DATA_DIR/home"
  export PI_CODING_AGENT_DIR="$DATA_DIR/agent"
  PERSISTENT=yes
else
  echo "Warning: $DATA_DIR is not writable; using an ephemeral /tmp/pi-agent instead." >&2
  export HOME=/tmp
  export PI_CODING_AGENT_DIR=/tmp/pi-agent
  PERSISTENT=no
fi
mkdir -p "$HOME" "$PI_CODING_AGENT_DIR"

# pi hides models whose provider has no apiKey from /model and --list-models,
# even for servers that never check it (e.g. Ollama, llama.cpp). models.json
# refers to this variable by name, so the secret itself is never written to
# disk — and a placeholder keeps keyless servers listed.
export PI_PROVIDER_API_KEY="${PI_PROVIDER_API_KEY:-sandbox}"

# ---------------------------------------------------------------------------
# Generate/refresh pi's config from the env vars run.sh forwarded (sourced
# from the sandbox's .env, which lives outside /workspace). Only the parts
# .env defines are rewritten; anything else you or pi put into these files is
# kept.
# ---------------------------------------------------------------------------
python3 - "$PERSISTENT" <<'PY'
import json, os, pathlib, re, sys

persistent = len(sys.argv) > 1 and sys.argv[1] == "yes"

agent_dir = pathlib.Path(os.environ["PI_CODING_AGENT_DIR"])
base_url = os.environ.get("PI_PROVIDER_BASE_URL", "").strip()


def load(name, default):
    path = agent_dir / name
    if path.exists():
        try:
            return json.loads(path.read_text() or "null") or default
        except (json.JSONDecodeError, ValueError) as exc:
            print(f"Warning: {path} is not valid JSON ({exc}); regenerating it.", file=sys.stderr)
    return default


def save(name, data):
    path = agent_dir / name
    try:
        path.write_text(json.dumps(data, indent=2) + "\n")
    except OSError as exc:
        # A read-only mount shouldn't stop pi from starting.
        print(f"Warning: could not write {path} ({exc}); pi will use its existing config.", file=sys.stderr)


def load_names(name):
    """Previously managed server/model names; [] when the file is absent or broken."""
    path = agent_dir / name
    try:
        return json.loads(path.read_text() or "[]") if path.exists() else []
    except (json.JSONDecodeError, ValueError):
        return []


def env_words(name):
    """A config var holding a comma- or space-separated list."""
    return [word for word in re.split(r"[,\s]+", os.environ.get(name, "")) if word]


# --- model server + models ---------------------------------------------------
if base_url:
    primary = (os.environ.get("PI_MODEL_ID") or "default").strip()
    context_window = int(os.environ.get("PI_CONTEXT_WINDOW") or 128000)
    max_tokens = int(os.environ.get("PI_MAX_TOKENS") or 4096)
    # pi only sends images to a model whose entry says it accepts them.
    model_input = env_words("PI_MODEL_INPUT") or ["text"]
    # pi only offers /thinking levels for models marked reasoning-capable, and
    # then sends the extra request field — so this is opt-in per server.
    reasoning = (os.environ.get("PI_MODEL_REASONING") or "").lower() in ("1", "true", "yes")

    # Managed = regenerated from the config file on every start. Anything else
    # already in models.json (a hand-edited entry, a model added by hand) is
    # left alone, which is how a second model on the same server survives.
    managed_models = [primary] + [m for m in env_words("PI_EXTRA_MODELS") if m != primary]

    catalogue = load("models.json", {})
    providers = catalogue.setdefault("providers", {})
    provider = providers.get("sandbox")
    if not isinstance(provider, dict):
        provider = providers["sandbox"] = {}
    provider["baseUrl"] = base_url
    provider["api"] = "openai-completions"
    provider["apiKey"] = "${PI_PROVIDER_API_KEY}"

    by_id = {m["id"]: m for m in provider.get("models", []) if isinstance(m, dict) and m.get("id")}
    managed_models_file = ".pi-sandbox-managed-models.json"
    previously = load_names(managed_models_file)
    if not previously and not (agent_dir / managed_models_file).exists():
        # models.json written by an older version of this script: every model
        # under 'sandbox' was generated from the config file, so all of them are
        # replaceable rather than hand-added.
        previously = list(by_id)
    for stale in previously:
        if stale not in managed_models:
            by_id.pop(stale, None)
    for model_id in managed_models:
        by_id[model_id] = {
            **by_id.get(model_id, {}),
            "id": model_id,
            "contextWindow": context_window,
            "maxTokens": max_tokens,
            "input": model_input,
            "reasoning": reasoning,
        }
    provider["models"] = [by_id[m] for m in managed_models] + [
        m for name, m in by_id.items() if name not in managed_models
    ]
    save("models.json", catalogue)
    save(managed_models_file, managed_models)

    settings = load("settings.json", {})
    settings["defaultProvider"] = "sandbox"
    settings["defaultModel"] = primary
    save("settings.json", settings)

# --- MCP servers ------------------------------------------------------------
# pi has a built-in MCP client that reads <agent-dir>/mcp.json, so no adapter
# package is needed. Flat PI_MCP_<n>_* vars from .env are turned into pi's own
# entry format; servers already in the file that this sandbox does not manage
# (e.g. added with `pi mcp add`) are left untouched.
managed, servers = [], {}
n = 1
while os.environ.get(f"PI_MCP_{n}_NAME"):
    name = os.environ[f"PI_MCP_{n}_NAME"].strip()
    url = (os.environ.get(f"PI_MCP_{n}_URL") or "").strip()
    command = (os.environ.get(f"PI_MCP_{n}_COMMAND") or "").strip()
    entry = {}

    if url:
        entry["url"] = url
        if (os.environ.get(f"PI_MCP_{n}_TOKEN") or "").strip():
            # Referenced by variable name so the token never lands on disk.
            entry["headers"] = {"Authorization": f"Bearer ${{PI_MCP_{n}_TOKEN}}"}
    elif command:
        entry["command"] = command
        entry["args"] = (os.environ.get(f"PI_MCP_{n}_ARGS") or "").split()
    else:
        print(f"Warning: MCP server '{name}' has neither a URL nor a command; skipped.", file=sys.stderr)
        n += 1
        continue

    # pi's default exposure ("codemode") also activates the codemode tool.
    # Hand-picked single-purpose servers are more predictable as "direct",
    # i.e. declared like a built-in tool. Set PI_MCP_<n>_EXPOSURE to override
    # (codemode | deferred | direct | hidden).
    entry["exposure"] = (os.environ.get(f"PI_MCP_{n}_EXPOSURE") or "direct").strip()
    servers[name] = entry
    managed.append(name)
    n += 1

mcp = load("mcp.json", {})
configured = mcp.setdefault("mcpServers", {})
for stale in load_names(".pi-sandbox-managed-mcp.json"):
    if stale not in servers:
        configured.pop(stale, None)
configured.update(servers)
save("mcp.json", mcp)
save(".pi-sandbox-managed-mcp.json", managed)

# --- summary ----------------------------------------------------------------
if base_url:
    extras = f" (+{len(managed_models) - 1} more model{'s' if len(managed_models) > 2 else ''})" if len(managed_models) > 1 else ""
    print(f"pi config: provider 'sandbox' -> {base_url}")
    print(f"  model {primary}: ctx {context_window}, max output {max_tokens}, "
          f"input {'+'.join(model_input)}, thinking {'on' if reasoning else 'off'}{extras}")
if servers:
    print("MCP servers (built-in client): " + ", ".join(f"{k} [{v['exposure']}]" for k, v in servers.items()))
print(f"pi config dir: {agent_dir} "
      + ("(persistent, inside the mount)" if persistent else "(ephemeral — this run's state is lost on exit)"))
PY

# ---------------------------------------------------------------------------
# Keep-current check, run on every start (PI_UPDATE_CHECK=always | daily | never).
#
# Three things age here, and they are checked in the only place each of them can
# actually be changed from inside a running container:
#
#   pi itself    npm's latest vs the image build, upgraded into $DATA/pi-runtime
#                (the image's own root filesystem is mounted read-only, so pi
#                cannot update itself in place; the cached copy shadows it via
#                PATH until a rebuild makes the image newer again)
#   pi packages  npm's latest vs data/agent/npm, upgraded with pi's own updater
#   system tools  fd/rg/apt come from the image, so only run.sh can refresh those
#                (it pulls the base images before building) — reported here
#
# Every network lookup is bounded and any failure is a warning: a missing
# registry answer must never stop the session from starting.
# ---------------------------------------------------------------------------
PI_PACKAGE="@earendil-works/pi-coding-agent"
RUNTIME_DIR="$DATA_DIR/pi-runtime"
RUNTIME_BIN="$RUNTIME_DIR/bin/pi"
IMAGE_PI="$(/usr/local/bin/pi --version 2>/dev/null || echo 0)"
UPDATES_CHECKED=no

newer_of() { printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1; }

npm_latest() { timeout 40 npm view "$1" version 2>/dev/null | tail -n 1; }

installed_version() {
  python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1]))["version"])
except Exception:
    pass' "$1" 2>/dev/null
}

due_for_update_check() {
  local stamp="$DATA_DIR/.last-update-check" now previous
  case "${PI_UPDATE_CHECK:-always}" in
    never) return 1 ;;
    daily)
      now="$(date +%s)"
      previous="$(cat "$stamp" 2>/dev/null || echo 0)"
      [ $((now - previous)) -lt 86400 ] && return 1
      ;;
  esac
  date +%s > "$stamp" 2>/dev/null || true
  return 0
}

# --- pi itself ---------------------------------------------------------------
RUNTIME_PI=""
if [ -x "$RUNTIME_BIN" ]; then
  RUNTIME_PI="$("$RUNTIME_BIN" --version 2>/dev/null || echo)"
fi

if [ -n "$RUNTIME_PI" ]; then
  if [ "$(newer_of "$RUNTIME_PI" "$IMAGE_PI")" = "$IMAGE_PI" ]; then
    # A rebuild caught up with (or passed) the cached copy — drop it again.
    echo "pi: image now has $IMAGE_PI, removing the older cached $RUNTIME_PI"
    rm -rf "$RUNTIME_DIR"
    RUNTIME_PI=""
  else
    PATH="$RUNTIME_DIR/bin:$PATH"
  fi
fi
CURRENT_PI="${RUNTIME_PI:-$IMAGE_PI}"

if due_for_update_check; then
  UPDATES_CHECKED=yes
  LATEST_PI="$(npm_latest "$PI_PACKAGE")"
  if [ -z "$LATEST_PI" ]; then
    echo "pi update check: npm registry unreachable, keeping pi $CURRENT_PI" >&2
  elif [ "$LATEST_PI" != "$CURRENT_PI" ]; then
    echo "pi $CURRENT_PI -> $LATEST_PI (installing into $DATA_DIR/pi-runtime, first time takes ~30s)..."
    if npm install -g --prefix "$RUNTIME_DIR" --ignore-scripts --no-audit --no-fund \
         "${PI_PACKAGE}@${LATEST_PI}" >/dev/null 2>/tmp/pi-update.err; then
      PATH="$RUNTIME_DIR/bin:$PATH"
      echo "pi: now running $("$RUNTIME_BIN" --version 2>/dev/null || echo "$LATEST_PI")"
    else
      echo "Warning: pi update to $LATEST_PI failed; staying on $CURRENT_PI:" >&2
      tail -n 3 /tmp/pi-update.err >&2
    fi
  fi
fi

# --- pi packages -------------------------------------------------------------
# Installed once per project into the agent dir; PI_PACKAGES comes from the
# image default (Containerfile) or the config file, which can also set it to an
# empty value to install none.
pi_state() {
  # Prints "<source> missing" or "<source> <installed-version>" per package.
  local src name have
  have="$(pi list 2>/dev/null | sed 's/^[[:space:]]*//' || true)"
  for src in $PI_PACKAGES; do
    if ! printf '%s\n' "$have" | grep -qxF "$src"; then
      printf '%s missing\n' "$src"
      continue
    fi
    name="${src#npm:}"
    printf '%s %s\n' "$src" "$(installed_version "$PI_CODING_AGENT_DIR/npm/node_modules/$name/package.json")"
  done
}

if [ -n "${PI_PACKAGES:-}" ]; then
  MISSING=""
  OUTDATED=""      # one tab-separated "source installed latest" per line
  while read -r src version; do
    [ -z "$src" ] && continue
    if [ "$version" = "missing" ]; then
      MISSING+="$src"$'\n'
      continue
    fi
    if [ "$UPDATES_CHECKED" = yes ] && [ -n "$version" ]; then
      want="$(npm_latest "${src#npm:}")"
      if [ -n "$want" ] && [ "$want" != "$version" ]; then
        OUTDATED+="$src	$version	$want"$'\n'
      fi
    fi
  done <<EOF
$(pi_state)
EOF

  while IFS= read -r src; do
    [ -z "$src" ] && continue
    echo "Installing pi package $src..."
    if ! pi install "$src" >/dev/null 2>/tmp/pi-install.err; then
      echo "Warning: pi install $src failed; it won't be available this run:" >&2
      tail -n 3 /tmp/pi-install.err >&2
    fi
  done <<< "$MISSING"

  # Deliberately not colon-delimited: the sources themselves contain colons.
  while IFS=$'\t' read -r src from to; do
    [ -z "$src" ] && continue
    echo "pi package $src: $from -> $to"
    manifest="$PI_CODING_AGENT_DIR/npm/node_modules/${src#npm:}/package.json"
    if ! pi update --extension "$src" >/dev/null 2>/tmp/pi-update.err; then
      echo "Warning: updating $src failed; staying on $from:" >&2
      tail -n 3 /tmp/pi-update.err >&2
      continue
    fi
    # pi update shells out to `npm update`, which respects the version spec the
    # package was installed under: a caret moves to the newest patch, but an
    # exact or major-pinned spec can't be moved at all. If the version didn't
    # change, install the target explicitly so this doesn't repeat every start.
    after="$(installed_version "$manifest")"
    if [ "$after" != "$to" ] && [ "${src#npm:}" != "$src" ]; then
      echo "  pi update left it on ${after:-unknown}; installing $to directly..."
      if ! (cd "$PI_CODING_AGENT_DIR/npm" \
            && npm install --legacy-peer-deps --no-audit --no-fund "${src#npm:}@$to") \
           >/dev/null 2>>/tmp/pi-update.err; then
        echo "Warning: updating $src failed; staying on ${after:-$from}:" >&2
        tail -n 3 /tmp/pi-update.err >&2
      fi
    fi
  done <<< "$OUTDATED"

  if [ -z "$MISSING" ] && [ -z "$OUTDATED" ]; then
    if [ "$UPDATES_CHECKED" = yes ]; then
      echo "all up to date: pi $(pi --version)"
      echo "pi packages: $PI_PACKAGES"
    else
      echo "pi packages: $PI_PACKAGES (update check skipped, PI_UPDATE_CHECK=${PI_UPDATE_CHECK:-always})"
    fi
  fi
fi

echo "in-image tools: pi $(/usr/local/bin/pi --version 2>/dev/null), $(rg --version 2>/dev/null | awk 'NR==1{print "ripgrep "$2}'), $(fdfind --version 2>/dev/null | awk 'NR==1{print "fd "$2}'), node $(node --version)"

# ---------------------------------------------------------------------------
# Proof of what is exposed, then hand off to pi.
# ---------------------------------------------------------------------------
echo "================================================================"
echo " PROOF: what pi can reach from inside this container"
echo "================================================================"
echo "Host folder mounted at /workspace (read-write):"
echo "  ${PI_SANDBOX_HOST_PROJECT:-the folder you ran ./run.sh from}"
echo ""
echo "No *host* files outside that folder are reachable. The container does have"
echo "its own root filesystem, /tmp and /proc — they just contain nothing of"
echo "yours. Outbound network (model server, internet) is open."
echo ""
TOTAL="$(find /workspace -maxdepth 2 2>/dev/null | wc -l | tr -d ' ')"
echo "Contents of /workspace (2 levels deep, $TOTAL entries, first 200):"
find /workspace -maxdepth 2 2>/dev/null | sort | head -n 200
echo "================================================================"
echo ""

exec pi "$@"
