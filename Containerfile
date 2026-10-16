FROM node:22-slim

# Pinned so the npm layer below is cacheable *and* updatable: bump this (or
# run ./run.sh with PI_VERSION=... ) to move pi forward. Without a pin the
# layer stays cached forever and silently runs an unknown old build.
ARG PI_VERSION=1.3.0

# Minimal system deps + network investigation tools + Python
# ripgrep: pi's grep tool uses rg when it is available.
# fd-find: pi's find tool shells out to `fd`, and PI_OFFLINE below stops pi from
#      downloading it on demand ("fd not found. Offline mode enabled, skipping
#      download"). Install it here instead. Debian names the package fd-find.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates ripgrep fd-find \
    curl wget nmap iputils-ping dnsutils netcat-openbsd traceroute \
    python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

# uv — fast Python package/venv manager, official static-binary install
# (recommended way to get uv into a Dockerfile, no curl-pipe-sh at build time)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Install pi (https://github.com/earendil-works/pi). --ignore-scripts keeps
# lifecycle scripts of pi's dependencies from running at build time, which is
# what pi's own containerization guide recommends.
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}"

# Entrypoint prints what's visible before starting pi (see entrypoint.sh)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Run as the non-root "node" user the base image already ships (UID 1000)
USER node
WORKDIR /workspace

# Fallback $HOME for when the project mount is not writable. entrypoint.sh
# overrides this with a folder under the (writable) project mount, so npm's
# and uv's caches survive between runs.
ENV HOME=/tmp

# Keep pi from phoning home on every start: model catalog refresh, latest
# version check, and install/update telemetry + provider attribution headers.
# The only provider here is the one declared in models.json, so the bundled
# catalog refresh buys nothing. All three can still be overridden by adding
# e.g. PI_TELEMETRY=1 to the sandbox's .env.
ENV PI_OFFLINE=1 \
    PI_SKIP_VERSION_CHECK=1 \
    PI_TELEMETRY=0

# pi packages (extensions/skills/prompts) entrypoint.sh makes sure are
# installed, space-separated: background shell tasks, a model-facing todo list,
# web search/fetch/PDF/video, the Feynman research agent, and a structured
# ask-the-user questionnaire. They land in the persistent data/agent dir, so the
# download happens once per project, not on every start. Set PI_PACKAGES in the
# config file to change the list — including PI_PACKAGES='' to install none.
ENV PI_PACKAGES="npm:pi-background-tasks npm:@juicesharp/rpiv-todo npm:pi-web-access npm:@companion-ai/feynman npm:@juicesharp/rpiv-ask-user-question"

# How entrypoint.sh keeps things current on every container start:
#   always  check npm for a newer pi and newer packages each start (default)
#   daily   at most one check per day, stamped in data/.last-update-check
#   never   install missing packages, otherwise change nothing
# A newer pi can't replace the image copy in place (the root filesystem is
# read-only), so it installs into data/pi-runtime and shadows it via PATH.
ENV PI_UPDATE_CHECK=always

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
