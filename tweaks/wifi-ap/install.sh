#!/bin/sh
# WiFi Access Point — Install
# Enables WiFi AP on the CMU with iptables flush.
# Patches stage_wifi.sh for persistent WiFi AP on boot.

TWEAK_DIR="${TWEAK_DIR:-$(dirname "$0")}"
LIB="${TWEAKS_LIB:-/data_persist/tweaks/lib/patch.sh}"
[ -f "$LIB" ] || LIB="$TWEAK_DIR/../../lib/patch.sh"
. "$LIB"

STAGE_WIFI="/jci/scripts/stage_wifi.sh"

if [ ! -f "$STAGE_WIFI" ]; then
    echo "E1: stage_wifi.sh not found"
    exit 1
fi

if grep -q '# tweaks:wifi-ap:begin' "$STAGE_WIFI" 2>/dev/null; then
    echo "Already installed"
    echo "OK"
    exit 0
fi

patch_begin "$STAGE_WIFI" "wifi-ap"

patch_append_block "tweaks:wifi-ap" \
'/jci/scripts/jci-fw.sh stop 2>/dev/null &
/jci/scripts/jci-wifiap.sh start 2>/dev/null &' \
"WiFi AP: disable firewall + start AP (background to not block boot)"

patch_verify 'tweaks:wifi-ap:begin' "marker exists"

RES=$(patch_commit)
RET=$?

if [ $RET -ne 0 ]; then
    echo "$RES"
    exit 1
fi
echo "$RES"

# Apply immediately (load module → drop firewall → start AP)
/jci/scripts/start_wifi.sh 2>/dev/null || true
/jci/scripts/jci-fw.sh stop 2>/dev/null || true
/jci/scripts/jci-wifiap.sh start 2>/dev/null || true
echo "WiFi AP enabled (192.168.53.1)"
