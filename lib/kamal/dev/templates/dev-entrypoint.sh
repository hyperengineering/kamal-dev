#!/bin/sh
# Kamal Dev entrypoint script
# Handles git cloning for remote deployments while preserving local devcontainer workflow

set -e

# Check if this is a kamal-dev remote deployment (env vars will be set)
if [ -n "$KAMAL_DEV_GIT_REPO" ]; then
  echo "[kamal-dev] Remote deployment detected"

  # Setup SSH keys if provided (for private repositories)
  if [ -n "$KAMAL_DEV_SSH_KEY" ]; then
    echo "[kamal-dev] Setting up SSH keys for git clone"
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    # Write SSH key to file (use printf to preserve newlines)
    printf '%s\n' "$KAMAL_DEV_SSH_KEY" > ~/.ssh/id_rsa
    chmod 600 ~/.ssh/id_rsa

    # Configure SSH to skip host key verification (for automated deployments)
    # In production, you might want to use known_hosts instead
    cat > ~/.ssh/config <<EOF
Host github.com
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF
    chmod 600 ~/.ssh/config

    echo "[kamal-dev] SSH keys configured"
  fi

  # Clone repository if not already present
  if [ ! -d "$KAMAL_DEV_WORKSPACE_FOLDER/.git" ]; then
    echo "[kamal-dev] Cloning $KAMAL_DEV_GIT_REPO (branch: $KAMAL_DEV_GIT_BRANCH)"
    mkdir -p "$KAMAL_DEV_WORKSPACE_FOLDER"
    git clone --depth 1 --branch "$KAMAL_DEV_GIT_BRANCH" "$KAMAL_DEV_GIT_REPO" "$KAMAL_DEV_WORKSPACE_FOLDER"
    echo "[kamal-dev] Clone complete: $KAMAL_DEV_WORKSPACE_FOLDER"
  else
    echo "[kamal-dev] Repository already cloned at $KAMAL_DEV_WORKSPACE_FOLDER"
    # Optionally pull latest changes
    # cd "$KAMAL_DEV_WORKSPACE_FOLDER" && git pull
  fi
else
  echo "[kamal-dev] Local development mode (using mounted code)"
fi

# Execute the original command (CMD from Dockerfile or docker-compose)
exec "$@"
