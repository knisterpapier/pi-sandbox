#!/bin/bash
set -e

# This script's own folder (the tooling subfolder, e.g. "pi-sandbox")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The parent folder = your actual project
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

IMAGE_NAME="pi-sandbox"

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

if [ ! -f "$SCRIPT_DIR/.env" ]; then
  echo "No .env file found in $SCRIPT_DIR. Lets fetz up your model server."
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

  {
    echo "PI_PROVIDER_BASE_URL=$PI_PROVIDER_BASE_URL"
    [ -n "$PI_PROVIDER_API_KEY" ] && echo "PI_PROVIDER_API_KEY=$PI_PROVIDER_API_KEY"
    echo "PI_MODEL_ID=$PI_MODEL_ID"
    echo "PI_CONTEXT_WINDOW=$PI_CONTEXT_WINDOW"
    echo "PI_MAX_TOKENS=$PI_MAX_TOKENS"
  } > "$SCRIPT_DIR/.env"

  echo "Wrote $SCRIPT_DIR/.env (delete it and re-run to change these)"
  echo ""
fi

set -a
source "$SCRIPT_DIR/.env"
set +a

if [[ "$1" != "--no-build" ]]; then
  podman build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"
fi

echo "Mounting project root: $PROJECT_ROOT -> /workspace"

podman run --rm -it \
  --userns=keep-id \
  --security-opt=no-new-privileges \
  --cap-drop=ALL \
  --read-only \
  --tmpfs /tmp \
  -v "$PROJECT_ROOT:/workspace:Z" \
  -e PI_PROVIDER_BASE_URL \
  -e PI_PROVIDER_API_KEY \
  -e PI_MODEL_ID \
  -e PI_CONTEXT_WINDOW \
  -e PI_MAX_TOKENS \
  "$IMAGE_NAME"
