#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_PORT="${COMFY_PORT:-${PORT:-8188}}"
# Default to the smallest usable pair rather than everything. "all" is three
# diffusion models and three encoders, which does not fit the 50GB container
# disk this listing asks for, and nothing sets these when the image is run
# directly or deployed somewhere that does not apply the listing's inputs.
ACESTEP_XL_VARIANT="${ACESTEP_XL_VARIANT:-xl_turbo}"
ACESTEP_LM="${ACESTEP_LM:-qwen_0.6b}"
COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
OUTPUT_DIR="${OUTPUT_DIR:-${WORKSPACE}/outputs}"
MODEL_ROOT="${WORKSPACE}/models/acestep15xl"
LOG_DIR="${WORKSPACE}/logs"
HF_HOME="${HF_HOME:-${WORKSPACE}/.cache/huggingface}"

export HF_HOME
export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"

mkdir -p "${MODEL_ROOT}" "${LOG_DIR}" "${OUTPUT_DIR}"
exec > >(tee -a "${LOG_DIR}/start_acestep15xl_$(date +%Y%m%d_%H%M%S).log") 2>&1

echo "[start] start: $(date -Iseconds)"
echo "[start] workspace: ${WORKSPACE}"
echo "[start] ComfyUI: ${COMFY_DIR}"
echo "[start] output: ${OUTPUT_DIR}"
echo "[start] ACE-Step XL variant: ${ACESTEP_XL_VARIANT}"
echo "[start] ACE-Step LM: ${ACESTEP_LM}"

# モデル download 中は ComfyUI がまだ起動しておらず、health check は「起動中」ではなく
# 「不健全」に見える。専用ポートを立てればその区別を 204 で伝えられるが、Hub の listing は
# 公開ポートを宣言できず PORT しか到達しないため、既定では立てない。
# PORT_HEALTH が明示され、かつ ComfyUI と別ポートのときだけ起動する。
# 同じポートを指定されたら、先に bind した側が ComfyUI の起動を妨げるので拒否する。
if [ -n "${PORT_HEALTH:-}" ] && [ -f /opt/runpod/healthcheck.py ]; then
  if [ "${PORT_HEALTH}" = "${COMFY_PORT}" ]; then
    echo "[start] PORT_HEALTH equals COMFY_PORT (${COMFY_PORT}), not starting the health check server"
    echo "[start] point HEALTH_CHECK_PATH at ComfyUI's own /system_stats instead"
  else
    COMFY_PORT="${COMFY_PORT}" PORT_HEALTH="${PORT_HEALTH}" \
      python /opt/runpod/healthcheck.py &
    echo "[start] health check: listening on 0.0.0.0:${PORT_HEALTH}"
  fi
fi

if [ "${HF_TOKEN:-}" = "your-huggingface-token" ]; then
  echo "[start] HF_TOKEN is a placeholder, ignoring it"
  unset HF_TOKEN
fi

# CMD で公式イメージの entrypoint を置き換えているため、PUBLIC_KEY を authorized_keys へ
# 展開して sshd を起動する処理はこの script が持つ必要がある。
# exec でプロセスが置き換わるので、必ず末尾の exec より前に実行すること。
start_sshd() {
  if [ -z "${PUBLIC_KEY:-}" ]; then
    echo "[start] PUBLIC_KEY is empty, skip sshd"
    return
  fi

  mkdir -p /root/.ssh /run/sshd
  chmod 700 /root/.ssh
  # RunPod が渡す PUBLIC_KEY を正とし、再起動のたびに上書きする（追記だと重複が溜まる）
  printf '%s\n' "${PUBLIC_KEY}" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys

  mkdir -p /etc/ssh/sshd_config.d
  printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\n' \
    > /etc/ssh/sshd_config.d/runpod.conf

  ssh-keygen -A
  /usr/sbin/sshd
  echo "[start] sshd started"
}

# sshd が起動できなくても ComfyUI は動かす
start_sshd || echo "[start] warning: failed to start sshd"

