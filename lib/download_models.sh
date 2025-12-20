#!/usr/bin/env bash
set -euo pipefail

COMFY_HOME="${COMFY_HOME:-/workspace/ComfyUI}"

DIT_PATH="$COMFY_HOME/models/diffusion_models/hunyuan3d-dit-v2-1.ckpt"
VAE_PATH="$COMFY_HOME/models/vae/hunyuan3d-vae-v2-1.ckpt"

mkdir -p "$(dirname "$DIT_PATH")" "$(dirname "$VAE_PATH")"

DIT_URL_DEFAULT="https://huggingface.co/tencent/Hunyuan3D-2.1/resolve/main/hunyuan3d-dit-v2-1/model.fp16.ckpt"
VAE_URL_DEFAULT="https://huggingface.co/tencent/Hunyuan3D-2.1/resolve/main/hunyuan3d-vae-v2-1/model.fp16.ckpt"

DIT_URL="${HUNYUAN_DIT_URL:-$DIT_URL_DEFAULT}"
VAE_URL="${HUNYUAN_VAE_URL:-$VAE_URL_DEFAULT}"

if [[ ! -f "$DIT_PATH" ]]; then
  echo "[hunyuan3d] Downloading DIT checkpoint..."
  curl -L "$DIT_URL" -o "$DIT_PATH"
else
  echo "[hunyuan3d] DIT checkpoint already present."
fi

if [[ ! -f "$VAE_PATH" ]]; then
  echo "[hunyuan3d] Downloading VAE checkpoint..."
  curl -L "$VAE_URL" -o "$VAE_PATH"
else
  echo "[hunyuan3d] VAE checkpoint already present."
fi

echo "[hunyuan3d] Model download done."
