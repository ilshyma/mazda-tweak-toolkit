#!/bin/sh
# No More Disclaimer — Uninstall
# Reverses all patches applied to systemApp.js:
#   1. Restore Dialog3Tmplt template (reverse inline sed markers)
#   2. Restore original function bindings
#   3. Remove appended _noMoreDisclaimer block (by begin/end markers)

TWEAK_DIR="$(dirname "$0")"
LIB="/data_persist/tweaks/lib/patch.sh"
[ -f "$LIB" ] || LIB="$TWEAK_DIR/../../lib/patch.sh"
. "$LIB"

SYSAPP="/jci/gui/apps/system/js/systemApp.js"

if [ ! -f "$SYSAPP" ]; then
    echo "E1: systemApp.js not found"
    exit 1
fi

if ! grep -q 'tweaks:no-disclaimer' "$SYSAPP" 2>/dev/null; then
    echo "Not installed"
    exit 0
fi

patch_begin "$SYSAPP" "no-disclaimer"

# Reverse 1: restore Dialog3Tmplt template
patch_sed 's/"template": "NoCtrlTmplt", \/\/ tweaks:no-disclaimer/"template": "Dialog3Tmplt"/g' \
    "restore Disclaimer template to Dialog3Tmplt"

# Reverse 2: restore readyFunction binding
patch_sed 's/this\._noMoreDisclaimer\.bind(this)/this._displayedDisclaimer.bind(this)/g' \
    "restore readyFunction to _displayedDisclaimer"

# Reverse 3: restore selectCallback
patch_sed 's/\/\/ tweaks:no-disclaimer removed selectCallback/defaultSelectCallback : this._selectCallbackDisclaimer.bind(this)/g' \
    "restore selectCallback"

# Reverse 4: restore displayedFunction
patch_sed 's/\/\/ tweaks:no-disclaimer removed displayedFunction/"displayedFunction" : this._displayedDisclaimer.bind(this)/g' \
    "restore displayedFunction bind"

# Remove appended _noMoreDisclaimer block by begin/end markers
patch_remove_block "tweaks:no-disclaimer" "_noMoreDisclaimer function block" "/*"

# Verify all markers removed
patch_verify_not 'tweaks:no-disclaimer' "all markers removed"

RES=$(patch_commit)
RET=$?

if [ $RET -ne 0 ]; then
    echo "$RES"
    exit 1
fi
echo "$RES"

[ "${NO_REBOOT:-0}" != "1" ] && (sleep 5 && reboot) >/dev/null 2>&1 &
