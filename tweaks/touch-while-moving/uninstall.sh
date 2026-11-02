#!/bin/sh
# Touchscreen While Moving — Uninstall
# Restores Common.js from backup and re-enables speed restriction

TWEAK_DIR="$(dirname "$0")"
LIB="/data_persist/tweaks/lib/patch.sh"
[ -f "$LIB" ] || LIB="$TWEAK_DIR/../../lib/patch.sh"
. "$LIB"

COMMON="/jci/gui/common/js/Common.js"

mount -o remount,rw / 2>/dev/null

# Re-enable NVRAM speed restrictions
[ -x /jci/scripts/set_speed_restriction_config.sh ] && \
    /jci/scripts/set_speed_restriction_config.sh enable 2>/dev/null
[ -x /jci/scripts/set_lvds_speed_restriction_config.sh ] && \
    /jci/scripts/set_lvds_speed_restriction_config.sh enable 2>/dev/null

# Restore original Common.js
patch_rollback "$COMMON"
RET=$?

mount -o remount,ro / 2>/dev/null

[ $RET -eq 0 ] && [ "${NO_REBOOT:-0}" != "1" ] && (sleep 5 && reboot) >/dev/null 2>&1 &
exit $RET
