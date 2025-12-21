#!/bin/bash
set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${WORKSPACE_DIR}/ComfyUI"
MODELS_DIR="${COMFYUI_DIR}/models"
CUSTOM_NODES_DIR="${COMFYUI_DIR}/custom_nodes"

HF_SEMAPHORE_DIR="${WORKSPACE_DIR}/hf_download_sem_$$"
HF_MAX_PARALLEL=3
MODEL_LOG=${MODEL_LOG:-/var/log/portal/comfyui.log}

# Model declarations: "URL|OUTPUT_PATH"
HF_MODELS=(
  "https://huggingface.co/Kijai/Hunyuan3D-2_safetensors/resolve/main/hunyuan3d-dit-v2-0-fp16.safetensors|$MODELS_DIR/diffusion_models/hunyuan3d-dit-v2-0-fp16.safetensors"
)
### End Configuration ###

script_cleanup() { rm -rf "$HF_SEMAPHORE_DIR"; }

# If this script fails we cannot let a serverless worker be marked as ready.
script_error() {
  local exit_code=$?
  local line_number=$1
  echo "[ERROR] Provisioning Script failed at line $line_number with exit code $exit_code" | tee -a "$MODEL_LOG"
}

trap script_cleanup EXIT
trap 'script_error $LINENO' ERR

main() {
  . /venv/main/bin/activate

  set_cleanup_job
  mkdir -p "$HF_SEMAPHORE_DIR"

  install_custom_nodes
  write_workflow

  pids=()
  # Download all models in parallel
  for model in "${HF_MODELS[@]}"; do
    url="${model%%|*}"
    output_path="${model##*|}"
    download_hf_file "$url" "$output_path" & pids+=($!)
  done

  # Wait for each job and check exit status
  for pid in "${pids[@]}"; do
    wait "$pid" || exit 1
  done
}

install_custom_nodes() {
  mkdir -p "$CUSTOM_NODES_DIR"
  cd "$CUSTOM_NODES_DIR"

  # Hunyuan3D Wrapper
  if [[ ! -d "$CUSTOM_NODES_DIR/ComfyUI-Hunyuan3DWrapper" ]]; then
    git clone https://github.com/kijai/ComfyUI-Hunyuan3DWrapper.git --recursive
  fi
  if [[ "${AUTO_UPDATE,,}" != "false" ]]; then
    ( cd "$CUSTOM_NODES_DIR/ComfyUI-Hunyuan3DWrapper" && git pull ) || true
  fi
  if [[ -f "$CUSTOM_NODES_DIR/ComfyUI-Hunyuan3DWrapper/requirements.txt" ]]; then
    pip install --no-cache-dir -r "$CUSTOM_NODES_DIR/ComfyUI-Hunyuan3DWrapper/requirements.txt"
  fi

  # Essentials (nodes ImageResize+, TransparentBGSession+, etc.)
  if [[ ! -d "$CUSTOM_NODES_DIR/ComfyUI_essentials" ]]; then
    git clone https://github.com/cubiq/ComfyUI_essentials.git --recursive
  fi
  if [[ "${AUTO_UPDATE,,}" != "false" ]]; then
    ( cd "$CUSTOM_NODES_DIR/ComfyUI_essentials" && git pull ) || true
  fi
  if [[ -f "$CUSTOM_NODES_DIR/ComfyUI_essentials/requirements.txt" ]]; then
    pip install --no-cache-dir -r "$CUSTOM_NODES_DIR/ComfyUI_essentials/requirements.txt"
  fi
}

