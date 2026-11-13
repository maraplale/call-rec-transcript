#!/bin/bash
# self-test.sh — full test: records 14 seconds, transcribes, shows the result.
# RUN IT FROM YOUR OWN TERMINAL: if another process starts it, macOS attributes the
# permission to that process and the system-audio track comes out silent.
# The Mac speaks a sentence (it plays "the others"); speak into the microphone too.
set -uo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
# configuration: plain KEY=value lines, exported one by one (nothing is evaluated)
CRT_CFG="$(python3 "$BASE/crt_config.py" --shell)" || { echo "cannot read the configuration"; exit 1; }
while IFS= read -r CRT_L; do
  case "${CRT_L%%=*}" in CRT_*) export "${CRT_L%%=*}=${CRT_L#*=}" ;; esac
done <<< "$CRT_CFG"
unset CRT_CFG CRT_L
APPDIR="$CRT_INSTALL_DIR/Call Recorder.app"
[ -d "$APPDIR" ] || { echo "Call Recorder.app not found: run build.sh first"; exit 1; }
PATTERN="Call Recorder.app/Contents/MacOS/CallRecorder"
SESS="$(mktemp -d -t call-recorder-selftest)"

echo "Recording 14 seconds. The Mac will say a sentence (it plays the other person)."
echo "SPEAK INTO THE MICROPHONE TOO, so both tracks get tested."
echo
pkill -INT -f "$PATTERN" 2>/dev/null
open -n -a "$APPDIR" --args "$SESS"
sleep 3
say "So, to sum up: the invoice is twelve thousand euros. I will send you the details by Friday, and you prepare the payment plan in twelve instalments." 2>/dev/null
sleep 4
pkill -INT -f "$PATTERN" 2>/dev/null; sleep 2

echo
echo "── levels captured ──"
for track in system mic; do
  P=$(ffmpeg -hide_banner -i "$SESS/$track.wav" -af volumedetect -f null - 2>&1 | sed -n 's/.*max_volume: \(-*[0-9.]*\) dB.*/\1/p')
  printf "  %-8s %8s dB\n" "$track" "${P:-n/a}"
done

echo
echo "── transcript ──"
python3 "$BASE/transcribe.py" "$SESS" auto >/dev/null && cat "$SESS/transcript.md"
echo
echo "test folder (delete it when done): $SESS"
