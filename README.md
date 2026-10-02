# OpenShorts → RunPod Serverless (HTTP / Load Balancer)

Drop-in Docker worker for your GPU API + Remotion renderer.
The dashboard is **not** included — host the frontend elsewhere and call this endpoint over HTTP.

You only pay while workers are up (idle scale-to-zero), instead of an always-on GPU pod.

## What runs in the container

| Process | Internal | Public (via nginx on `$PORT`) |
|---------|----------|-------------------------------|
| FastAPI (`uvicorn app:app`) | `:8000` | `/`, `/api/`, `/health` |
| Remotion `render-service` | `:3100` | `/render/` |
| Health for RunPod LB | — | `/ping` (`204` starting → `200` ready) |

Same GPU defaults as your pod script: Whisper `large-v3-turbo` on CUDA, FFmpeg `nvenc`.

## Layout

```
openshorts-runpod/
  Dockerfile
  docker/
    entrypoint.sh
    nginx.conf.template
  scripts/
    sync-app.sh      # copy OpenShorts source into ./app
    build.sh         # sync + docker build (+ optional push)
  app/               # filled by sync-app.sh (gitignored)
```

## 1. Build the image

You need Docker Hub (or any registry) credentials, and your OpenShorts repo locally (or on the machine you build from).

```bash
cd ~/Desktop/openshorts-runpod
chmod +x scripts/*.sh docker/entrypoint.sh

# sync + build
./scripts/build.sh /path/to/openshorts YOUR_DOCKERHUB_USER/openshorts-runpod:v1

# or sync + build + push
./scripts/build.sh /path/to/openshorts YOUR_DOCKERHUB_USER/openshorts-runpod:v1 --push
```

Must target **linux/amd64** (RunPod). Building on Apple Silicon already passes `--platform linux/amd64`.

### Build with GitHub Actions (recommended if local/Mac is slow)

1. Push this repo to GitHub.
2. In the repo: **Settings → Secrets and variables → Actions**, add:
   - `DOCKERHUB_USERNAME` — e.g. `yusufabdullah`
   - `DOCKERHUB_TOKEN` — Docker Hub **access token** (Read & Write)
3. Open **Actions → Build and push Runpod image → Run workflow**
4. Optional: set image tag (default `v1`)

The workflow clones [mutonby/openshorts](https://github.com/mutonby/openshorts), syncs into `app/`, builds for `linux/amd64`, and pushes:

```text
DOCKERHUB_USERNAME/openshorts-runpod:v1
```

First run can take a long time (torch + CUDA wheels). Subsequent runs reuse GitHub/Docker layer caches when possible.

## 2. Deploy on RunPod

1. [Serverless](https://www.runpod.io/console/serverless) → **New Endpoint**
2. **Import from Docker Registry** → `YOUR_DOCKERHUB_USER/openshorts-runpod:v1`
3. **Endpoint Type: Load Balancer** (not queue/handler)
4. Pick a GPU that fits Whisper + Remotion (start around 24GB+ VRAM if you use `large-v3-turbo`)
5. Container settings:
   - **Expose HTTP Ports:** `80`
   - Health check path: `/ping` (default)
6. Optional env vars (override defaults):

| Variable | Default | Notes |
|----------|---------|--------|
| `PORT` | `80` | RunPod public port — keep 80 unless you change expose |
| `WHISPER_MODEL` | `large-v3-turbo` | |
| `WHISPER_DEVICE` | `cuda` | |
| `WHISPER_COMPUTE` | `float16` | |
| `FFMPEG_ENCODER` | `nvenc` | |
| `NVIDIA_DRIVER_CAPABILITIES` | `compute,video,utility` | needed for NVENC |

7. Deploy.

Your base URL:

```
https://ENDPOINT_ID.api.runpod.ai
```

Examples:

```bash
curl -s https://ENDPOINT_ID.api.runpod.ai/ping
curl -s https://ENDPOINT_ID.api.runpod.ai/health/ready
# your existing API routes:
curl -s https://ENDPOINT_ID.api.runpod.ai/api/...
```

Cold start tip: if you get `no workers available`, retry — first boot installs/warms GPU paths and can take a while. Keep max workers ≥ 1 only if you need always-warm; otherwise scale-to-zero saves money.

## 3. Point the frontend elsewhere

On Vercel / Netlify / Cloudflare / etc., set your API base URL to the RunPod endpoint, e.g.:

```
VITE_API_BASE=https://ENDPOINT_ID.api.runpod.ai
```

If the browser calls the API directly, enable CORS on FastAPI for your frontend origin (in the OpenShorts app code).

## Local smoke test (optional)

```bash
./scripts/sync-app.sh /path/to/openshorts
docker build --platform linux/amd64 -t openshorts-runpod:local .
docker run --rm --gpus all -p 8080:80 openshorts-runpod:local

curl -i http://127.0.0.1:8080/ping
```

Needs an NVIDIA GPU + Container Toolkit on the host. On a Mac you can only build/push; run the image on RunPod or a Linux GPU box.

## vs your old one-shot script

| Old pod script | This image |
|----------------|------------|
| Always-on GPU machine | Serverless workers, idle → $0 |
| Nginx :8080 + PM2 + dashboard :5173 | Nginx :$PORT, no dashboard, no PM2 |
| Node via NVM | Node 20 from NodeSource |
| Manual `apt` + sync on the pod | One Docker image you push |

## Next steps after first deploy

1. Sync real OpenShorts into `app/` and build.
2. Confirm `/ping` → 200 and `/health/ready` on the endpoint.
3. Wire the hosted dashboard to `https://ENDPOINT_ID.api.runpod.ai`.
4. Tune RunPod **idle timeout** / **max workers** for cost vs cold starts.
