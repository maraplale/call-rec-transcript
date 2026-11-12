#!/bin/bash
# setup-permissions.sh — makes the macOS permission dialogs appear and waits for your consent.
# Run it FROM YOUR OWN TERMINAL after every new build: the ad-hoc signature changes with
# each compilation and macOS treats the app as "new", so the permission must be given again.
#
#   ./setup-permissions.sh [seconds-to-wait]     (default 100)
set -uo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
eval "$(python3 "$BASE/crt_config.py" --shell)"
t() { if [ "$CRT_UI_LANG" = it ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
APPDIR="$CRT_INSTALL_DIR/Call Recorder.app"
[ -d "$APPDIR" ] || { echo "$(t "Call Recorder.app not found: run build.sh first" "Call Recorder.app non trovata: lancia prima build.sh")"; exit 1; }
PATTERN="MacOS/CallRecorder"
T="$(mktemp -d -t call-recorder-permissions)"
WAIT="${1:-100}"

pkill -f "$PATTERN" 2>/dev/null; sleep 1
# if the Terminal window is closed or Ctrl-C is pressed, never leave the recorder running
trap 'pkill -f "$PATTERN" 2>/dev/null; rm -rf "$T"' EXIT HUP INT TERM

echo "$(t "Starting «Call Recorder»." "Avvio «Call Recorder».")"
echo "$(t "One or two macOS dialogs should appear on screen: allow them." "Sullo schermo devono comparire uno o due pop-up di macOS: dai il consenso.")"
echo "  1) $(t "microphone access          → your voice" "accesso al microfono         → la tua voce")"
echo "  2) $(t "screen & system audio rec. → the others' audio" "registrazione schermo/audio → l'audio degli altri")"
echo
open -a "$APPDIR" --args "$T"

i=0
while [ $i -lt "$WAIT" ]; do
  sleep 5; i=$((i+5))
  SIZE=$(stat -f%z "$T/system.wav" 2>/dev/null || echo 0)
  if [ "$SIZE" -gt 200000 ]; then
    afplay /System/Library/Sounds/Submarine.aiff 2>/dev/null
    sleep 2
    pkill -INT -f "$PATTERN" 2>/dev/null; sleep 2
    P=$(ffmpeg -hide_banner -i "$T/system.wav" -af volumedetect -f null - 2>&1 | sed -n 's/.*max_volume: \(-*[0-9.]*\) dB.*/\1/p')
    echo "$(t "system audio peak" "picco audio di sistema"): ${P:-n/a} dB"
    rm -rf "$T"
    if [ -n "$P" ] && awk "BEGIN{exit !($P > -55)}"; then
      echo "✓ $(t "DONE: system audio is being captured. You can use rec." "FATTO: l'audio di sistema viene catturato. Puoi usare rec.")"
      exit 0
    fi
    echo "✗ $(t "the stream starts but is silent: the audio-capture consent is still missing." "il flusso parte ma è muto: manca ancora il consenso alla cattura audio.")"
    exit 1
  fi
  echo "  …$(t "waiting for consent" "in attesa del consenso") (${i}s)"
done

pkill -f "$PATTERN" 2>/dev/null
rm -rf "$T"
echo
echo "✗ $(t "No consent received within" "Nessun consenso ricevuto entro") ${WAIT}s."
echo "  $(t "Open: System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording" "Apri: Impostazioni di Sistema ▸ Privacy e sicurezza ▸ Registrazione schermo e audio di sistema")"
echo "  $(t "turn on «Call Recorder», then run ./setup-permissions.sh again" "attiva «Call Recorder», poi rilancia ./setup-permissions.sh")"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" 2>/dev/null
exit 1
