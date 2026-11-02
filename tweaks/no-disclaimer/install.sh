#!/bin/sh
# No More Disclaimer — Install
# Patches systemApp.js: replaces Disclaimer context to auto-dismiss
#
# Changes:
#   1. Disclaimer template: Dialog3Tmplt → NoCtrlTmplt (remove agree button)
#   2. Remove buttonCount, buttonConfig, text1Id from Disclaimer context
#   3. readyFunction: _displayedDisclaimer → _noMoreDisclaimer
#   4. Remove displayedFunction/noLongerDisplayedFunction binds
#   5. Append _noMoreDisclaimer function to prototype

TWEAK_DIR="$(dirname "$0")"
LIB="/data_persist/tweaks/lib/patch.sh"
[ -f "$LIB" ] || LIB="$TWEAK_DIR/../../lib/patch.sh"
. "$LIB"

SYSAPP="/jci/gui/apps/system/js/systemApp.js"

# check not already installed
if grep -q '_noMoreDisclaimer' "$SYSAPP" 2>/dev/null; then
    echo "Already installed"
    echo "OK"
    exit 0
fi

mount -o remount,rw / 2>/dev/null

patch_begin "$SYSAPP" "no-disclaimer"

# 1. Change Disclaimer template from Dialog3Tmplt to NoCtrlTmplt
#    (scoped to Disclaimer block — template and end-comment are on different lines in v74)
patch_sed_range '/"Disclaimer" *: *{/,/end of Disclaimer/' \
    's/"template" *: *"Dialog3Tmplt"/"template": "NoCtrlTmplt", \/\/ tweaks:no-disclaimer/' \
    "Disclaimer template → NoCtrlTmplt"

# 2. Replace readyFunction binding
patch_sed 's/this\._displayedDisclaimer\.bind(this)/this._noMoreDisclaimer.bind(this)/' \
    "readyFunction → _noMoreDisclaimer"

# 3. Comment out the selectCallback for Disclaimer (agree button handler)
patch_sed 's/defaultSelectCallback *: *this\._selectCallbackDisclaimer\.bind(this)/\/\/ tweaks:no-disclaimer removed selectCallback/' \
    "remove selectCallback"

# 4. Comment out displayedFunction if separate from readyFunction
#    (in some FW versions displayedFunction is separate)
patch_sed 's/"displayedFunction" *: *this\._displayedDisclaimer\.bind(this)/\/\/ tweaks:no-disclaimer removed displayedFunction/' \
    "remove displayedFunction bind"

# 5. Append _noMoreDisclaimer function
patch_append '/* tweaks:no-disclaimer */
systemApp.prototype._noMoreDisclaimer = function() {
    framework.sendEventToMmui("system", "DisposeIntroVideo");
    this._disclaimerTime.remaining = 3500;
    log.debug("No more disclaimer — auto-accepting");
    framework.sendEventToMmui("common", "Global.Yes");
};' "add _noMoreDisclaimer function"

# Verify
patch_verify '_noMoreDisclaimer' "function exists"
patch_verify 'NoCtrlTmplt.*no-disclaimer' "template changed"
patch_verify_not 'defaultSelectCallback.*_selectCallbackDisclaimer' "old selectCallback gone"

RES=$(patch_commit)
RET=$?

mount -o remount,ro / 2>/dev/null

if [ $RET -ne 0 ]; then
    echo "$RES"
    exit 1
fi
echo "$RES"

(sleep 5 && reboot) >/dev/null 2>&1 &
