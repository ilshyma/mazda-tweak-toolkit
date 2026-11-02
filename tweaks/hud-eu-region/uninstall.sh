#!/bin/sh
# HUD EU Region Unlock — Uninstall
# Restores original vehsettingsApp.js from backup

TWEAK_DIR="$(dirname "$0")"
LIB="/data_persist/tweaks/lib/patch.sh"
[ -f "$LIB" ] || LIB="$TWEAK_DIR/../../lib/patch.sh"
. "$LIB"

VEHAPP="/jci/gui/apps/vehsettings/js/vehsettingsApp.js"

mount -o remount,rw / 2>/dev/null

patch_rollback "$VEHAPP"
RET=$?

mount -o remount,ro / 2>/dev/null

[ $RET -eq 0 ] && [ "${NO_REBOOT:-0}" != "1" ] && (sleep 5 && reboot) >/dev/null 2>&1 &
exit $RET
