#!/bin/bash
# Publish the built image to the NAS, which serves it over HTTP via the
# ota-images quadlet (deploy/ota-images.container, ~/ota-images on luna:8080).
#
# Compresses image/*.img to .img.gz (gzip -1: fast to stream, small on the
# wire), writes the two sidecars ota-flash reads, copies all three to the NAS
# and verifies what landed there.
#
# Usage: scripts/04-ota-publish.sh [image-file] [--local] [--host HOST] [--port N]
#   --local        do not touch the NAS: serve image/ from this host instead
#   --host HOST    URL host for the board (default: $OTA_URL_HOST or 10.21.50.12)
#   --port N       port on the host (default: $OTA_URL_PORT or 8080)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

NAS_SSH="${OTA_NAS_SSH:-lunarian@luna}"
NAS_DIR="${OTA_NAS_DIR:-ota-images}"
LOCAL=0
URL_HOST="${OTA_URL_HOST:-10.21.50.12}"
URL_PORT="${OTA_URL_PORT:-8080}"
IMG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --local) LOCAL=1; shift ;;
    --host) URL_HOST="$2"; shift 2 ;;
    --port) URL_PORT="$2"; shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) IMG="$1"; shift ;;
  esac
done

if [ -z "$IMG" ]; then
  IMG=$(ls -1t image/*.img 2>/dev/null | head -1 || true)
  [ -n "$IMG" ] || { echo "no image/*.img found: run scripts/03-build-image.sh first" >&2; exit 1; }
fi
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }

IMG_GZ="$IMG.gz"
IMG_SHA="$IMG.sha256"
IMG_SIZE="$IMG.size"

if [ ! -f "$IMG_GZ" ] || [ "$IMG" -nt "$IMG_GZ" ]; then
  echo "--- compressing $IMG (gzip -1)"
  gzip -1 -c "$IMG" > "$IMG_GZ.part"
  mv "$IMG_GZ.part" "$IMG_GZ"
fi

echo "--- sidecars"
# write via temp + rename: the image dir may hold root-owned leftovers from the
# containerised build, and only the directory needs to be writable for that
sha256sum "$IMG" | awk '{ print $1 }' > "$IMG_SHA.tmp"
mv "$IMG_SHA.tmp" "$IMG_SHA"
stat -c '%s' "$IMG" > "$IMG_SIZE.tmp"
mv "$IMG_SIZE.tmp" "$IMG_SIZE"
cat "$IMG_SHA" "$IMG_SIZE" | sed 's/^/    /'

BASE=$(basename "$IMG_GZ")
URL="http://${URL_HOST}:${URL_PORT}/${BASE}"

if [ "$LOCAL" = 1 ]; then
  cat <<EOF

serving $ROOT_DIR/image on 0.0.0.0:$URL_PORT (Ctrl-C to stop)

On the board:

  ota-flash $URL
EOF
  exec python3 -m http.server "$URL_PORT" --bind 0.0.0.0 --directory image
fi

echo "--- copying to $NAS_SSH:~/$NAS_DIR"
ssh "$NAS_SSH" "mkdir -p ~/$NAS_DIR"
scp -q "$IMG_GZ" "$IMG_SHA" "$IMG_SIZE" "$NAS_SSH:~/$NAS_DIR/"

echo "--- verifying on the NAS"
ssh "$NAS_SSH" "cd ~/$NAS_DIR && ls -l '$BASE' '$(basename "$IMG_SHA")' '$(basename "$IMG_SIZE")' && echo -n 'remote sha256: ' && cat '$(basename "$IMG_SHA")' && echo 'http headers:' && curl -sI 'http://127.0.0.1:$URL_PORT/$BASE' | head -3"

LOCAL_SHA=$(cat "$IMG_SHA")
REMOTE_SHA=$(ssh "$NAS_SSH" "cat ~/$NAS_DIR/$(basename "$IMG_SHA")")
[ "$LOCAL_SHA" = "$REMOTE_SHA" ] || { echo "FAIL: sha256 sidecar differs on the NAS" >&2; exit 1; }

cat <<EOF

published. On the board:

  ota-flash $URL

ota-flash fetches $URL, $(echo "$URL" | sed 's/\.gz$//').sha256 and
$(echo "$URL" | sed 's/\.gz$//').size from the same directory, streams the
image through gzip into dd on the boot medium, then verifies the bootloader
magic and re-reads the written region to compare against the sha256.

Dry run first (streams everything, writes nothing):

  ota-flash $URL --test -y
EOF
