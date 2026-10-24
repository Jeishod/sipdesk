#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIRECTORY="${SIPDESK_OUTPUT_DIRECTORY:-$ROOT/build}"
mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
CONFIGURATION=release
RUN=0
for option in "$@"; do
    case "$option" in
        --debug) CONFIGURATION=debug ;;
        --run) RUN=1 ;;
        *) printf 'Usage: %s [--debug] [--run]\n' "$0"; exit 2 ;;
    esac
done

cd "$ROOT"
./Scripts/bootstrap-pjsip.sh
BUILD_ARGS=()
if [[ -n "${SIPDESK_BUILD_PATH:-}" ]]; then BUILD_ARGS=(--scratch-path "$SIPDESK_BUILD_PATH"); fi
swift build ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} -c "$CONFIGURATION" --product SIPDesk
BIN="$(swift build ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} -c "$CONFIGURATION" --show-bin-path)"
mkdir -p build/assets
xcrun swift Resources/make-icon.swift "$ROOT/build/assets"
iconutil -c icns build/assets/AppIcon.iconset -o build/assets/AppIcon.icns
/usr/bin/python3 Resources/generate-tones.py "$ROOT/build/assets"
STAGING="$(mktemp -d "$ROOT/build/.SIPDesk.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/SIPDesk.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses"
cp "$BIN/SIPDesk" "$APP/Contents/MacOS/SIPDesk"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# SwiftPM resource bundle lookup also works in the installed app.
for bundle in "$BIN"/*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
cp build/assets/AppIcon.icns build/assets/ringtone.wav build/assets/ringback.wav "$APP/Contents/Resources/"
cp .dependencies/pjsip/licenses/* "$APP/Contents/Resources/Licenses/"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
# Notarization requires a secure timestamp; ad-hoc signatures cannot carry one.
TIMESTAMP=--timestamp
if [[ "$SIGNING_IDENTITY" == "-" ]]; then TIMESTAMP=--timestamp=none; fi
codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$TIMESTAMP" \
    --entitlements Resources/SIPDesk.entitlements "$APP"
codesign --verify --deep --strict "$APP"
if [[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]]; then
    SIGNATURE="$(codesign -dvvv "$APP" 2>&1)"
    for expected in 'Authority=Developer ID Application:' 'Timestamp=' '(runtime)'; do
        if [[ "$SIGNATURE" != *"$expected"* ]]; then
            printf 'Signature is missing %s\n' "$expected" >&2
            exit 1
        fi
    done
fi
if pgrep -f "^$OUTPUT_DIRECTORY/SIPDesk.app/Contents/MacOS/SIPDesk" >/dev/null; then
    printf '\nSIPDesk is running. Quit it before replacing the built app.\n' >&2
    exit 1
fi
rm -rf "$OUTPUT_DIRECTORY/SIPDesk.app"
mv "$APP" "$OUTPUT_DIRECTORY/SIPDesk.app"
printf '\nBuilt: %s/SIPDesk.app\n' "$OUTPUT_DIRECTORY"
if [[ "$RUN" == 1 ]]; then open "$OUTPUT_DIRECTORY/SIPDesk.app"; fi

