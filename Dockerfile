ARG BASE_IMAGE=runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04
FROM ${BASE_IMAGE}

ARG COMFYUI_REPO=https://github.com/Comfy-Org/ComfyUI.git
ARG COMFYUI_REF=v0.32.0

LABEL org.opencontainers.image.source="https://github.com/RyoheiTanaka/runpod-template-acestep15xl"

ENV DEBIAN_FRONTEND=noninteractive \
    COMFY_DIR=/opt/ComfyUI \
    HF_XET_HIGH_PERFORMANCE=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1

# openssh-server: CMD で公式イメージの entrypoint を置き換えるため、sshd は start.sh が起動する
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      curl \
      ca-certificates \
      ffmpeg \
      libgl1 \
      libglib2.0-0 \
      libsndfile1 \
      openssh-server \
    && mkdir -p /run/sshd \
    && rm -rf /var/lib/apt/lists/*

# ComfyUI の requirements.txt は torch / torchvision を裸で要求するため、pip がベースイメージの
# PyTorch を PyPI の既定ビルドで置き換えうる。CUDA ビルドが変わると壊れるので constraints で固定する。
#
# ただし torch だけ固定すると torchvision が PyPI から浮いてペアが崩れ、C++ 拡張が噛み合わずに
# `RuntimeError: operator torchvision::nms does not exist` で ComfyUI が起動しなくなる。
# cu130 ベースには torchvision が入っていないため、torch と同じ PyTorch index から先に入れておく。
#
# --depth 1 で全履歴の取得を避ける（ComfyUI の .git は数百MB になる）
RUN set -eu \
    && TORCH_CU="$(python -c 'import re, torch; m = re.search(r"\+(cu[0-9]+)", torch.__version__); print(m.group(1) if m else "")')" \
    && echo "base torch: $(python -c 'import torch; print(torch.__version__)') (index: ${TORCH_CU:-pypi})" \
    && python -m pip install --upgrade pip \
    && python -m pip freeze | grep -E '^(torch|torchaudio)==' > /opt/torch-constraints.txt \
    && test -s /opt/torch-constraints.txt \
    && if ! python -c 'import torchvision' >/dev/null 2>&1; then \
         if [ -n "${TORCH_CU}" ]; then \
           python -m pip install torchvision --index-url "https://download.pytorch.org/whl/${TORCH_CU}" -c /opt/torch-constraints.txt; \
         else \
           python -m pip install torchvision -c /opt/torch-constraints.txt; \
         fi; \
       fi \
    && python -m pip freeze | grep -E '^(torch|torchvision|torchaudio)==' > /opt/torch-constraints.txt \
    && cat /opt/torch-constraints.txt \
    && git clone --depth 1 --branch "${COMFYUI_REF}" "${COMFYUI_REPO}" "${COMFY_DIR}" \
    && cd "${COMFY_DIR}" \
    && python -m pip install huggingface_hub \
    && python -m pip install -r requirements.txt -c /opt/torch-constraints.txt \
    && python -c 'import torch, torchvision; print("after install:", torch.__version__, torchvision.__version__)' \
    && python -c 'import torchvision; torchvision.ops.nms' \
    && rm -rf /root/.cache/pip

COPY start.sh /opt/runpod/start.sh
COPY healthcheck.py /opt/runpod/healthcheck.py
RUN chmod +x /opt/runpod/start.sh

WORKDIR /workspace
EXPOSE 8188 8189 22
CMD ["/opt/runpod/start.sh"]
