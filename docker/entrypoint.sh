#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/app}"
VENV="${VENV:-$APP_DIR/.venv}"
BACKEND_HOST="${BACKEND_HOST:-127.0.0.1}"
BACKEND_PORT="${BACKEND_PORT:-8000}"
RENDER_HOST="${RENDER_HOST:-127.0.0.1}"
RENDER_PORT="${RENDER_PORT:-3100}"
PORT="${PORT:-80}"
READY_FILE="/tmp/openshorts_ready"

rm -f "$READY_FILE"

export PATH="$VENV/bin:/root/.deno/bin:$PATH"
export WHISPER_MODEL="${WHISPER_MODEL:-large-v3-turbo}"
export WHISPER_DEVICE="${WHISPER_DEVICE:-cuda}"
export WHISPER_COMPUTE="${WHISPER_COMPUTE:-float16}"
export FFMPEG_ENCODER="${FFMPEG_ENCODER:-nvenc}"
export NVIDIA_DRIVER_CAPABILITIES="${NVIDIA_DRIVER_CAPABILITIES:-compute,video,utility}"

echo "=========================================="
echo " OpenShorts RunPod HTTP worker"
echo " Public port: $PORT"
echo " FastAPI:     ${BACKEND_HOST}:${BACKEND_PORT}"
echo " Renderer:    ${RENDER_HOST}:${RENDER_PORT}"
echo "=========================================="

# --------------------------------------------------
# Render nginx config from template (PORT is dynamic on RunPod)
# --------------------------------------------------
envsubst '${PORT} ${BACKEND_HOST} ${BACKEND_PORT} ${RENDER_HOST} ${RENDER_PORT}' \
    < /etc/nginx/templates/openshorts.conf.template \
    > /etc/nginx/conf.d/openshorts.conf

# Strip default site if present
rm -f /etc/nginx/sites-enabled/default || true

nginx -t
nginx

cleanup() {
    echo "==> Shutting down..."
    kill "$BACKEND_PID" 2>/dev/null || true
    kill "$RENDER_PID" 2>/dev/null || true
    nginx -s quit 2>/dev/null || true
    wait || true
}
trap cleanup EXIT INT TERM

# --------------------------------------------------
# FastAPI (internal)
# --------------------------------------------------
echo "==> Starting FastAPI..."
cd "$APP_DIR"
"$VENV/bin/python" -m uvicorn app:app \
    --host "$BACKEND_HOST" \
    --port "$BACKEND_PORT" \
    --log-level info &
BACKEND_PID=$!

# --------------------------------------------------
# Remotion render-service (internal)
# --------------------------------------------------
echo "==> Starting Remotion renderer..."
cd "$APP_DIR/render-service"
npm start &
RENDER_PID=$!

# --------------------------------------------------
# Wait until FastAPI is ready, then flip /ping to 200
# --------------------------------------------------
echo "==> Waiting for FastAPI health..."
for i in $(seq 1 120); do
    if curl -fsS "http://${BACKEND_HOST}:${BACKEND_PORT}/health/ready" >/dev/null 2>&1 \
        || curl -fsS "http://${BACKEND_HOST}:${BACKEND_PORT}/health" >/dev/null 2>&1 \
        || curl -fsS "http://${BACKEND_HOST}:${BACKEND_PORT}/docs" >/dev/null 2>&1; then
        touch "$READY_FILE"
        echo "==> Worker ready (attempt $i)"
        break
    fi
    if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
        echo "ERROR: FastAPI exited before becoming healthy"
        exit 1
    fi
    sleep 2
done

if [ ! -f "$READY_FILE" ]; then
    echo "ERROR: Timed out waiting for FastAPI"
    exit 1
fi

echo "==> Listening on :$PORT (RunPod load balancer)"
echo "    /ping          -> health (204 starting / 200 ready)"
echo "    /api/*         -> FastAPI"
echo "    /health*       -> FastAPI"
echo "    /render/*      -> Remotion render-service"
echo "    /*             -> FastAPI"

# Keep container alive while children run
wait -n "$BACKEND_PID" "$RENDER_PID"
echo "ERROR: a worker process exited"
exit 1
