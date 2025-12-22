#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[hy3d-provision] $*"; }

# 0) Détecter le dossier ComfyUI (selon template Vast)
find_comfy() {
  for d in /workspace/ComfyUI /root/ComfyUI /opt/ComfyUI /comfyui/ComfyUI; do
    if [ -d "$d" ] && [ -d "$d/custom_nodes" ] && [ -d "$d/models" ]; then
      echo "$d"; return 0
    fi
  done
  local hit
  hit="$(find / -maxdepth 4 -type d -name "ComfyUI" 2>/dev/null | head -n 1 || true)"
  if [ -n "${hit:-}" ] && [ -d "$hit/custom_nodes" ] && [ -d "$hit/models" ]; then
    echo "$hit"; return 0
  fi
  return 1
}

COMFY="$(find_comfy || true)"
if [ -z "${COMFY:-}" ]; then
  log "ERREUR: ComfyUI introuvable (chemins standard non trouvés)."
  exit 1
fi
log "ComfyUI détecté: $COMFY"

export DEBIAN_FRONTEND=noninteractive

# 1) Dépendances système (GL + build)
if command -v apt-get >/dev/null 2>&1; then
  log "Installation dépendances système..."
  apt-get update -y
  apt-get install -y --no-install-recommends \
    git ca-certificates curl \
    build-essential python3-dev \
    cmake ninja-build \
    libgl1 \
    && rm -rf /var/lib/apt/lists/*
else
  log "WARN: apt-get non disponible, saute l'install système."
fi

# 2) Venv Vast (demandé)
if [ -f /venv/main/bin/activate ]; then
  # shellcheck disable=SC1091
  source /venv/main/bin/activate
  log "Venv activé: /venv/main"
else
  log "WARN: /venv/main/bin/activate introuvable, on continue sans."
fi

python -m pip install -U pip setuptools wheel

# Optionnel: onnxruntime (tu l'avais avant)
python -m pip install -U onnxruntime || true

# HF CLI (tu l'avais avant)
curl -LsSf https://hf.co/cli/install.sh | bash || true

# 3) Fix OpenGL EXACT demandé
log "Fix OpenGL (exact)..."
ls -l /usr/lib/x86_64-linux-gnu/libGL.so.1 || true
ln -sf /usr/lib/x86_64-linux-gnu/libGL.so.1 /usr/lib/x86_64-linux-gnu/libOpenGL.so.0
ldconfig
ldconfig -p | grep -E "libOpenGL\.so\.0|libGL\.so\.1" || true


log "Installation ComfyUI-3D-Pack "
cd "$COMFY/custom_nodes/"
git clone https://github.com/MrForExample/ComfyUI-3D-Pack.git
cd "$COMFY/custom_nodes/ComfyUI-3D-Pack/"
pip install -r requirements.txt
python install.py

# 5) Compiler mesh painter (chemin EXACT demandé)
DR_DIR="$COMFY/custom_nodes/ComfyUI-3D-Pack/Gen_3D_Modules/Hunyuan3D_2_1/hy3dpaint/DifferentiableRenderer"
if [ ! -d "$DR_DIR" ]; then
  log "ERREUR: DifferentiableRenderer introuvable: $DR_DIR"
  log "=> Vérifie que ComfyUI-3D-Pack est bien sous $COMFY/custom_nodes/ComfyUI-3D-Pack"
  exit 1
fi

log "Compilation mesh painter..."
cd "$DR_DIR"
bash ./compile_mesh_painter.sh

# 6) GLB outputs: ton workflow écrit Hun2-1/mesh.glb + Hun2-1/tex_mesh.glb
mkdir -p "$COMFY/output/Hun2-1"

# 7) Patch PyWorker pour inclure .glb dans output[] (donc upload S3 + URL)
#    On localise le worker comfyui-json via benchmark.json (doc Vast mentionne workers/comfyui-json/misc/benchmark.json).
log "Patch PyWorker (comfyui-json) pour inclure .glb..."
BENCH="$(find / -type f -path "*/workers/comfyui-json/misc/benchmark.json" 2>/dev/null | head -n 1 || true)"
if [ -z "${BENCH:-}" ]; then
  # fallback: certains templates clonent ailleurs, on cherche comfyui-json/misc/benchmark.json
  BENCH="$(find / -type f -path "*comfyui-json/misc/benchmark.json" 2>/dev/null | head -n 1 || true)"
fi

if [ -z "${BENCH:-}" ]; then
  log "WARN: benchmark.json introuvable, patch PyWorker non appliqué."
else
  WORKER_DIR="$(cd "$(dirname "$BENCH")/.." && pwd)"  # -> .../workers/comfyui-json
  log "Worker comfyui-json détecté: $WORKER_DIR"

  # On cherche le fichier qui définit/filtre les extensions d'assets (souvent output.py / utils/output*.py)
  OUTFILE="$(grep -RIl --exclude-dir=.git --exclude=*.pyc -E "ALLOWED_.*EXT|allowed_.*ext|\\.(png|jpg|jpeg|webp|mp4)" "$WORKER_DIR" 2>/dev/null | head -n 1 || true)"

  if [ -z "${OUTFILE:-}" ]; then
    log "WARN: Fichier de whitelist extensions introuvable dans $WORKER_DIR, patch non appliqué."
  else
    log "Patch extensions dans: $OUTFILE"
    python - <<'PY'
import re, pathlib

p = pathlib.Path(r"""'"$OUTFILE"'"")
txt = p.read_text(encoding="utf-8", errors="ignore")

# Ajoute ".glb" si une whitelist d'extensions existe
patterns = [
    # ex: ALLOWED_EXTENSIONS = {".png", ".jpg", ...}
    (r'(ALLOWED_\w*EXT\w*\s*=\s*\{[^}]*)(\})', r'\1, ".glb"\2'),
    # ex: ALLOWED_EXTENSIONS = [".png", ".jpg", ...]
    (r'(ALLOWED_\w*EXT\w*\s*=\s*\[[^\]]*)(\])', r'\1, ".glb"\2'),
    # ex: allowed_extensions = { ... }
    (r'(allowed_\w*ext\w*\s*=\s*\{[^}]*)(\})', r'\1, ".glb"\2'),
    (r'(allowed_\w*ext\w*\s*=\s*\[[^\]]*)(\])', r'\1, ".glb"\2'),
]

new = txt
for pat, rep in patterns:
    if re.search(pat, new):
        new2 = re.sub(pat, rep, new, count=1)
        if new2 != new:
            new = new2
            break

# Si on a déjà ".glb" (ou glb sans point), on ne touche pas
if re.search(r'["\']\.glb["\']', txt) or re.search(r'["\']glb["\']', txt):
    pass
elif new == txt:
    # fallback: si aucune var whitelist, on tente d'ajouter "glb" à un tuple/list d'extensions courantes
    new = re.sub(r'(\.mp4["\']\s*[,}\]])', r'.mp4", ".glb"\1', txt, count=1)

p.write_text(new, encoding="utf-8")
PY
  fi
fi

# 8) Désinstaller sageattention (demandé)
pip uninstall -y sageattention || true

# 9) Restart (demandé)
if command -v supervisorctl >/dev/null 2>&1; then
  supervisorctl restart comfyui || true
  supervisorctl restart api-wrapper || true
else
  log "WARN: supervisorctl introuvable."
fi

log "Provisioning terminé."
