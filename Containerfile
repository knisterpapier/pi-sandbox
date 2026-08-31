FROM node:22-slim

# Minimal system deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install pi (https://github.com/earendil-works/pi)
RUN npm install -g @earendil-works/pi-coding-agent

# Entrypoint prints what's visible before starting pi (see entrypoint.sh)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Run as the non-root "node" user the base image already ships (UID 1000)
USER node
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
