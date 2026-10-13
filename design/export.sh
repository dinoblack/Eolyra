#!/usr/bin/env bash
# Regenera os assets a partir dos SVGs: ícone do app (.icns), ícones da barra de menus e ícone do README.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; ROOT="$D/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
swiftc -O -o "$TMP/render" "$D/render.swift"

ICONSET="$TMP/AppIcon.iconset"; mkdir "$ICONSET"
for s in 16 32 128 256 512; do
  "$TMP/render" "$D/logo.svg" "$ICONSET/icon_${s}x${s}.png" $s
  "$TMP/render" "$D/logo.svg" "$ICONSET/icon_${s}x${s}@2x.png" $((s * 2))
done
iconutil -c icns -o "$ROOT/App/Resources/AppIcon.icns" "$ICONSET"

for pair in menubar:MenuBar menubar-muted:MenuBarMuted; do
  src="${pair%%:*}" out="${pair#*:}"
  "$TMP/render" "$D/$src.svg" "$ROOT/App/Resources/$out.png" 18
  "$TMP/render" "$D/$src.svg" "$ROOT/App/Resources/$out@2x.png" 36
done

"$TMP/render" "$D/logo.svg" "$D/icon-256.png" 256
echo "assets gerados"
