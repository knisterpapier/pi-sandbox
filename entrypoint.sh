#!/bin/bash
set -e

# Give pi a writable, ephemeral config dir (tmpfs, wiped on exit) and
# generate a provider entry for the model server from the PI_PROVIDER_*
# / PI_MODEL_ID / PI_CONTEXT_WINDOW / PI_MAX_TOKENS env vars run.sh passed
# in (sourced from pi-sandbox/.env). Nothing generated ever touches the repo.
export PI_CODING_AGENT_DIR="/tmp/pi-agent"
mkdir -p "$PI_CODING_AGENT_DIR"

if [ -n "$PI_PROVIDER_BASE_URL" ]; then
  {
    echo "{"
    echo "  \"providers\": {"
    echo "    \"sandbox\": {"
    echo "      \"baseUrl\": \"$PI_PROVIDER_BASE_URL\","
    echo "      \"api\": \"openai-completions\","
    # pi hides models with no apiKey from /model and --list-models, even
    # for servers that don't check it (e.g. Ollama/llama.cpp) — so always
    # send one, falling back to a placeholder when none was configured.
    echo "      \"apiKey\": \"${PI_PROVIDER_API_KEY:-sandbox}\","
    echo "      \"models\": [{"
    echo "        \"id\": \"${PI_MODEL_ID:-default}\","
    echo "        \"contextWindow\": ${PI_CONTEXT_WINDOW:-128000},"
    echo "        \"maxTokens\": ${PI_MAX_TOKENS:-4096}"
    echo "      }]"
    echo "    }"
    echo "  }"
    echo "}"
  } > "$PI_CODING_AGENT_DIR/models.json"

  {
    echo "{"
    echo "  \"defaultProvider\": \"sandbox\","
    echo "  \"defaultModel\": \"${PI_MODEL_ID:-default}\""
    echo "}"
  } > "$PI_CODING_AGENT_DIR/settings.json"
fi

echo "================================================================"
echo " PROOF: filesystem visible to pi inside this container"
echo "================================================================"
echo "Host folder mounted at /workspace (read-write)."
echo "Nothing outside /workspace exists in this container's view."
echo ""
echo "Contents (2 levels deep):"
find /workspace -maxdepth 2 | sort
echo "================================================================"
echo ""

exec pi "$@"
