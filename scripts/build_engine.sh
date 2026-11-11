#!/bin/bash
# Stages the ComfyUI engine that ships inside ReCaVSR.app:
#   - a standalone Python 3.13 (python-build-standalone, fetched by uv)
#   - PyTorch (pinned below) and the ComfyUI requirements
#   - ComfyUI (without models, outputs or other custom nodes)
#   - the ComfyUI-ReCaVSR custom node, with this app's patches (engine_patches/): one runs it on
#     Apple Silicon, the other keeps the video's colours
#   - the ComfyUI-AppleSilicon-int8-Fast custom node
# All three are downloaded from GitHub at the commits pinned below, so no local ComfyUI is
# needed. To use local copies instead, set COMFY_SRC (and INT8_SRC, RECAVSR_SRC).
# Output: build/engine-stage (copied into the app by build_app.sh).
# Run once; delete build/engine-stage to rebuild from scratch.
set -euo pipefail

cd "$(dirname "$0")/.."

# Sources, pinned to the commits the app was tested with. ComfyUI-ReCaVSR needs ComfyUI 0.44 or
# later (this is 0.45.0 plus a few commits); ComfyUI-ReCaVSR 2.0.0; int8-Fast 1.2.0.
COMFY_REPO="https://github.com/Comfy-Org/ComfyUI.git"
COMFY_COMMIT="74eb0c4b8a1a894e7210326882a8d9a016e37ccb"
RECAVSR_REPO="https://github.com/PedroMarinhoDev/ComfyUI-ReCaVSR.git"
RECAVSR_COMMIT="831769467c89b35ee47926189ac8189be63883d1"
# Applied in order to the pinned commit.
RECAVSR_PATCHES=("engine_patches/ComfyUI-ReCaVSR-1-apple-silicon.patch" "engine_patches/ComfyUI-ReCaVSR-2-color.patch")
INT8_REPO="https://github.com/Illuminus7/ComfyUI-AppleSilicon-int8-Fast.git"
INT8_COMMIT="d79490cf566af1c29e8bfab41ef9f0359dc6b5d2"

# PyTorch for Apple Silicon, pinned to the versions the engine was tested with. int8-Fast's Metal
# kernels need PyTorch 2.13 or later. torchaudio is left out: the engine does not process audio.
TORCH_PINS=("torch==2.15.0" "torchvision==0.29.2")
# PyAV reads and writes the video inside ReCaVSR; pinned to the version it was tested with.
AV_PIN="av==17.0.1"
# ComfyUI-ReCaVSR's requirements.txt asks for triton (NVIDIA only) and OpenCV. Only OpenCV is
# installed: without Triton the patched node runs its tiled PyTorch attention on the GPU.
RECAVSR_PIPS=("opencv-python-headless")
STAGE="build/engine-stage"
SOURCES="build/sources"
PY_VERSION="3.13"

if [ -f "$STAGE/.complete" ]; then
    echo "Engine already staged at $STAGE (delete it to rebuild)."
    exit 0
fi

# Downloads one repository at one commit (no history) into build/sources/<name>.
fetch_source() {
    local name="$1" repo="$2" commit="$3" dest="$SOURCES/$1"
    if [ "$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)" = "$commit" ]; then
        echo "==> $name already at ${commit:0:12}"
        return
    fi
    echo "==> Downloading $name at ${commit:0:12}"
    rm -rf "$dest"
    mkdir -p "$dest"
    git -C "$dest" init -q
    git -C "$dest" fetch -q --depth 1 "$repo" "$commit"
    git -C "$dest" -c advice.detachedHead=false checkout -q FETCH_HEAD
}

if [ -z "${COMFY_SRC:-}" ]; then
    fetch_source ComfyUI "$COMFY_REPO" "$COMFY_COMMIT"
    COMFY_SRC="$SOURCES/ComfyUI"
fi
if [ -z "${INT8_SRC:-}" ]; then
    if [ -d "$COMFY_SRC/custom_nodes/ComfyUI-AppleSilicon-int8-Fast" ] && [ "$COMFY_SRC" != "$SOURCES/ComfyUI" ]; then
        INT8_SRC="$COMFY_SRC/custom_nodes/ComfyUI-AppleSilicon-int8-Fast"
    else
        fetch_source ComfyUI-AppleSilicon-int8-Fast "$INT8_REPO" "$INT8_COMMIT"
        INT8_SRC="$SOURCES/ComfyUI-AppleSilicon-int8-Fast"
    fi