# HuggingFace download helper (same pattern as WAN: semaphore + per-file lock + retry/backoff) :contentReference[oaicite:1]{index=1}
download_hf_file() {
  local url="$1"
  local output_path="$2"
  local lockfile="${output_path}.lock"
  local max_retries=5
  local retry_delay=2

  # Acquire slot for parallel download limiting
  local slot
  slot=$(acquire_slot)

  # Acquire lock for this specific file
  while ! mkdir "$lockfile" 2>/dev/null; do
    echo "Another process is downloading to $output_path (waiting...)" | tee -a "$MODEL_LOG"
    sleep 1
  done

  # Check if file already exists
  if [ -f "$output_path" ]; then
    echo "File already exists: $output_path (skipping)" | tee -a "$MODEL_LOG"
    rmdir "$lockfile"
    release_slot "$slot"
    return 0
  fi

  # Extract repo and file path
  local repo
  repo=$(echo "$url" | sed -n 's|https://huggingface.co/\([^/]*/[^/]*\)/resolve/.*|\1|p')
  local file_path
  file_path=$(echo "$url" | sed -n 's|https://huggingface.co/[^/]*/[^/]*/resolve/[^/]*/\(.*\)|\1|p')

  if [ -z "$repo" ] || [ -z "$file_path" ]; then
    echo "ERROR: Invalid HuggingFace URL: $url" | tee -a "$MODEL_LOG"
    rmdir "$lockfile"
    release_slot "$slot"
    return 1
  fi

  local temp_dir
  temp_dir=$(mktemp -d)
  local attempt=1

  # Retry loop for rate limits and transient failures
  while [ $attempt -le $max_retries ]; do
    echo "Downloading $file_path (attempt $attempt/$max_retries)..." | tee -a "$MODEL_LOG"
    if hf download "$repo" \
      "$file_path" \
      --local-dir "$temp_dir" \
      --cache-dir "$temp_dir/.cache" 2>&1 | tee -a "$MODEL_LOG"
    then
      mkdir -p "$(dirname "$output_path")"
      mv "$temp_dir/$file_path" "$output_path"
      rm -rf "$temp_dir"
      rmdir "$lockfile"
      release_slot "$slot"
      echo "✓ Successfully downloaded: $output_path" | tee -a "$MODEL_LOG"
      return 0
    else
      echo "✗ Download failed (attempt $attempt/$max_retries), retrying in ${retry_delay}s..." | tee -a "$MODEL_LOG"
      sleep $retry_delay
      retry_delay=$((retry_delay * 2)) # Exponential backoff
      attempt=$((attempt + 1))
    fi
  done

  echo "ERROR: Failed to download $output_path after $max_retries attempts" | tee -a "$MODEL_LOG"
  rm -rf "$temp_dir"
  rmdir "$lockfile"
  release_slot "$slot"
  return 1
}

acquire_slot() {
  while true; do
    local count
    count=$(find "$HF_SEMAPHORE_DIR" -name "slot_*" 2>/dev/null | wc -l)
    if [ $count -lt $HF_MAX_PARALLEL ]; then
      local slot="$HF_SEMAPHORE_DIR/slot_$$_$RANDOM"
      touch "$slot"
      echo "$slot"
      return 0
    fi
    sleep 0.5
  done
}

release_slot() { rm -f "$1"; }

