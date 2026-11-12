#!/bin/bash
# Double-click from the Finder or the Dock. It works from wherever it sits next to `rec`
# (build.sh installs both in ~/Applications/Call Recorder).
# "Record speakerphone.command" runs this same file with REC_SPEAKERPHONE=1.
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 1
eval "$(python3 "$HERE/crt_config.py" --shell)"
t() { if [ "$CRT_UI_LANG" = it ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
[ -x "$HERE/rec" ] || { echo "rec not found next to this launcher: $HERE"; read -r; exit 1; }

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
[ -z "$TITLE" ] && TITLE="$(t call riunione)"
echo

./rec -- "$TITLE"

echo
# rec leaves in the pointer file the PDF of the summary (or the note, if there is no PDF)
LAST="$(sed -n 's/^open=//p' "$CRT_LAST" 2>/dev/null)"
if [ -n "$LAST" ] && [ -f "$LAST" ]; then
  read -r -p "  $(t "Open the summary? [enter = yes, n = no]  " "Apro la sintesi? [invio = sì, n = no]  ")" R
  [ "$R" != "n" ] && open "$LAST"
fi

echo
read -r -p "  $(t "Press ENTER to close.  " "Premi INVIO per chiudere.  ")" _
