#!/bin/bash
# Drain battery to target % using EC force-discharge + CPU load, then restore auto charging.
# Usage: sudo ./tools/drain_battery.sh [TARGET_PERCENT]
TARGET="${1:-84}"
BAT=/sys/class/power_supply/BAT0
cap() { cat $BAT/capacity; }

echo "$(date +%H:%M:%S) start: capacity=$(cap) status=$(cat $BAT/status) behaviour=$(cat $BAT/charge_behaviour)"

echo force-discharge > $BAT/charge_behaviour || { echo "FAILED to set force-discharge"; exit 1; }
sleep 8
st=$(cat $BAT/status)
echo "$(date +%H:%M:%S) force-discharge: status=$st current=$(cat $BAT/current_now)"
if [ "$st" != "Discharging" ]; then
    echo "force-discharge not active (status=$st); restoring auto and aborting"
    echo auto > $BAT/charge_behaviour
    exit 1
fi

# 10 load threads to speed up discharge
for i in $(seq 1 10); do timeout 2400 sha256sum /dev/zero >/dev/null 2>&1 & done

while :; do
    echo "$(date +%H:%M:%S) capacity=$(cap) current=$(cat $BAT/current_now) status=$(cat $BAT/status)"
    [ "$(cap)" -le "$TARGET" ] && break
    sleep 25
done

pkill -f 'sha256sum /dev/zero' 2>/dev/null
sleep 3
echo auto > $BAT/charge_behaviour
echo "$(date +%H:%M:%S) DONE: capacity=$(cap) current=$(cat $BAT/current_now) status=$(cat $BAT/status) behaviour=$(cat $BAT/charge_behaviour)"