fi
NODE_SRC="$INT8_SRC"
if [ -z "${RECAVSR_SRC:-}" ]; then
    fetch_source ComfyUI-ReCaVSR "$RECAVSR_REPO" "$RECAVSR_COMMIT"
    RECAVSR_SRC="$SOURCES/ComfyUI-ReCaVSR"
fi

for required in "$COMFY_SRC/main.py" "$COMFY_SRC/requirements.txt" "$NODE_SRC/__init__.py" \
                "$RECAVSR_SRC/__init__.py" "$RECAVSR_SRC/nodes.py" "${RECAVSR_PATCHES[@]}"; do
    if [ ! -e "$required" ]; then
        echo "Missing: $required" >&2
        exit 1
    fi
done

rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "==> Fetching standalone Python $PY_VERSION"
UV_PYTHON_INSTALL_DIR="$PWD/$STAGE/.uv" uv python install --no-bin "$PY_VERSION"
PY_BIN="$(UV_PYTHON_INSTALL_DIR="$PWD/$STAGE/.uv" uv python find --managed-python "$PY_VERSION")"
PY_ROOT="$(cd "$(dirname "$PY_BIN")/.." && pwd -P)"
mv "$PY_ROOT" "$STAGE/python"
rm -rf "$STAGE/.uv"
PY="$STAGE/python/bin/python3"
# uv marks its interpreters as externally managed (PEP 668); this copy is ours to fill.
rm -f "$STAGE"/python/lib/python3*/EXTERNALLY-MANAGED

echo "==> Installing PyTorch and ComfyUI requirements"
"$PY" -m pip --version >/dev/null 2>&1 || "$PY" -m ensurepip
"$PY" -m pip install --no-cache-dir --disable-pip-version-check \
    "${TORCH_PINS[@]}" "$AV_PIN" \
    -r "$COMFY_SRC/requirements.txt" \
    -r "$NODE_SRC/requirements.txt" \
    "${RECAVSR_PIPS[@]}"

echo "==> Copying ComfyUI"
mkdir -p "$STAGE/ComfyUI"
# '/.*' skips every hidden top-level entry, including the source install's own .venv
# (about 2 GB that the bundled engine never uses) and .git.
rsync -a \
    --exclude='/.*' --exclude='/models' --exclude='/input' --exclude='/output' \
    --exclude='/temp' --exclude='/user' --exclude='/custom_nodes' --exclude='/tests' \
    --exclude='/tests-unit' --exclude='__pycache__' \
    "$COMFY_SRC/" "$STAGE/ComfyUI/"
mkdir -p "$STAGE/ComfyUI/models/recavsr" "$STAGE/ComfyUI/custom_nodes"

echo "==> Copying the int8-Fast node"
rsync -a --exclude='/.*' --exclude='/tests' --exclude='__pycache__' \
    "$NODE_SRC/" "$STAGE/ComfyUI/custom_nodes/ComfyUI-AppleSilicon-int8-Fast/"

echo "==> Copying the ReCaVSR node and applying the app's patches"
RECAVSR_DEST="$STAGE/ComfyUI/custom_nodes/ComfyUI-ReCaVSR"
# The demo media, tests and conversion tool are not needed to run it.
rsync -a --exclude='/.*' --exclude='/assets' --exclude='/tests' --exclude='/tools' --exclude='__pycache__' \
    "$RECAVSR_SRC/" "$RECAVSR_DEST/"
# A patch a local RECAVSR_SRC already has is skipped; one that applies neither way stops the build.
for patch_file in "${RECAVSR_PATCHES[@]}"; do
    if patch -d "$RECAVSR_DEST" -p1 -R --dry-run -s -f < "$patch_file" >/dev/null 2>&1; then
        echo "    $(basename "$patch_file"): already applied"
    else
        patch -d "$RECAVSR_DEST" -p1 -s -f --no-backup-if-mismatch < "$patch_file"
        echo "    $(basename "$patch_file"): applied"
    fi
done
find "$RECAVSR_DEST" \( -name "*.orig" -o -name "*.rej" \) -delete
grep -q "dst_colorspace" "$RECAVSR_DEST/recavsr/video_io.py" && [ -f "$RECAVSR_DEST/recavsr/tiled_attention.py" ] ||
    { echo "The ReCaVSR patches did not apply." >&2; exit 1; }

echo "==> Removing bytecode caches"
find "$STAGE" -name "__pycache__" -type d -prune -exec rm -rf {} +

./scripts/scrub_engine.sh

date -u +%Y-%m-%dT%H:%M:%SZ > "$STAGE/.complete"
echo "Engine staged at $STAGE"
