#!/bin/bash
# Builds the heavy engine payload for the desktop app, cached by content key.
#
# Outputs into $PAYLOAD_DIR (default: <repo>/desktop/payload-cache):
#   python_env.tar.gz  relocatable conda env (python, torch-mps, ffmpeg, sox,
#                      mediainfo, tesseract, espeakng-loader, sitecustomize)
#   calibre.app/       official Calibre .app (ebook-convert)
#   voices/            seed voices (all builtin speaker wavs)
#
# Cache key: hash of this script + requirements.txt + VERSION.txt.
# Env overrides: PAYLOAD_DIR, SRC_DIR
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${SRC_DIR:-$(cd "$HERE/../.." && pwd)}"
PAYLOAD_DIR="${PAYLOAD_DIR:-$SRC_DIR/desktop/payload-cache}"
WORK="$PAYLOAD_DIR/work"

MINIFORGE_VERSION="26.5.3-0"
MINIFORGE_URL="https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VERSION}/Miniforge3-MacOSX-arm64.sh"
MINIFORGE_SHA256="0d765919d3ccfd1f89147aa1cf8133bfc55b3a3c13f5bacdcc091c33132fddd2"

CALIBRE_VERSION="9.13.0"
CALIBRE_URL="https://github.com/kovidgoyal/calibre/releases/download/v${CALIBRE_VERSION}/calibre-${CALIBRE_VERSION}.dmg"
CALIBRE_SHA256="001be6ed70d8acfd793fa7d8c95ea50045abedaf0e756b20e564275a0b0a7667"

KEY="$(cat "$SRC_DIR/requirements.txt" "$HERE/build-payload.sh" "$SRC_DIR/VERSION.txt" | shasum -a 256 | cut -c1-16)"

mkdir -p "$PAYLOAD_DIR"
if [ -f "$PAYLOAD_DIR/key" ] \
   && [ "$(cat "$PAYLOAD_DIR/key")" = "$KEY" ] \
   && [ -f "$PAYLOAD_DIR/python_env.tar.gz" ] \
   && [ -d "$PAYLOAD_DIR/calibre.app" ] \
   && [ -d "$PAYLOAD_DIR/voices" ]; then
  echo "payload cache hit (key=$KEY)"
  exit 0
fi

echo "building engine payload (key=$KEY)"
rm -rf "$PAYLOAD_DIR/python_env.tar.gz" "$PAYLOAD_DIR/calibre.app" "$PAYLOAD_DIR/voices" "$WORK"
mkdir -p "$WORK"
cd "$WORK"

# ---------------------------------------------------------------- miniforge
echo "=== installing miniforge ${MINIFORGE_VERSION} ==="
curl -fL --retry 3 -o miniforge.sh "$MINIFORGE_URL"
ACTUAL="$(shasum -a 256 miniforge.sh | cut -d' ' -f1)"
if [ "$ACTUAL" != "$MINIFORGE_SHA256" ]; then
  echo "FATAL: miniforge checksum mismatch" >&2
  exit 1
fi
bash miniforge.sh -b -p "$WORK/miniforge"

# ---------------------------------------------------------------- python env
echo "=== creating python 3.12 env with native tools ==="
"$WORK/miniforge/bin/conda" create -y -p "$WORK/env" -c conda-forge \
  --strict-channel-priority \
  python=3.12 pip conda-pack ffmpeg sox mediainfo tesseract

export E2A_HOME="$WORK/data"
mkdir -p "$E2A_HOME"
PY="$WORK/env/bin/python"

echo "=== installing device (MPS/torch) + python packages ==="
cd "$SRC_DIR"
DEVICE_INFO="$($PY -c 'from lib.classes.device_installer import DeviceInstaller; print(DeviceInstaller().check_device_info("native"))')"
echo "device: $DEVICE_INFO"
$PY -c 'import sys
from lib.classes.device_installer import DeviceInstaller
d = DeviceInstaller()
sys.exit(d.install_device_packages(sys.argv[1]))' "$DEVICE_INFO"
$PY -c 'import sys
from lib.classes.device_installer import DeviceInstaller
sys.exit(DeviceInstaller().install_python_packages())'

echo "=== bundling espeak-ng loader + sitecustomize hook ==="
$PY -m pip install --no-cache-dir espeakng-loader==0.2.4
SITE="$($PY -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
cp "$SRC_DIR/components/sitecustomize.py" "$SITE/sitecustomize.py"

echo "=== packing python_env ==="
"$WORK/env/bin/conda-pack" -p "$WORK/env" -o "$PAYLOAD_DIR/python_env.tar.gz" \
  --force --ignore-missing-files

# voices were downloaded by install_python_packages()/check_voices() into
# $E2A_HOME/voices — harvest as the first-run seed.
if [ -d "$E2A_HOME/voices" ] && [ -n "$(find "$E2A_HOME/voices" -name '*.wav' -print -quit 2>/dev/null)" ]; then
  mv "$E2A_HOME/voices" "$PAYLOAD_DIR/voices"
else
  echo "FATAL: voices were not downloaded" >&2
  exit 1
fi

# ---------------------------------------------------------------- calibre
echo "=== fetching calibre ${CALIBRE_VERSION} ==="
cd "$WORK"
curl -fL --retry 3 -o calibre.dmg "$CALIBRE_URL"
ACTUAL="$(shasum -a 256 calibre.dmg | cut -d' ' -f1)"
if [ "$ACTUAL" != "$CALIBRE_SHA256" ]; then
  echo "FATAL: calibre checksum mismatch" >&2
  exit 1
fi
hdiutil attach -nobrowse -readonly -mountpoint "$WORK/calibre-mount" calibre.dmg >/dev/null
ditto "$WORK/calibre-mount/calibre.app" "$PAYLOAD_DIR/calibre.app"
hdiutil detach "$WORK/calibre-mount" >/dev/null

echo "$KEY" > "$PAYLOAD_DIR/key"
rm -rf "$WORK"
echo "=== payload done ==="
du -sh "$PAYLOAD_DIR"/*
