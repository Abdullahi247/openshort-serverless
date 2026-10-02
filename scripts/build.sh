#!/usr/bin/env bash
set -euo pipefail

# Build + optionally push the RunPod worker image.
# Usage:
#   ./scripts/build.sh /path/to/openshorts yourdockerhub/openshorts-runpod:v1
#   ./scripts/build.sh /path/to/openshorts yourdockerhub/openshorts-runpod:v1 --push

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-}"
IMAGE="${2:-}"
DO_PUSH="${3:-}"

if [[ -z "$SRC" || -z "$IMAGE" ]]; then
  echo "Usage: $0 /path/to/openshorts IMAGE_TAG [--push]"
  echo "Example: $0 ~/openshorts myuser/openshorts-runpod:v1 --push"
  exit 1
fi

"$ROOT/scripts/sync-app.sh" "$SRC"

if ! docker buildx version >/dev/null 2>&1; then
  echo "ERROR: docker buildx is missing (needed for BuildKit pip cache mounts)."
  echo "Install it with:"
  echo "  ./scripts/install-buildx.sh"
  exit 1
fi

echo "==> Building $IMAGE (linux/amd64, BuildKit)"
DOCKER_BUILDKIT=1 docker build --platform linux/amd64 -t "$IMAGE" "$ROOT"

if [[ "$DO_PUSH" == "--push" ]]; then
  echo "==> Pushing $IMAGE"
  docker push "$IMAGE"
fi

echo "==> Image ready: $IMAGE"
echo "Deploy on RunPod → Serverless → New Endpoint → Load Balancer"
echo "  Container image: $IMAGE"
echo "  Expose HTTP port: 80"
echo "  Health check path: /ping (default)"
