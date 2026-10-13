#!/usr/bin/env bash
# Builds the drivers and the app into build/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/Driver/build-driver.sh"

APP="$ROOT/build/Eolyra.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/App/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT"/App/Resources/*.{icns,png} "$APP/Contents/Resources/"
cp -R "$ROOT"/App/Resources/*.lproj "$APP/Contents/Resources/"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" -o "$ROOT/build/Eolyra-$arch" "$ROOT"/App/Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/Eolyra" "$ROOT"/build/Eolyra-{arm64,x86_64}
rm "$ROOT"/build/Eolyra-{arm64,x86_64}
codesign --force --sign - "$APP"
echo "ok: $APP"