# Same pattern as WAN: write payload for /generate/sync + benchmark.json :contentReference[oaicite:2]{index=2}
write_workflow() {
  local workflow_json
  read -r -d '' workflow_json << 'WORKFLOW_JSON' || true
{"10":{"inputs":{"model":"hunyuan3d-dit-v2-0-fp16.safetensors","attention_mode":"sdpa","cublas_ops":false},"class_type":"Hy3DModelLoader","_meta":{"title":"Hy3DModelLoader"}},"13":{"inputs":{"image":"__INPUT_IMAGE__"},"class_type":"LoadImage","_meta":{"title":"Charger Image"}},"17":{"inputs":{"filename_prefix":"3D/Hy3D","file_format":"glb","save_file":true,"trimesh":["59",0]},"class_type":"Hy3DExportMesh","_meta":{"title":"Hy3DExportMesh"}},"28":{"inputs":{"model":"hunyuan3d-delight-v2-0"},"class_type":"DownloadAndLoadHy3DDelightModel","_meta":{"title":"(Down)Load Hy3D DelightModel"}},"35":{"inputs":{"steps":50,"width":1024,"height":1024,"cfg_image":1,"seed":0,"delight_pipe":["28",0],"image":["64",0],"scheduler":["148",0]},"class_type":"Hy3DDelightImage","_meta":{"title":"Hy3DDelightImage"}},"45":{"inputs":{"images":["35",0]},"class_type":"PreviewImage","_meta":{"title":"Aperçu Image"}},"52":{"inputs":{"width":1024,"height":1024,"interpolation":"lanczos","method":"pad","condition":"always","multiple_of":2,"image":["13",0]},"class_type":"ImageResize+","_meta":{"title":"🔧 Image Resize"}},"55":{"inputs":{"mode":"base","use_jit":true},"class_type":"TransparentBGSession+","_meta":{"title":"🔧 InSPyReNet TransparentBG"}},"56":{"inputs":{"rembg_session":["55",0],"image":["52",0]},"class_type":"ImageRemoveBackground+","_meta":{"title":"🔧 Image Remove Background"}},"59":{"inputs":{"remove_floaters":true,"remove_degenerate_faces":true,"reduce_faces":true,"max_facenum":100000,"smooth_normals":false,"trimesh":["140",0]},"class_type":"Hy3DPostprocessMesh","_meta":{"title":"Hy3D Postprocess Mesh"}},"61":{"inputs":{"camera_azimuths":"0, 90, 180, 270, 0, 180","camera_elevations":"0, 0, 0, 0, 90, -90","view_weights":"1, 0.1, 0.5, 0.1, 0.05, 0.05","camera_distance":1.45,"ortho_scale":1.2},"class_type":"Hy3DCameraConfig","_meta":{"title":"Hy3D Camera Config"}},"64":{"inputs":{"x":0,"y":0,"resize_source":false,"destination":["133",0],"source":["52",0],"mask":["56",1]},"class_type":"ImageCompositeMasked","_meta":{"title":"ImageCompositeMasked"}},"79":{"inputs":{"render_size":1024,"texture_size":2048,"normal_space":"world","trimesh":["83",0],"camera_config":["61",0]},"class_type":"Hy3DRenderMultiView","_meta":{"title":"Hy3D Render MultiView"}},"83":{"inputs":{"trimesh":["59",0]},"class_type":"Hy3DMeshUVWrap","_meta":{"title":"Hy3D Mesh UV Wrap"}},"85":{"inputs":{"model":"hunyuan3d-paint-v2-0"},"class_type":"DownloadAndLoadHy3DPaintModel","_meta":{"title":"(Down)Load Hy3D PaintModel"}},"88":{"inputs":{"view_size":1024,"steps":50,"seed":1024,"denoise_strength":1,"pipeline":["85",0],"ref_image":["35",0],"normal_maps":["79",0],"position_maps":["79",1],"camera_config":["61",0],"scheduler":["149",0]},"class_type":"Hy3DSampleMultiView","_meta":{"title":"Hy3D Sample MultiView"}},"92":{"inputs":{"images":["117",0],"renderer":["79",2],"camera_config":["61",0]},"class_type":"Hy3DBakeFromMultiview","_meta":{"title":"Hy3D Bake From Multiview"}},"98":{"inputs":{"texture":["104",0],"renderer":["129",2]},"class_type":"Hy3DApplyTexture","_meta":{"title":"Hy3D Apply Texture"}},"99":{"inputs":{"filename_prefix":"3D/Hy3D_textured","file_format":"glb","save_file":true,"trimesh":["98",0]},"class_type":"Hy3DExportMesh","_meta":{"title":"Hy3DExportMesh"}},"104":{"inputs":{"inpaint_radius":5,"inpaint_method":"ns","texture":["129",0],"mask":["129",1]},"class_type":"CV2InpaintTexture","_meta":{"title":"CV2 Inpaint Texture"}},"117":{"inputs":{"width":2048,"height":2048,"interpolation":"lanczos","method":"stretch","condition":"always","multiple_of":0,"image":["88",0]},"class_type":"ImageResize+","_meta":{"title":"🔧 Image Resize"}},"129":{"inputs":{"texture":["92",0],"mask":["92",1],"renderer":["92",2]},"class_type":"Hy3DMeshVerticeInpaintTexture","_meta":{"title":"Hy3D Mesh Vertice Inpaint Texture"}},"132":{"inputs":{"value":0.8,"width":1024,"height":1024},"class_type":"SolidMask","_meta":{"title":"SolidMask"}},"133":{"inputs":{"mask":["132",0]},"class_type":"MaskToImage","_meta":{"title":"Convertir le masque en image"}},"140":{"inputs":{"box_v":1.01,"octree_resolution":384,"num_chunks":32000,"mc_level":0,"mc_algo":"mc","enable_flash_vdm":true,"force_offload":true,"vae":["10",1],"latents":["141",0]},"class_type":"Hy3DVAEDecode","_meta":{"title":"Hy3D VAE Decode"}},"141":{"inputs":{"guidance_scale":5.5,"steps":50,"seed":123,"scheduler":"FlowMatchEulerDiscreteScheduler","force_offload":true,"pipeline":["10",0],"image":["52",0],"mask":["56",1]},"class_type":"Hy3DGenerateMesh","_meta":{"title":"Hy3DGenerateMesh"}},"148":{"inputs":{"scheduler":"Euler A","sigmas":"default","pipeline":["28",0]},"class_type":"Hy3DDiffusersSchedulerConfig","_meta":{"title":"Hy3D Diffusers Scheduler Config"}},"149":{"inputs":{"scheduler":"Euler A","sigmas":"default","pipeline":["85",0]},"class_type":"Hy3DDiffusersSchedulerConfig","_meta":{"title":"Hy3D Diffusers Scheduler Config"}}}
WORKFLOW_JSON

  # Write payload file for API wrapper
  rm -f /opt/comfyui-api-wrapper/payloads/*
  cat > /opt/comfyui-api-wrapper/payloads/hunyuan3d.json << EOF
{
  "input": {
    "request_id": "",
    "workflow_json": ${workflow_json}
  }
}
EOF

  # Wait for directory to exist (from git clone), then write benchmark.json
  local benchmark_dir="$WORKSPACE/vast-pyworker/workers/comfyui-json/misc"
  while [[ ! -d "$benchmark_dir" ]]; do sleep 1; done
  echo "$workflow_json" > "$benchmark_dir/benchmark.json"
}

# Add a cron job to remove older (oldest +24 hours) output files if disk space is low :contentReference[oaicite:3]{index=3}
set_cleanup_job() {
  if [[ ! -f /opt/instance-tools/bin/clean-output.sh ]]; then
    cat > /opt/instance-tools/bin/clean-output.sh << 'CLEAN_OUTPUT'
#!/bin/bash
output_dir="${WORKSPACE:-/workspace}/ComfyUI/output/"
min_free_mb=512
available_space=$(df -m "${output_dir}" | awk 'NR==2 {print $4}')
if [[ "$available_space" -lt "$min_free_mb" ]]; then
  oldest=$(find "${output_dir}" -mindepth 1 -type f -printf "%T@\n" 2>/dev/null | sort -n | head -1 | awk '{printf "%.0f", $1}')
  if [[ -n "$oldest" ]]; then
    cutoff=$(awk "BEGIN {printf \"%.0f\", ${oldest}+86400}")
    find "${output_dir}" -mindepth 1 -type f ! -newermt "@${cutoff}" -delete
    find "${output_dir}" -mindepth 1 -xtype l -delete
    find "${output_dir}" -mindepth 1 -type d -empty -delete
  fi
fi
CLEAN_OUTPUT
    chmod +x /opt/instance-tools/bin/clean-output.sh
  fi

  if ! crontab -l 2>/dev/null | grep -qF 'clean-output.sh'; then
    (crontab -l 2>/dev/null; echo '*/10 * * * * /opt/instance-tools/bin/clean-output.sh') | crontab -
  fi
}

main
