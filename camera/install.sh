#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/3] Installing OV5675 libcamera SoftISP tuning file..."
sudo mkdir -p /usr/share/libcamera/ipa/simple
sudo install -m 644 "$SCRIPT_DIR/ov5675-clean.yaml" /usr/share/libcamera/ipa/simple/ov5675.yaml

echo "[2/3] Granting Flatpak camera permission to Google Chrome (bypasses portal focus bug)..."
if command -v flatpak >/dev/null 2>&1; then
    flatpak permission-set devices camera com.google.Chrome yes || true
fi

echo "[3/3] Restarting PipeWire & WirePlumber..."
systemctl --user restart wireplumber pipewire || true

echo "Done! Reminder: ensure chrome://flags/#enable-webrtc-pipewire-camera is Enabled in Chrome."
