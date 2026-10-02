# OpenShorts RunPod Serverless (Load Balancer / HTTP)
# Build for linux/amd64 — RunPod workers are x86_64 + NVIDIA GPU.
#
# Place your OpenShorts repo contents in ./app before building:
#   rsync -a --exclude dashboard --exclude .venv /path/to/openshorts/ ./app/
#
#   docker build --platform linux/amd64 -t YOUR_USER/openshorts-runpod:v1 .
#   docker push YOUR_USER/openshorts-runpod:v1

FROM nvidia/cuda:12.1.0-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    APP_DIR=/app \
    VENV=/app/.venv \
    NVM_DIR=/root/.nvm \
    DENO_INSTALL=/root/.deno \
    NODE_VERSION=20 \
    WHISPER_MODEL=large-v3-turbo \
    WHISPER_DEVICE=cuda \
    WHISPER_COMPUTE=float16 \
    FFMPEG_ENCODER=nvenc \
    NVIDIA_DRIVER_CAPABILITIES=compute,video,utility \
    NVIDIA_VISIBLE_DEVICES=all \
    PORT=80 \
    PORT_HEALTH=80 \
    HEALTH_CHECK_PATH=/ping \
    BACKEND_HOST=127.0.0.1 \
    BACKEND_PORT=8000 \
    RENDER_HOST=127.0.0.1 \
    RENDER_PORT=3100

WORKDIR /app

# --------------------------------------------------
# System packages
# --------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        wget \
        unzip \
        git \
        ffmpeg \
        nginx \
        ca-certificates \
        build-essential \
        python3 \
        python3-venv \
        python3-pip \
        python3-dev \
        fontconfig \
        fonts-liberation \
        fonts-noto-color-emoji \
        libgl1 \
        libglib2.0-0 \
        libsm6 \
        libxext6 \
        libxrender1 \
        gettext-base \
        # Remotion / Chromium headless deps
        libnss3 \
        libatk1.0-0 \
        libatk-bridge2.0-0 \
        libcups2 \
        libdrm2 \
        libxkbcommon0 \
        libxcomposite1 \
        libxdamage1 \
        libxfixes3 \
        libxrandr2 \
        libgbm1 \
        libasound2 \
        libpango-1.0-0 \
        libcairo2 \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default

# --------------------------------------------------
# Node.js 20 (no NVM — cleaner in containers)
# --------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && node --version && npm --version \
    && rm -rf /var/lib/apt/lists/*

# --------------------------------------------------
# Deno (kept for parity with your pod script)
# --------------------------------------------------
RUN curl -fsSL https://deno.land/install.sh | sh \
    && ln -sf /root/.deno/bin/deno /usr/local/bin/deno \
    && deno --version | head -1

# --------------------------------------------------
# App source (OpenShorts without dashboard)
# Copy requirements first so pip layers cache across code-only changes.
# --------------------------------------------------
COPY app/requirements.txt /app/requirements.txt
COPY app/requirements-billing.txt /app/requirements-billing.txt

# --------------------------------------------------
# Python deps (split layers + BuildKit pip cache)
# Split so a failed GPU wheel download does not redo torch.
# Cache mounts need BuildKit/buildx (see scripts/install-buildx.sh).
# GPU extras match upstream OpenShorts Dockerfile (faster-whisper /
# CTranslate2 need cuBLAS12+cuDNN9; Parakeet needs onnxruntime-gpu).
# --------------------------------------------------
ENV PIP_DEFAULT_TIMEOUT=1000 \
    PIP_RETRIES=20 \
    PIP_RESUME_RETRIES=100

RUN python3 -m venv "$VENV" \
    && . "$VENV/bin/activate" \
    && pip install --upgrade "pip>=25" setuptools wheel

RUN --mount=type=cache,target=/root/.cache/pip \
    . "$VENV/bin/activate" \
    && pip install --default-timeout=1000 --retries=20 --resume-retries=100 \
        -r /app/requirements.txt

RUN --mount=type=cache,target=/root/.cache/pip \
    . "$VENV/bin/activate" \
    && pip install --default-timeout=1000 --retries=20 --resume-retries=100 \
        -r /app/requirements-billing.txt

RUN --mount=type=cache,target=/root/.cache/pip \
    . "$VENV/bin/activate" \
    && pip install \
        --default-timeout=1000 \
        --retries=20 \
        --resume-retries=100 \
        "nvidia-cublas-cu12<13" \
        "nvidia-cudnn-cu12>=9,<10" \
        onnx-asr \
        onnxruntime-gpu

# Remaining app code (after deps so code edits don't bust pip layers)
COPY app/ /app/

# Point at pip-installed CUDA libs (cu12 for faster-whisper; cu13 may
# also exist from torch — both paths are fine if present).
ENV LD_LIBRARY_PATH=/app/.venv/lib/python3.10/site-packages/nvidia/cublas/lib:/app/.venv/lib/python3.10/site-packages/nvidia/cudnn/lib:/app/.venv/lib/python3.10/site-packages/nvidia/cuda_runtime/lib:/app/.venv/lib/python3.10/site-packages/nvidia/cu13/lib

# --------------------------------------------------
# Remotion project
# --------------------------------------------------
WORKDIR /app/remotion
RUN npm install \
    && npm install \
        remotion@4.0.518 \
        @remotion/bundler@4.0.518 \
        @remotion/renderer@4.0.518 \
        @remotion/media@4.0.518 \
    && npm run build

# --------------------------------------------------
# Render service
# --------------------------------------------------
WORKDIR /app/render-service
RUN npm install \
    && npm install \
        react@18.2.0 \
        react-dom@18.2.0 \
        remotion@4.0.518 \
        @remotion/bundler@4.0.518 \
        @remotion/renderer@4.0.518 \
    && npm run build

# --------------------------------------------------
# Nginx + entrypoint (public HTTP on $PORT for RunPod LB)
# --------------------------------------------------
WORKDIR /app
COPY docker/nginx.conf.template /etc/nginx/templates/openshorts.conf.template
COPY docker/entrypoint.sh /usr/local/bin/openshorts-entrypoint.sh
RUN chmod +x /usr/local/bin/openshorts-entrypoint.sh \
    && mkdir -p /run/nginx /var/log/openshorts \
    && rm -f /etc/nginx/sites-enabled/* /etc/nginx/conf.d/default.conf || true

EXPOSE 80

# RunPod load balancer polls GET /ping (200 = ready, 204 = still starting)
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT:-80}/ping" || exit 1

CMD ["/usr/local/bin/openshorts-entrypoint.sh"]
