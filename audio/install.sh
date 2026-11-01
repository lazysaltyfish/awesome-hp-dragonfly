#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/3] Installing SOF DMIC modprobe config (/etc/modprobe.d/adl-sof.conf)..."
sudo install -m 644 "$SCRIPT_DIR/adl-sof.conf" /etc/modprobe.d/adl-sof.conf

echo "[2/3] Installing WirePlumber rules (/etc/wireplumber/wireplumber.conf.d/)..."
sudo mkdir -p /etc/wireplumber/wireplumber.conf.d
sudo install -m 644 "$SCRIPT_DIR/51-disable-pro-audio.conf" /etc/wireplumber/wireplumber.conf.d/51-disable-pro-audio.conf
sudo install -m 644 "$SCRIPT_DIR/51-increase-headroom.conf" /etc/wireplumber/wireplumber.conf.d/51-increase-headroom.conf

if [[ "${1:-}" == "--hide-mic2" ]]; then
    echo "      Also installing 52-disable-mic2.conf to hide dead Mic2 channel..."
    sudo install -m 644 "$SCRIPT_DIR/52-disable-mic2.conf" /etc/wireplumber/wireplumber.conf.d/52-disable-mic2.conf
fi

echo "[3/3] Restarting PipeWire/WirePlumber and setting active Mic1 as default source..."
systemctl --user restart wireplumber pipewire pipewire-pulse || true
sleep 2

MIC1_SOURCE="alsa_input.pci-0000_00_1f.3-platform-adl_rt5682_def.HiFi__Mic1__source"
if pactl list short sources 2>/dev/null | grep -q "$MIC1_SOURCE"; then
    pactl set-default-source "$MIC1_SOURCE"
    echo "Done! Default source set to $MIC1_SOURCE"
else
    echo "Warning: $MIC1_SOURCE not yet visible. If adl-sof.conf was just installed for the first time, reboot and re-run this script."
fi
