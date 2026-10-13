# Without a terminal (e.g. run from another app), sudo asks for the password in a macOS dialog.
if [ ! -t 0 ]; then
  ASKPASS="$(mktemp -t eolyra-askpass)"
  cat > "$ASKPASS" <<'AP'
#!/bin/sh
osascript -e 'text returned of (display dialog "Eolyra needs your administrator password to install or remove its audio drivers." with title "Eolyra" default answer "" with hidden answer with icon caution)'
AP
  chmod 700 "$ASKPASS"
  export SUDO_ASKPASS="$ASKPASS"
  trap 'rm -f "$ASKPASS"' EXIT
  sudo() { command sudo -A "$@"; }
fi
