#!/bin/sh
# Touchscreen While Moving — Install
# Disables speed restriction on touchscreen via NVRAM + GUI patch
#
# Changes:
#   1. NVRAM: disable speed restriction configs
#   2. Common.js: comment out "Global.AtSpeed" handler

TWEAK_DIR="$(dirname "$0")"
LIB="/data_persist/tweaks/lib/patch.sh"
[ -f "$LIB" ] || LIB="$TWEAK_DIR/../../lib/patch.sh"
. "$LIB"

COMMON="/jci/gui/common/js/Common.js"

# check not already installed
if grep -q '\/\/"Global\.AtSpeed' "$COMMON" 2>/dev/null; then
    echo "Already installed"
    echo "OK"
    exit 0
fi

mount -o remount,rw / 2>/dev/null

# NVRAM speed restrictions (these are separate from the JS patch)
[ -x /jci/scripts/set_speed_restriction_config.sh ] && \
    /jci/scripts/set_speed_restriction_config.sh disable 2>/dev/null
[ -x /jci/scripts/set_lvds_speed_restriction_config.sh ] && \
    /jci/scripts/set_lvds_speed_restriction_config.sh disable 2>/dev/null

# Patch Common.js
patch_begin "$COMMON" "touch-while-moving"

patch_sed 's/ "Global\.AtSpeed/ \/\/"Global.AtSpeed/g' \
    "comment out Global.AtSpeed handler"

patch_verify '\/\/"Global\.AtSpeed' "AtSpeed commented out"
patch_verify_not ' "Global\.AtSpeed' "no active AtSpeed handler"

RES=$(patch_commit)
RET=$?

mount -o remount,ro / 2>/dev/null

if [ $RET -ne 0 ]; then
    echo "$RES"
    exit 1
fi
echo "$RES"

(sleep 5 && reboot) >/dev/null 2>&1 &
