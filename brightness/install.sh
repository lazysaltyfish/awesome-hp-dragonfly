#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/4] Installing udev rule for cros-ec-light (OPT3001) & intel_backlight..."
sudo install -m 644 "$SCRIPT_DIR/99-redrix-als.rules" /etc/udev/rules.d/99-redrix-als.rules
sudo chmod 0666 /sys/class/backlight/intel_backlight/brightness || true
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=iio --attr-match=name=cros-ec-light

echo "[2/4] Disabling buggy gsd-power relative ambient normalization..."
gsettings set org.gnome.settings-daemon.plugins.power ambient-enabled false
gdbus call --session --dest org.gnome.Shell.Brightness \
  --object-path /org/gnome/Shell/Brightness \
  --method org.gnome.Shell.Brightness.SetAutoBrightnessTarget -- -1.0 >/dev/null 2>&1 || true

echo "[3/4] Installing GNOME Shell extension (redrix-auto-brightness@local)..."
EXT_DIR="$HOME/.local/share/gnome-shell/extensions/redrix-auto-brightness@local"
mkdir -p "$EXT_DIR"
install -m 644 "$SCRIPT_DIR/redrix-auto-brightness@local/metadata.json" "$EXT_DIR/metadata.json"
install -m 644 "$SCRIPT_DIR/redrix-auto-brightness@local/extension.js" "$EXT_DIR/extension.js"

python3 - <<'PY'
import subprocess, ast
cur = subprocess.check_output(["gsettings", "get", "org.gnome.shell", "enabled-extensions"], text=True).strip()
exts = ast.literal_eval(cur) if cur.startswith("[") else []
if "redrix-auto-brightness@local" not in exts:
    exts.append("redrix-auto-brightness@local")
    subprocess.run(["gsettings", "set", "org.gnome.shell", "enabled-extensions", str(exts)], check=True)
PY

echo "[4/4] Installing & starting user-space fallback service (active immediately)..."
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
install -m 755 "$SCRIPT_DIR/redrix-auto-brightness" "$HOME/.local/bin/redrix-auto-brightness"
install -m 644 "$SCRIPT_DIR/redrix-auto-brightness.service" "$HOME/.config/systemd/user/redrix-auto-brightness.service"
systemctl --user daemon-reload
systemctl --user enable --now redrix-auto-brightness.service

echo "Done! Perceptual Gamma 2.2 + logarithmic auto-brightness is now active."
