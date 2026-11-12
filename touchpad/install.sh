#!/usr/bin/env bash
# Issue 6: Touchpad / cursor frame drops & initial-stroke stutter on Redrix.
#   1. Disables broken i915 PSR2 Selective Fetch on Alder Lake-P + BOE eDP
#      (fixes Pipe A selective fetch errors & drmModeAtomicCommit -EBUSY drops).
#   2. Keeps both LPSS PCI bridges (00:19.1, 00:15.3) AND child i2c_designware
#      platform controllers awake (fixes 1s runtime autosuspend & touch jumps).
#
# Usage:
#   ./touchpad/install.sh              install (default: i915.enable_psr=0)
#   ./touchpad/install.sh --psr1       install with PSR1 fallback (enable_psr=1 enable_psr2_sel_fetch=0)
#   ./touchpad/install.sh --uninstall  remove configs & restore defaults
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULE=/etc/udev/rules.d/99-touchpad-i2c-no-pm.rules
MODPROBE_CONF=/etc/modprobe.d/i915-psr.conf

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

if [ "${1:-}" = "--uninstall" ]; then
    echo "[1/3] Removing $RULE and $MODPROBE_CONF ..."
    $SUDO rm -f "$RULE" "$MODPROBE_CONF"

    echo "[2/3] Removing i915 PSR kernel cmdline arguments ..."
    if command -v grubby >/dev/null 2>&1; then
        $SUDO grubby --update-kernel=ALL --remove-args="i915.enable_psr i915.enable_psr2_sel_fetch"
    fi

    echo "[3/3] Reloading udev and restoring runtime PM auto control ..."
    $SUDO udevadm control --reload-rules
    for p in /sys/devices/pci0000:00/0000:00:19.1 /sys/devices/pci0000:00/0000:00:15.3 \
             /sys/devices/pci0000:00/0000:00:19.1/i2c_designware.* \
             /sys/devices/pci0000:00/0000:00:15.3/i2c_designware.*; do
        [ -w "$p/power/control" ] && echo auto | $SUDO tee "$p/power/control" >/dev/null || true
    done
    echo "Done. Reboot to restore default i915 PSR behaviour."
    exit 0
fi

echo "[1/3] Installing udev rule -> $RULE"
$SUDO install -Dm644 "$SCRIPT_DIR/99-touchpad-i2c-no-pm.rules" "$RULE"
$SUDO restorecon "$RULE" 2>/dev/null || true

echo "[2/3] Reloading udev and waking LPSS + DesignWare I2C controllers ..."
$SUDO udevadm control --reload-rules
$SUDO udevadm trigger --action=change --subsystem-match=pci --sysname-match="0000:00:19.1"
$SUDO udevadm trigger --action=change --subsystem-match=pci --sysname-match="0000:00:15.3"
$SUDO udevadm trigger --action=change --subsystem-match=platform --sysname-match="i2c_designware.*"
$SUDO udevadm settle

if [ "${1:-}" = "--psr1" ]; then
    KARGS="i915.enable_psr=1 i915.enable_psr2_sel_fetch=0"
    echo "[3/3] Configuring i915 PSR1 fallback ($KARGS) ..."
    printf '# Fallback to PSR1 without broken PSR2 Selective Fetch\noptions i915 enable_psr=1 enable_psr2_sel_fetch=0\n' \
        | $SUDO tee "$MODPROBE_CONF" >/dev/null
    $SUDO chmod 644 "$MODPROBE_CONF"
else
    KARGS="i915.enable_psr=0"
    echo "[3/3] Disabling i915 PSR ($KARGS) ..."
    $SUDO install -Dm644 "$SCRIPT_DIR/i915-psr.conf" "$MODPROBE_CONF"
fi
$SUDO restorecon "$MODPROBE_CONF" 2>/dev/null || true

if command -v grubby >/dev/null 2>&1; then
    $SUDO grubby --update-kernel=ALL --remove-args="i915.enable_psr i915.enable_psr2_sel_fetch"
    $SUDO grubby --update-kernel=ALL --args="$KARGS"
else
    echo "Warning: grubby not found; installed $MODPROBE_CONF (rebuild initramfs or add '$KARGS' to bootloader)."
fi

echo "=== Runtime PM Verification ==="
for p in /sys/devices/pci0000:00/0000:00:19.1 \
         /sys/devices/pci0000:00/0000:00:19.1/i2c_designware.* \
         /sys/devices/pci0000:00/0000:00:15.3 \
         /sys/devices/pci0000:00/0000:00:15.3/i2c_designware.*; do
    [ -e "$p/power/control" ] || continue
    echo "  $p: control=$(cat "$p/power/control") status=$(cat "$p/power/runtime_status")"
done

if [ -r /etc/kernel/cmdline ]; then
    echo "=== Kernel Cmdline (/etc/kernel/cmdline) ==="
    echo "  $(cat /etc/kernel/cmdline)"
fi
echo "Done! I2C runtime PM fix is active immediately; reboot once to activate $KARGS."
