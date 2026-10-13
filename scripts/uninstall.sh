#!/usr/bin/env bash
# Removes the Eolyra app, drivers and preferences.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib-sudo.sh"
pkill -x Eolyra 2>/dev/null || true
rm -rf /Applications/Eolyra.app
defaults delete app.eolyra.Eolyra 2>/dev/null || true
sudo /bin/sh -c '
  rm -rf /Library/Audio/Plug-Ins/HAL/Eolyra.driver
  killall coreaudiod
'
echo "Eolyra removed."