download_model() {
  local include_pattern="$1"
  local source="${MODEL_ROOT}/comfy-files/${include_pattern}"

  if [ -f "${source}" ]; then
    echo "[start] model already exists: ${include_pattern}"
    return
  fi

  echo "[start] downloading ${include_pattern}"
  hf download Comfy-Org/ace_step_1.5_ComfyUI_files \
    --include "${include_pattern}" \
    --local-dir "${MODEL_ROOT}/comfy-files"
}

install_from_split_files() {
  local category="$1"
  local filename="$2"
  local source="${MODEL_ROOT}/comfy-files/split_files/${category}/${filename}"
  local target_dir="${COMFY_DIR}/models/${category}"

  mkdir -p "${target_dir}"
  if [ ! -f "${source}" ]; then
    echo "[start] error: missing downloaded model file: ${source}"
    exit 1
  fi
  ln -sfn "${source}" "${target_dir}/${filename}"
}

case "${ACESTEP_XL_VARIANT}" in
  xl_base)
    DIFFUSION_MODELS=("acestep_v1.5_xl_base_bf16.safetensors")
    ;;
  xl_sft)
    DIFFUSION_MODELS=("acestep_v1.5_xl_sft_bf16.safetensors")
    ;;
  xl_turbo)
    DIFFUSION_MODELS=("acestep_v1.5_xl_turbo_bf16.safetensors")
    ;;
  all)
    DIFFUSION_MODELS=(
      "acestep_v1.5_xl_base_bf16.safetensors"
      "acestep_v1.5_xl_sft_bf16.safetensors"
      "acestep_v1.5_xl_turbo_bf16.safetensors"
    )
    ;;
  *)
    echo "[start] error: unsupported ACESTEP_XL_VARIANT=${ACESTEP_XL_VARIANT}. Use xl_base, xl_sft, xl_turbo, or all."
    exit 2
    ;;
esac

case "${ACESTEP_LM}" in
  qwen_0.6b)
    TEXT_ENCODERS=("qwen_0.6b_ace15.safetensors")
    ;;
  qwen_1.7b)
    TEXT_ENCODERS=("qwen_1.7b_ace15.safetensors")
    ;;
  qwen_4b)
    TEXT_ENCODERS=("qwen_4b_ace15.safetensors")
    ;;
  all)
    TEXT_ENCODERS=(
      "qwen_0.6b_ace15.safetensors"
      "qwen_1.7b_ace15.safetensors"
      "qwen_4b_ace15.safetensors"
    )
    ;;
  *)
    echo "[start] error: unsupported ACESTEP_LM=${ACESTEP_LM}. Use qwen_0.6b, qwen_1.7b, qwen_4b, or all."
    exit 2
    ;;
esac

for diffusion_model in "${DIFFUSION_MODELS[@]}"; do
  download_model "split_files/diffusion_models/${diffusion_model}"
  install_from_split_files "diffusion_models" "${diffusion_model}"
done

for text_encoder in "${TEXT_ENCODERS[@]}"; do
  download_model "split_files/text_encoders/${text_encoder}"
  install_from_split_files "text_encoders" "${text_encoder}"
done

download_model "split_files/vae/ace_1.5_vae.safetensors"
install_from_split_files "vae" "ace_1.5_vae.safetensors"

# ComfyUI と comfy-aimdo はホストの RAM を見ており、コンテナに与えられた上限を見ない。
# ホストが大きくコンテナの取り分が小さい環境では、2本目のモデルを積んだ時点で pinned memory が
# コンテナ上限を超え、traceback を出さずに OOM kill される（コンテナごと再起動する）。
# cgroup から実際の上限を読み、ホスト RAM より明らかに小さければ pinned memory を切る。
#
# COMFY_PINNED_MEMORY=auto（既定）/ on（常に使う）/ off（常に切る）で上書きできる。
container_memory_limit_bytes() {
  local limit=""
  if [ -r /sys/fs/cgroup/memory.max ]; then
    limit="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)"
  elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    limit="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)"
  fi
  case "${limit}" in
    "" | max | *[!0-9]*) return 1 ;;
  esac
  echo "${limit}"
}

host_memory_bytes() {
  local kb
  kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || true)"
  case "${kb}" in
    "" | *[!0-9]*) return 1 ;;
  esac
  echo $((kb * 1024))
}

