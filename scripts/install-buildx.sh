#!/usr/bin/env bash
set -euo pipefail

# Install Docker Buildx CLI plugin into ~/.docker/cli-plugins
# (needed for BuildKit pip cache mounts on Colima / Docker Engine installs)

PLUGIN_DIR="${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins"
mkdir -p "$PLUGIN_DIR"

ARCH="$(uname -m)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

case "$ARCH" in
  arm64|aarch64) BX_ARCH=arm64 ;;
  x86_64|amd64) BX_ARCH=amd64 ;;
  *)
    echo "Unsupported CPU arch: $ARCH"
    exit 1
    ;;
esac

case "$OS" in
  darwin|linux) ;;
  *)
    echo "Unsupported OS: $OS"
    exit 1
    ;;
esac

VERSION="${BUILDX_VERSION:-v0.29.1}"
URL="https://github.com/docker/buildx/releases/download/${VERSION}/buildx-${VERSION}.${OS}-${BX_ARCH}"
DEST="$PLUGIN_DIR/docker-buildx"

echo "==> Installing docker-buildx ${VERSION} (${OS}/${BX_ARCH})"
echo "    -> $DEST"
curl -fsSL -o "$DEST" "$URL"
chmod +x "$DEST"

echo "==> Verifying"
docker buildx version

echo ""
echo "==> Done. Rebuild with:"
echo "    ./scripts/build.sh ~/Desktop/openshorts yusufabdullah/openshorts-runpod:v1 --push"
