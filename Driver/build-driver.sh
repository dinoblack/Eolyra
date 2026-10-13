#!/usr/bin/env bash
# Builds Eolyra.driver (AudioServerPlugIn) into build/drivers/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/drivers/Eolyra.driver/Contents"
rm -rf "$ROOT/build/drivers"; mkdir -p "$OUT/MacOS"
clang -bundle -O2 -Wall -Wextra -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
  -fvisibility=hidden -framework CoreAudio -framework CoreFoundation \
  -o "$OUT/MacOS/Eolyra" "$ROOT/Driver/EolyraDriver.c"
cp "$ROOT/Driver/Info.plist" "$OUT/Info.plist"
codesign --force --sign - "$ROOT/build/drivers/Eolyra.driver"
echo "ok: $ROOT/build/drivers/Eolyra.driver"
