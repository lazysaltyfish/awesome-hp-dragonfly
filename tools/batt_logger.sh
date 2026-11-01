#!/usr/bin/env bash
# Background battery charge logger. Run as root:
#   sudo ./tools/batt_logger.sh [/path/to/charge_log.csv]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${1:-$SCRIPT_DIR/charge_log.csv}"

[ -f "$LOG" ] || echo "time,soc,status,sysfs_current_uA,ec_chg_mA,ec_input_mA,bms_temp_C,bms_chg_current_mA,bms_chg_voltage_mV" >> "$LOG"
while :; do
    IFS=, read -r CHG IN TEMP BMSI BMSV <<< "$(python3 "$SCRIPT_DIR/ectool.py" --csv 2>/dev/null)"
    echo "$(date '+%m-%d %H:%M:%S'),$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null),$(cat /sys/class/power_supply/BAT0/status 2>/dev/null),$(cat /sys/class/power_supply/BAT0/current_now 2>/dev/null),$CHG,$IN,$TEMP,$BMSI,$BMSV" >> "$LOG"
    sleep 60
done
