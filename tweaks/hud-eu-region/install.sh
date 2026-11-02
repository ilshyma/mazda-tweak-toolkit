#!/bin/sh
# HUD EU Region Unlock — Install
# Removes region gate from vehsettingsApp.js to expose
# Street Information and extended Navigation modes on EU CMUs
#
# Changes:
#   1. _HUDDispInfoCtxtIn: region !== "Region_Europe" → true
#   2. _CHUDNavigationCtxtIn: region === "Region_Europe" → false
#   3. Add "Display Information" item to standard HUD tab (only J78A/J36 had it)

TWEAK_DIR="$(dirname "$0")"
LIB="/data_persist/tweaks/lib/patch.sh"
[ -f "$LIB" ] || LIB="$TWEAK_DIR/../../lib/patch.sh"
. "$LIB"

VEHAPP="/jci/gui/apps/vehsettings/js/vehsettingsApp.js"

if [ ! -f "$VEHAPP" ]; then
    echo "E1: vehsettingsApp.js not found"
    exit 1
fi

if grep -q 'tweaks:hud-eu-region' "$VEHAPP" 2>/dev/null; then
    echo "Already installed"
    echo "OK"
    exit 0
fi

# Check HUD is installed (D-Bus query)
HUD_TYPE=""
if command -v dbus-send >/dev/null 2>&1; then
    HUD_TYPE=$(dbus-send --system --print-reply --dest=com.jci.vbs.settings \
        /com/jci/vbs/settings com.jci.vbs.settings.Query \
        string:"GetCMUControlReq" int32:26 2>/dev/null | grep variant | awk '{print $3}' | tr -d '"')
fi

if [ -n "$HUD_TYPE" ] && [ "$HUD_TYPE" = "0" ]; then
    echo "E2: No HUD detected on this unit"
    exit 1
fi

mount -o remount,rw / 2>/dev/null

patch_begin "$VEHAPP" "hud-eu-region"

# Patch 1: _HUDDispInfoCtxtIn — remove region check so Street Info appears
patch_sed 's/region !== "Region_Europe"/true \/* tweaks:hud-eu-region *\//g' \
    "unlock Street Info for EU"

# Patch 2: _CHUDNavigationCtxtIn — unlock extended nav modes
patch_sed 's/region === "Region_Europe"/false \/* tweaks:hud-eu-region *\//g' \
    "unlock extended nav modes for EU"

# Patch 3: Add "Display Information" item to standard HUD tab
#   The standard HUD tab only has a simple Navigation On/Off toggle.
#   J78A/J36 models have a "Display Information" caret item that leads to
#   the sub-menu with StreetInformation and extended nav modes.
#   We hook _HUDTabCtxtIn to inject this item at runtime.
patch_append '/* tweaks:hud-eu-region — add Display Information to standard HUD tab */
(function(){
    var _origCtxtIn = vehsettingsApp.prototype._HUDTabCtxtIn;
    vehsettingsApp.prototype._HUDTabCtxtIn = function() {
        var list = this._HUDTabCtxtDataListBrightnessControlOn;
        if (list && list.items) {
            var found = false;
            for (var i = 0; i < list.items.length; i++) {
                if (list.items[i].appData === "SelectDisplayInformation") { found = true; break; }
            }
            if (!found) {
                list.items.push({ appData: "SelectDisplayInformation", text1Id: "DisplayInformation", hasCaret: true, itemStyle: "style01" });
                list.itemCount = list.items.length;
            }
        }
        _origCtxtIn.call(this);
    };
})();' "add Display Information item to HUD tab"

# Verify
patch_verify 'tweaks:hud-eu-region' "marker present"
patch_verify_not 'region !== "Region_Europe"' "old EU gate removed"
patch_verify 'SelectDisplayInformation.*DisplayInformation' "Display Information item added"

RES=$(patch_commit)
RET=$?

mount -o remount,ro / 2>/dev/null

if [ $RET -ne 0 ]; then
    echo "$RES"
    exit 1
fi
echo "$RES"

(sleep 5 && reboot) >/dev/null 2>&1 &
