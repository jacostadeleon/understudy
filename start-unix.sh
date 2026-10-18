#!/bin/sh
# understudy one-click launcher for macOS and Linux
# - mac: status-bar icon (needs PyObjC, preinstalled on recent macOS)
# - linux: tray icon via pystray+pillow (pip3 install --user pystray pillow)
# - without a GUI toolkit it still works: keeps the proxy alive headlessly
DIR="$(cd "$(dirname "$0")" && pwd)"

PY=python3
command -v python3 >/dev/null 2>&1 || PY=python

if [ "$1" = "--headless" ]; then
  exec "$PY" "$DIR/tray.py" --headless
fi

"$PY" "$DIR/tray.py"
