#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=2.17-dev
REVISION=c7fa6bfb85172f038cf37986696a16b3987391ea
CHECKSUM=a1c0d3e97b240d8ea71f599f3538d81fc3f8b1237154cef9accc604f5f3b3cda
PREFIX="$ROOT/.dependencies/pjsip"
ARCHIVE="$ROOT/.dependencies/downloads/pjproject-$REVISION.tar.gz"
SOURCE="$ROOT/.dependencies/pjproject-$REVISION"
FINGERPRINT="$REVISION-$(uname -m)-macos14-apple-tls-v3"

if [[ -f "$PREFIX/.fingerprint" ]] && [[ "$(cat "$PREFIX/.fingerprint")" == "$FINGERPRINT" ]] && [[ -f "$PREFIX/lib/libSIPStack.a" ]]; then
    printf 'PJSIP %s is ready.\n' "$VERSION"
    exit 0
fi

xcrun --find clang >/dev/null
mkdir -p "$(dirname "$ARCHIVE")" "$PREFIX"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 3 --connect-timeout 20 \
        "https://github.com/pjsip/pjproject/archive/$REVISION.tar.gz" \
        --output "$ARCHIVE.partial"
    mv "$ARCHIVE.partial" "$ARCHIVE"
fi
printf '%s  %s\n' "$CHECKSUM" "$ARCHIVE" | shasum -a 256 -c -
if [[ -d "$SOURCE" ]]; then
    rm -rf "$SOURCE"
fi
tar -xzf "$ARCHIVE" -C "$ROOT/.dependencies"
cp "$ROOT/Resources/pjsip-config.h" "$SOURCE/pjlib/include/pj/config_site.h"

export MACOSX_DEPLOYMENT_TARGET=14.0
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC="$(xcrun --find clang)"
export CXX="$(xcrun --find clang++)"
export CFLAGS="-O2 -DNDEBUG -mmacosx-version-min=14.0 -isysroot $SDKROOT"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-framework Network -framework Security"

cd "$SOURCE"
./configure --prefix="$PREFIX" \
    --disable-shared --disable-pjsua2 --disable-video \
    --disable-sdl --disable-ffmpeg --disable-v4l2 --disable-openh264 \
    --disable-libyuv --disable-libwebrtc --disable-libwebrtc-aec3 \
    --disable-opencore-amr --disable-silk --disable-opus \
    --disable-g7221-codec --disable-ilbc-codec --disable-gsm-codec \
    --disable-darwin-ssl
make dep
make -j "$(sysctl -n hw.logicalcpu)" lib
make install
rm -f "$PREFIX/lib/libSIPStack.a"
/usr/bin/libtool -static -o "$PREFIX/lib/libSIPStack.a" "$PREFIX"/lib/lib*.a
mkdir -p "$PREFIX/licenses"
cp COPYING "$PREFIX/licenses/PJSIP-COPYING.txt"
cp third_party/speex/COPYING "$PREFIX/licenses/Speex-COPYING.txt"
cp third_party/resample/COPYING "$PREFIX/licenses/Resample-COPYING.txt"
cp third_party/srtp/LICENSE "$PREFIX/licenses/SRTP-LICENSE.txt"
printf '%s\n' "$REVISION" > "$PREFIX/licenses/UPSTREAM-REVISION.txt"
printf '%s\n' "$FINGERPRINT" > "$PREFIX/.fingerprint"
printf '\nPJSIP %s built for %s with native Apple TLS.\n' "$VERSION" "$(uname -m)"

