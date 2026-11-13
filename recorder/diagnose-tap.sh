#!/bin/bash
# diagnose-tap.sh — tries the two system-audio capture strategies and says which one works.
# No rebuild needed: the strategy is chosen at runtime (--tap=device|global).
# Run it from your own Terminal. It plays a sound and says a phrase out loud.
set -uo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
# configuration: plain KEY=value lines, exported one by one (nothing is evaluated)
CRT_CFG="$(python3 "$BASE/crt_config.py" --shell)" || { echo "cannot read the configuration"; exit 1; }
while IFS= read -r CRT_L; do
  case "${CRT_L%%=*}" in CRT_*) export "${CRT_L%%=*}=${CRT_L#*=}" ;; esac
done <<< "$CRT_CFG"
unset CRT_CFG CRT_L
APP="$CRT_INSTALL_DIR/Call Recorder.app/Contents/MacOS/CallRecorder"
[ -x "$APP" ] || { echo "Call Recorder.app not found: run build.sh first"; exit 1; }
PATTERN="MacOS/CallRecorder"
WORK="$(mktemp -d -t call-recorder-diagnose)"

for STRATEGY in device global; do
  D="$WORK/$STRATEGY"; mkdir -p "$D"
  pkill -9 -f "$PATTERN" 2>/dev/null; sleep 1
  ( "$APP" "$D" "--tap=$STRATEGY" >/dev/null 2>&1 & )
  sleep 3
  afplay /System/Library/Sounds/Submarine.aiff 2>/dev/null
  say "testing one two three" 2>/dev/null
  sleep 1
  pkill -INT -f "$PATTERN" 2>/dev/null; sleep 2
  P=$(ffmpeg -hide_banner -i "$D/system.wav" -af volumedetect -f null - 2>&1 | sed -n 's/.*max_volume: \(-*[0-9.]*\) dB.*/\1/p')
  CB=$(grep -o "callback: [0-9]*" "$D/recorder.log" 2>/dev/null | tail -1)
  if [ -n "$P" ] && awk "BEGIN{exit !($P > -55)}"; then
    printf "  %-8s peak %8s dB  (%s)  ✓ WORKS\n" "$STRATEGY" "$P" "${CB:-no callback}"
  else
    printf "  %-8s peak %8s dB  (%s)  ✗ silent\n" "$STRATEGY" "${P:-n/a}" "${CB:-no callback}"
  fi
done
pkill -9 -f "$PATTERN" 2>/dev/null
rm -rf "$WORK"
