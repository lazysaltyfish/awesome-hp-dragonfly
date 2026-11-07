#!/usr/bin/env bash
# Issue 5: Thunderbolt 3 docks not detected (kernel auto-enters DP alt mode,
# TBT alt mode is never entered). Installs a udev policy that mimics ChromeOS
# typecd: prefer TBT3, fall back to DP.
#
#   ./thunderbolt/install.sh              install (idempotent)
#   ./thunderbolt/install.sh --uninstall  remove (replug/reboot restores kernel default)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN=/usr/local/libexec/typec-mode-policy
RULE=/etc/udev/rules.d/90-typec-mode-policy.rules

if [ "${1:-}" = "--uninstall" ]; then
	echo "Removing $BIN and $RULE ..."
	sudo rm -f "$BIN" "$RULE"
	sudo udevadm control --reload-rules
	echo "Done. Replug devices or reboot to restore the default kernel behaviour."
	exit 0
fi

echo "[1/3] Installing alt mode policy script -> $BIN"
sudo install -Dm755 "$SCRIPT_DIR/typec-mode-policy" "$BIN"

echo "[2/3] Installing udev rule -> $RULE"
sudo install -Dm644 "$SCRIPT_DIR/90-typec-mode-policy.rules" "$RULE"
sudo restorecon "$BIN" "$RULE" 2>/dev/null || true

echo "[3/3] Reloading udev and applying port settings (DP auto-entry off, TBT on)"
sudo udevadm control --reload-rules
sudo udevadm trigger --action=add --subsystem-match=typec --sysname-match='port[0-9].[0-9]*'
sudo udevadm settle

for a in /sys/class/typec/port*/port*.[0-9]; do
	[ -e "$a/svid" ] && echo "  $(basename "$a"): svid=$(cat "$a/svid") active=$(cat "$a/active")"
done
echo "Done! Replug the Thunderbolt dock (anything plugged in before install keeps its old state)."
