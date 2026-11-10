#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/build-environment.sh
build="$DUO_BUILD_ROOT/microphone"
mkdir -p "$build"
bundle="$build/DuoMicrophone.driver"
mkdir -p "$bundle/Contents/MacOS"
cp Drivers/DuoMicrophone/Info.plist "$bundle/Contents/Info.plist"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
    xcrun clang -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -Werror \
        -arch "$arch" -isysroot "$sdk" -mmacosx-version-min=14.0 -bundle -fvisibility=hidden \
        -I Sources/DuoMicrophoneBridge/include Drivers/DuoMicrophone/DuoMicrophone.c Drivers/DuoMicrophone/MicrophoneBuffer.c \
        -framework CoreAudio -framework CoreFoundation -o "$build/DuoMicrophone-$arch"
done
xcrun lipo -create "$build/DuoMicrophone-arm64" "$build/DuoMicrophone-x86_64" \
    -output "$bundle/Contents/MacOS/DuoMicrophone"
codesign --force --sign - --timestamp=none "$bundle"
codesign --verify --strict "$bundle"
root="$build/package-root"
mkdir -p "$root/Library/Audio/Plug-Ins/HAL"
ditto "$bundle" "$root/Library/Audio/Plug-Ins/HAL/DuoMicrophone.driver"
# The installed driver is read by _coreaudiod, not the root package owner.
chmod -R u=rwX,go=rX "$root"
pkgbuild --root "$root" --identifier local.duoworkspace.microphone \
    --version "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Drivers/DuoMicrophone/Info.plist)" --scripts Scripts/MicrophoneInstaller "$build/DuoMicrophone.pkg" >/dev/null
if [[ -n "${1:-}" ]]; then
    mkdir -p "$1"
    cp "$build/DuoMicrophone.pkg" "$1/DuoMicrophone.pkg"
fi
echo "Built Duo Microphone driver and installer."
