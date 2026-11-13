#!/bin/bash
# check-setup.sh — checks what the recorder needs, without recording anything.
# Prints one line per requirement: OK, or what to do. Exit code 0 if everything is there.
set -uo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
# configuration: plain KEY=value lines, exported one by one (nothing is evaluated)
CRT_CFG="$(python3 "$BASE/crt_config.py" --shell)" || { echo "cannot read the configuration"; exit 1; }
while IFS= read -r CRT_L; do
  case "${CRT_L%%=*}" in CRT_*) export "${CRT_L%%=*}=${CRT_L#*=}" ;; esac
done <<< "$CRT_CFG"
unset CRT_CFG CRT_L
FAIL=0
ok()  { printf "  ✓ %s\n" "$1"; }
bad() { printf "  ✗ %s\n      → %s\n" "$1" "$2"; FAIL=1; }

[ "$(uname -s)" = Darwin ] && ok "macOS" || bad "not macOS" "this recorder only works on a Mac"
ARCH="$(uname -m)"; [ "$ARCH" = arm64 ] && ok "Apple Silicon" || bad "CPU: $ARCH" "tested on Apple Silicon only; Intel may work but is slow for whisper"
VER="$(sw_vers -productVersion 2>/dev/null)"
if python3 -c "import sys; v=[int(x) for x in sys.argv[1].split('.')[:2]]+[0]; sys.exit(0 if (v[0],v[1])>=(14,4) else 1)" "$VER"; then
  ok "macOS $VER (≥ 14.4)"
else
  bad "macOS $VER" "system-audio capture needs macOS 14.4 or later"
fi
command -v swiftc >/dev/null && ok "Xcode command line tools (swiftc)" || bad "swiftc missing" "xcode-select --install"
command -v ffmpeg >/dev/null && ok "ffmpeg" || bad "ffmpeg missing" "brew install ffmpeg"
command -v whisper-cli >/dev/null && ok "whisper-cli (whisper.cpp)" || bad "whisper-cli missing" "brew install whisper-cpp"
MODEL=""
for m in ggml-large-v3-turbo.bin ggml-medium.bin ggml-small.bin; do
  [ -s "$CRT_MODEL_DIR/$m" ] && { MODEL="$m"; break; }
done
[ -n "$MODEL" ] && ok "whisper model: $MODEL" || bad "no whisper model in $CRT_MODEL_DIR" "run get-model.sh (~1.6 GB download)"
[ -x "$CRT_INSTALL_DIR/Call Recorder.app/Contents/MacOS/CallRecorder" ] && ok "Call Recorder.app in $CRT_INSTALL_DIR" \
  || bad "Call Recorder.app not built" "run build.sh, then setup-permissions.sh from your own Terminal"
if [ "$CRT_NOTE" = 1 ]; then
  if [ -n "${ANTHROPIC_API_KEY:-}" ] && [ "$CRT_NOTE_ENGINE" != cli ]; then ok "notes via the Claude API ($CRT_NOTE_MODEL)"
  elif command -v claude >/dev/null || ls ~/.nvm/versions/node/*/bin/claude ~/.local/bin/claude ~/.claude/local/claude >/dev/null 2>&1; then
    ok "notes via the claude CLI (it must be logged in from the Terminal: claude → /login)"
  else bad "no way to write notes" "install Claude Code, or set ANTHROPIC_API_KEY, or set CRT_NOTE=off"; fi
else
  ok "notes turned off (CRT_NOTE=off)"
fi
if [ "$CRT_PDF_DIR" != off ]; then
  BROWSER="$CRT_CHROME"
  for b in "Google Chrome" Chromium "Microsoft Edge" "Brave Browser"; do
    [ -n "$BROWSER" ] && break
    for root in /Applications "$HOME/Applications"; do [ -d "$root/$b.app" ] && BROWSER="$root/$b.app"; done
  done
  if [ -n "$BROWSER" ]; then
    ok "browser for the PDF: $(basename "$BROWSER" .app)"
  else
    bad "no Chrome/Chromium/Edge/Brave for the PDF" "install one, set CRT_CHROME, or set CRT_PDF_DIR=off"
  fi
fi
echo
echo "  config:     $CRT_CONFIG"
echo "  notes:      $CRT_NOTES_DIR"
echo "  recordings: $CRT_RECORDINGS_DIR"
echo "  PDF:        $CRT_PDF_DIR"
echo "  language:   $CRT_LANG   (messages: $CRT_UI_LANG)"
exit $FAIL
