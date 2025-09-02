# =========================
# Stage 1: Builder (compile custom ops only)
# =========================
FROM nvidia/cuda:12.4.1-devel-ubuntu22.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-dev python3-pip git build-essential cmake curl \
 && python3 -m pip install --upgrade pip \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN ln -s /usr/bin/python3 /usr/bin/python

WORKDIR /workspace
RUN git clone -b flymachine --single-branch --depth 1 https://github.com/ItsThatRandomDev/Hunyuan3D-2.1.git
WORKDIR /workspace/Hunyuan3D-2.1

# Install only what's needed to build wheels
RUN pip install --no-cache-dir pybind11 ninja wheel \
 && rm -rf /root/.cache/pip

# Build custom wheels
WORKDIR /workspace/Hunyuan3D-2.1/hy3dpaint/custom_rasterizer
RUN pip wheel . -w /wheels --no-deps || true

WORKDIR /workspace/Hunyuan3D-2.1/hy3dpaint/DifferentiableRenderer
RUN bash compile_mesh_painter.sh || true

# Save artifacts
WORKDIR /workspace/Hunyuan3D-2.1
RUN mkdir -p /artifacts/app \
 && cp -R . /artifacts/app \
 && rm -rf /artifacts/app/.git \
 && mkdir -p /artifacts/wheels \
 && cp /wheels/*.whl /artifacts/wheels/ || true

# =========================
# Stage 2: Ultra-Minimal Runtime
# =========================
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04 AS runtime

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip libgl1-mesa-glx libglib2.0-0 curl \
 && python3 -m pip install --upgrade pip \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV HUGGINGFACE_HUB_CACHE=/data/hf \
    TRANSFORMERS_CACHE=/data/hf \
    HF_HOME=/data/hf \
    TORCH_HOME=/data/torch \
    HY3DGEN_CACHE=/data/hy3dgen \
    PIP_CACHE_DIR=/data/pip-cache \
    PYTHONPATH=/data/python-packages \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:512 \
    CUDA_LAUNCH_BLOCKING=0

WORKDIR /app
COPY --from=builder /artifacts/app /app
COPY --from=builder /artifacts/wheels /wheels
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Only install pip requirements file - no actual packages to keep image tiny
# All dependencies will be installed at runtime and cached in /data volume

CMD ["/entrypoint.sh"]