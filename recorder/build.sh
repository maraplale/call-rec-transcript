#!/bin/bash
# build.sh — compiles Call Recorder.app and installs it, with the scripts and the
# double-click launchers, into the install folder (default: ~/Applications/Call Recorder).
#
#   ./build.sh            build if the Swift source changed, refresh the scripts
#   ./build.sh --force    always recompile
#
# Why an .app bundle: without an Info.plist macOS does not know whom to attribute the
# microphone and audio-capture permissions to, and the consent dialogs never appear.
#
# Why outside the plugin folder: the plugin folder is replaced on every update, and the
# permissions belong to the app at a stable place. Re-running build.sh after a plugin
# update only refreshes the scripts; the app is recompiled (and the permissions asked
# again) only when the Swift source has changed.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
# configuration: plain KEY=value lines, exported one by one (nothing is evaluated)
CRT_CFG="$(python3 "$SRC/crt_config.py" --shell)" || { echo "cannot read the configuration"; exit 1; }
while IFS= read -r CRT_L; do
  case "${CRT_L%%=*}" in CRT_*) export "${CRT_L%%=*}=${CRT_L#*=}" ;; esac
done <<< "$CRT_CFG"
unset CRT_CFG CRT_L
python3 "$SRC/crt_config.py" --init >/dev/null

FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
DEST="$CRT_INSTALL_DIR"
APP="$DEST/Call Recorder.app"
BIN="$APP/Contents/MacOS/CallRecorder"
# outside the bundle: a file added after signing would break the signature seal
STAMP="$DEST/.build-stamp"

if [ "$(uname -m)" != "arm64" ]; then
  echo "Warning: this has been tested on Apple Silicon only."
fi
command -v swiftc >/dev/null || { echo "swiftc not found: install the Xcode command line tools (xcode-select --install)"; exit 1; }

mkdir -p "$DEST"
# bump BUNDLE_REV when Info.plist or the signing below change: it forces a rebuild
BUNDLE_REV=2
ICON_PNG="$SRC/../assets/icon.png"
HASH="$( (cat "$SRC/src/recorder.swift" "$ICON_PNG"; echo "bundle-rev-$BUNDLE_REV") | shasum -a 256 | cut -d' ' -f1)"

if [ "$FORCE" = 0 ] && [ -x "$BIN" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$HASH" ]; then
  echo "Call Recorder.app is up to date (permissions kept)."
else
  echo "compiling…"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Call Recorder</string>
  <key>CFBundleDisplayName</key><string>Call Recorder</string>
  <key>CFBundleIdentifier</key><string>io.github.maraplale.call-rec-transcript</string>
  <key>CFBundleExecutable</key><string>CallRecorder</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Records your voice during calls, to transcribe it locally on this Mac.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Records the other participants' audio during calls, to transcribe it locally on this Mac.</string>
</dict>
</plist>
PLIST

  ENT="$(mktemp -t call-recorder-entitlements)"
  cat > "$ENT" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
ENTITLEMENTS

  swiftc -O -swift-version 5 \
    -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework Foundation \
    -o "$BIN" "$SRC/src/recorder.swift"
  # the app icon is made here from assets/icon.png (1024 px), with the macOS tools
  ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
  for SZ in 16 32 128 256 512; do
    sips -z $SZ $SZ "$ICON_PNG" --out "$ICONSET/icon_${SZ}x${SZ}.png" >/dev/null
    sips -z $((SZ*2)) $((SZ*2)) "$ICON_PNG" --out "$ICONSET/icon_${SZ}x${SZ}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET")"
  # ad-hoc signature: every new build has a new fingerprint, so macOS asks again for consent
  codesign --force --sign - --entitlements "$ENT" "$APP"
  rm -f "$ENT"
  echo "$HASH" > "$STAMP"
  echo "built: $APP"
  echo "NEW BUILD: run ./setup-permissions.sh (from your own Terminal) to grant the permissions again."
fi

# scripts and launchers next to the app, so the launchers keep working after plugin updates
for f in rec transcribe.py note.py pdf.py crt_config.py setup-permissions.sh diagnose-tap.sh \
         self-test.sh check-setup.sh get-model.sh "Record call.command" "Record speakerphone.command"; do
  cp "$SRC/$f" "$DEST/$f"
done
chmod +x "$DEST/rec" "$DEST"/*.sh "$DEST"/*.command "$DEST"/*.py
echo "installed in: $DEST"
echo "config file:  $CRT_CONFIG"
