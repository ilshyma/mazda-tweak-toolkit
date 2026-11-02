#!/bin/sh
# No More Disclaimer — Uninstall
# Restores original systemApp.js from backup

TWEAK_DIR="$(dirname "$0")"
LIB="/data_persist/tweaks/lib/patch.sh"
[ -f "$LIB" ] || LIB="$TWEAK_DIR/../../lib/patch.sh"
. "$LIB"

SYSAPP="/jci/gui/apps/system/js/systemApp.js"

mount -o remount,rw / 2>/dev/null

patch_rollback "$SYSAPP"
RET=$?

mount -o remount,ro / 2>/dev/null

[ $RET -eq 0 ] && [ "${NO_REBOOT:-0}" != "1" ] && (sleep 5 && reboot) >/dev/null 2>&1 &
exit $RET
