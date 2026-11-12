#!/bin/bash
# get-model.sh — downloads the whisper model used for transcription (~1.6 GB) from the
# official whisper.cpp repository on Hugging Face, into CRT_MODEL_DIR (default ~/.cache/whisper-cpp).
#
#   ./get-model.sh            large-v3-turbo (recommended)
#   ./get-model.sh small      smaller and faster, less accurate (~490 MB)
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
eval "$(python3 "$BASE/crt_config.py" --shell)"
NAME="${1:-large-v3-turbo}"
case "$NAME" in large-v3-turbo|medium|small) ;; *) echo "model: large-v3-turbo, medium or small"; exit 1;; esac
FILE="ggml-$NAME.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$FILE"
mkdir -p "$CRT_MODEL_DIR"
DEST="$CRT_MODEL_DIR/$FILE"
if [ -s "$DEST" ]; then echo "already there: $DEST"; exit 0; fi
echo "downloading $FILE → $CRT_MODEL_DIR"
# download to a temporary name: a broken download never looks like a complete model
curl -fL --retry 3 -C - -o "$DEST.part" "$URL"
mv "$DEST.part" "$DEST"
ls -lh "$DEST"
