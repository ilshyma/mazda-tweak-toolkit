#!/bin/sh
# Touchscreen While Moving — Uninstall
# Reverses Common.js patch and re-enables speed restriction

TWEAK_DIR="$(dirname "$0")"
LIB="/data_persist/tweaks/lib/patch.sh"
[ -f "$LIB" ] || LIB="$TWEAK_DIR/../../lib/patch.sh"
. "$LIB"

COMMON="/jci/gui/common/js/Common.js"

if [ ! -f "$COMMON" ]; then
    echo "E1: Common.js not found"
    exit 1
fi

if ! grep -q 'tweaks:touch-while-moving' "$COMMON" 2>/dev/null; then
    echo "Not installed"
    exit 0
fi

# Re-enable NVRAM speed restrictions
[ -x /jci/scripts/set_speed_restriction_config.sh ] && \
    /jci/scripts/set_speed_restriction_config.sh enable 2>/dev/null
[ -x /jci/scripts/set_lvds_speed_restriction_config.sh ] && \
    /jci/scripts/set_lvds_speed_restriction_config.sh enable 2>/dev/null

# Reverse the JS patch: uncomment Global.AtSpeed lines and remove marker
patch_begin "$COMMON" "touch-while-moving"

patch_sed 's/ \/\/ tweaks:touch-while-moving "Global\.AtSpeed/ "Global.AtSpeed/g' \
    "restore Global.AtSpeed handler"

patch_verify_not 'tweaks:touch-while-moving' "all markers removed"
patch_verify ' "Global\.AtSpeed' "AtSpeed handler active"

RES=$(patch_commit)
RET=$?

if [ $RET -ne 0 ]; then
    echo "$RES"
    exit 1
fi
echo "$RES"

[ "${NO_REBOOT:-0}" != "1" ] && (sleep 5 && reboot) >/dev/null 2>&1 &
