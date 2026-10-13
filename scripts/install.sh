#!/usr/bin/env bash
# Installs the drivers into /Library/Audio/Plug-Ins/HAL and the app into /Applications (asks for an admin password).
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib-sudo.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$ROOT/build/Eolyra.app" ] || "$ROOT/scripts/build.sh"

pkill -x Eolyra 2>/dev/null || true
rm -rf /Applications/Eolyra.app
cp -R "$ROOT/build/Eolyra.app" /Applications/

echo "Installing drivers and restarting CoreAudio (sound will drop for 1-2 s)..."
sudo /bin/sh -c '
  HAL=/Library/Audio/Plug-Ins/HAL
  rm -rf "$HAL/Eolyra.driver"
  ditto "$1/Eolyra.driver" "$HAL/Eolyra.driver"
  chown -R root:wheel "$HAL/Eolyra.driver"
  killall coreaudiod
' _ "$ROOT/build/drivers"
sleep 3
open /Applications/Eolyra.app
echo "Done. Look for the headphones icon in the menu bar."