COMFY_ARGS=(--listen 0.0.0.0 --port "${COMFY_PORT}" --output-directory "${OUTPUT_DIR}")

pinned_mode="${COMFY_PINNED_MEMORY:-auto}"
if [ "${pinned_mode}" = "off" ]; then
  echo "[start] COMFY_PINNED_MEMORY=off, disabling pinned memory"
  COMFY_ARGS+=(--disable-pinned-memory)
elif [ "${pinned_mode}" = "auto" ]; then
  if limit_b="$(container_memory_limit_bytes)" && host_b="$(host_memory_bytes)"; then
    host_gb=$((host_b / 1024 / 1024 / 1024))
    # cgroup v2 は「上限なし」を max ではなく巨大な数値で返すことがあり、その場合
    # 上の max 判定を素通りする。ホスト RAM 以上の上限は実質「上限なし」なので、
    # 桁の狂った GB を表示せずにそう扱う。
    if [ "${limit_b}" -ge "${host_b}" ]; then
      echo "[start] memory: no container limit / host ${host_gb}GB"
    else
      limit_gb=$((limit_b / 1024 / 1024 / 1024))
      echo "[start] memory: container limit ${limit_gb}GB / host ${host_gb}GB"
      # 上限がホストの 80% 未満なら、ComfyUI が見ている値は実態より大きい
      if [ "${limit_b}" -lt $((host_b / 10 * 8)) ]; then
        echo "[start] container limit is well below host RAM, disabling pinned memory"
        echo "[start] set COMFY_PINNED_MEMORY=on to keep it enabled"
        COMFY_ARGS+=(--disable-pinned-memory)
      fi
    fi
  else
    echo "[start] memory: could not read the container limit, leaving pinned memory as-is"
  fi
fi

# 追加の ComfyUI 引数を環境変数から渡せるようにする（--lowvram, --fast-disk, --cache-none など）。
# 意図的に単語分割する。
if [ -n "${COMFY_EXTRA_ARGS:-}" ]; then
  echo "[start] extra args: ${COMFY_EXTRA_ARGS}"
  # shellcheck disable=SC2206
  COMFY_ARGS+=(${COMFY_EXTRA_ARGS})
fi

echo "[start] ready: ComfyUI will listen on 0.0.0.0:${COMFY_PORT}"
echo "[start] args: ${COMFY_ARGS[*]}"
cd "${COMFY_DIR}"

# ComfyUI は背景に回し、web UI を出したまま handler を前面に置く。同じイメージが
# Pod（ブラウザで ComfyUI）でも Serverless（キュー API）でも成立する。
python main.py "${COMFY_ARGS[@]}" &
COMFY_PID=$!

# handler は Serverless の環境でしか意味を持たない。Pod で起動した場合は
# runpod SDK がすぐ抜けるので、そのまま ComfyUI を待ち続ける。
# handler の失敗で Pod を落とさないよう、戻り値は無視する。
if [ -f /opt/runpod/handler.py ]; then
  echo "[start] starting the serverless handler"
  # runpod SDK は /opt/runpod/pylibs に分離してある（Dockerfile の説明を参照）
  if PYTHONPATH=/opt/runpod/pylibs python /opt/runpod/handler.py; then
    echo "[start] handler returned cleanly"
  elif [ -n "${RUNPOD_ENDPOINT_ID:-}" ]; then
    # On Serverless the handler is the worker: it is what registers with the
    # job queue and reports this container's existence. If it dies, Runpod
    # sees an endpoint that never fills any worker, with no clue why -- which
    # is exactly how a missing `runpod` package hid for several releases.
    # Fail the container so the failure is visible instead of silent.
    echo "[start] error: handler failed on a Serverless worker (RUNPOD_ENDPOINT_ID=${RUNPOD_ENDPOINT_ID})"
    exit 1
  else
    # On a Pod there is no job queue to join, so the handler exiting is
    # expected. ComfyUI is already up and is the thing being used here.
    echo "[start] handler exited; not a Serverless worker, continuing to serve ComfyUI"
  fi
fi

wait "${COMFY_PID}"
