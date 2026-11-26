#!/bin/sh
# WiFi Access Point — Uninstall
# Removes WiFi AP autostart from stage_wifi.sh

TWEAK_DIR="${TWEAK_DIR:-$(dirname "$0")}"
LIB="${TWEAKS_LIB:-/data_persist/tweaks/lib/patch.sh}"
[ -f "$LIB" ] || LIB="$TWEAK_DIR/../../lib/patch.sh"
. "$LIB"

STAGE_WIFI="/jci/scripts/stage_wifi.sh"

if ! grep -q 'tweaks:wifi-ap:begin' "$STAGE_WIFI" 2>/dev/null; then
    echo "Not installed"
    exit 0
fi

patch_begin "$STAGE_WIFI" "wifi-ap"
patch_remove_block "tweaks:wifi-ap" "WiFi AP + iptables block"
patch_verify_not 'tweaks:wifi-ap' "markers removed"

RES=$(patch_commit)
RET=$?

if [ $RET -ne 0 ]; then
    echo "$RES"
    exit 1
fi
echo "$RES"

[ "${NO_REBOOT:-0}" != "1" ] && (sleep 5 && reboot) >/dev/null 2>&1 &
