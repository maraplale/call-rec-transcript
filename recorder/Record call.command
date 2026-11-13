#!/bin/bash
# Double-click from the Finder or the Dock. It works from wherever it sits next to `rec`
# (build.sh installs both in ~/Applications/Call Recorder).
# "Record speakerphone.command" runs this same file with REC_SPEAKERPHONE=1.
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 1
eval "$(python3 "$HERE/crt_config.py" --shell)"
t() { if [ "$CRT_UI_LANG" = it ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
[ -x "$HERE/rec" ] || { echo "rec not found next to this launcher: $HERE"; read -r; exit 1; }

# Keep this window in front until the title is typed. Another app in front (a chat window
# that finishes its turn, for one) can take the focus back a few seconds after the
# double-click, and the window then waits hidden behind it. Stops after 20 s at most.
front() { [ "${TERM_PROGRAM:-}" = Apple_Terminal ] && osascript -e 'tell application "Terminal" to activate' >/dev/null 2>&1; }
front
( for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 2; front; done ) & KEEP_FRONT=$!

printf '\033[1m'
if [ "${REC_SPEAKERPHONE:-0}" = 1 ]; then
  echo
  echo "  ┌──────────────────────────────────────┐"
  echo "  │   CALL RECORDER · $(t "SPEAKERPHONE" "VIVA VOCE   ")       │"
  echo "  └──────────────────────────────────────┘"
  echo
  printf '\033[0m'
  echo "  $(t "Phone on speakerphone, next to the Mac's microphone." "Telefono in viva voce, appoggiato vicino al microfono del Mac.")"
  echo "  $(t "Microphone only: the transcript will not separate" "Registro solo il microfono: nella trascrizione le due voci")"
  echo "  $(t "the two voices into YOU / OTHERS." "non saranno separate in TU / ALTRI.")"
else
  echo
  echo "  ┌──────────────────────────────────────┐"
  echo "  │   CALL RECORDER                      │"
  echo "  └──────────────────────────────────────┘"
  echo
  printf '\033[0m'
fi
echo
echo "  $(t "As soon as they answer, tell them you are recording and ask if it is OK." "Appena risponde, avvisa che registri e chiedi se va bene.")"
echo "  $(t "If they say no: press ENTER to stop, and take notes by hand." "Se dice di no: premi INVIO per fermare e prendi appunti a mano.")"
echo

read -r -p "  $(t "What is this call about?  " "Di che riunione si tratta?  ")" TITLE
kill "$KEEP_FRONT" 2>/dev/null
[ -z "$TITLE" ] && TITLE="$(t call riunione)"
echo

./rec -- "$TITLE"

echo
# rec leaves in the pointer file the PDF of the summary (or the note, if there is no PDF)
LAST="$(sed -n 's/^open=//p' "$CRT_LAST" 2>/dev/null)"
if [ -n "$LAST" ] && [ -f "$LAST" ]; then
  read -r -p "  $(t "Open the summary? [enter = yes, n = no]  " "Apro la sintesi? [invio = sì, n = no]  ")" R
  case "$(printf '%s' "$R" | tr '[:upper:]' '[:lower:]' | tr -d ' ')" in
    ""|y|yes|s|si|sì|ok) open "$LAST" ;;
  esac
fi

echo
read -r -p "  $(t "Press ENTER to close.  " "Premi INVIO per chiudere.  ")" _
