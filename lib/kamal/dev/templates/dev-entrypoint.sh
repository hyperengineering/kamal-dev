#!/bin/sh
# Kamal Dev entrypoint script
# Handles git cloning for remote deployments while preserving local devcontainer workflow

set -e

# Check if this is a kamal-dev remote deployment (env vars will be set)
if [ -n "$KAMAL_DEV_GIT_REPO" ]; then
  echo "[kamal-dev] Remote deployment detected"

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
