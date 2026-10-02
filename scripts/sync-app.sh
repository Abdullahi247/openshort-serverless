#!/usr/bin/env bash
set -euo pipefail

# Sync OpenShorts source into ./app for the Docker build.
# Usage: ./scripts/sync-app.sh /path/to/openshorts

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-}"

if [[ -z "$SRC" ]]; then
  echo "Usage: $0 /path/to/openshorts"
  exit 1
fi

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source directory not found: $SRC"
  exit 1
fi

if [[ ! -f "$SRC/requirements.txt" ]]; then
  echo "ERROR: $SRC/requirements.txt not found — is this the OpenShorts root?"
  exit 1
fi

DEST="$ROOT/app"
mkdir -p "$DEST"

echo "==> Syncing $SRC -> $DEST"
rsync -a --delete \
  --exclude '.git' \
  --exclude '.venv' \
  --exclude 'node_modules' \
  --exclude 'dashboard/node_modules' \
  --exclude 'remotion/node_modules' \
  --exclude 'render-service/node_modules' \
  --exclude '__pycache__' \
  --exclude '.DS_Store' \
  --exclude 'PLACE_SOURCE_HERE.md' \
  "$SRC"/ "$DEST"/

# Dashboard is not served on RunPod; drop it to shrink the image.
if [[ -d "$DEST/dashboard" ]]; then
  echo "==> Removing dashboard/ from image context (host frontend elsewhere)"
  rm -rf "$DEST/dashboard"
fi

echo "==> Done. Key paths:"
ls -la "$DEST" | head -30
echo ""
test -d "$DEST/remotion" && echo "OK remotion/" || echo "WARN: remotion/ missing"
test -d "$DEST/render-service" && echo "OK render-service/" || echo "WARN: render-service/ missing"
test -f "$DEST/requirements.txt" && echo "OK requirements.txt" || echo "WARN: requirements.txt missing"
