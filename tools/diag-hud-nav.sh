#!/bin/sh
# HUD Navigation Diagnostic — run via SSH on CMU
# Usage: sh diag-hud-nav.sh
# Checks VBS/MMUI state to determine why HUD navigation arrows are missing

echo "=== HUD Navigation Diagnostic ==="
echo "Date: $(date 2>/dev/null)"
echo ""

# 1. HUD installed status
echo "--- HUD Installed Status ---"
HUD_TYPE=$(dbus-send --system --print-reply --dest=com.jci.vbs.settings \
    /com/jci/vbs/settings com.jci.vbs.settings.Query \
    string:"GetCMUControlReq" int32:26 2>/dev/null)
echo "VBS HUD type (int32:26): $HUD_TYPE"
echo ""

# 2. HUD on/off
echo "--- HUD On/Off State ---"
HUD_ONOFF=$(dbus-send --system --print-reply --dest=com.jci.vbs.settings \
    /com/jci/vbs/settings com.jci.vbs.settings.Query \
    string:"GetCMUControlReq" int32:24 2>/dev/null)
echo "VBS HUD on/off (int32:24): $HUD_ONOFF"
echo ""

# 3. HUD navigation on/off (TurnByTurn)
echo "--- HUD Navigation On/Off ---"
HUD_NAV=$(dbus-send --system --print-reply --dest=com.jci.vbs.settings \
    /com/jci/vbs/settings com.jci.vbs.settings.Query \
    string:"GetCMUControlReq" int32:25 2>/dev/null)
echo "VBS HUD nav (int32:25): $HUD_NAV"
echo ""

# 4. HUD navigation mode (CHUDNavigation)
echo "--- HUD Navigation Mode ---"
HUD_NAV_MODE=$(dbus-send --system --print-reply --dest=com.jci.vbs.settings \
    /com/jci/vbs/settings com.jci.vbs.settings.Query \
    string:"GetCMUControlReq" int32:27 2>/dev/null)
echo "VBS HUD nav mode (int32:27): $HUD_NAV_MODE"
echo ""

# 5. Region and destination code
echo "--- Region Info ---"
REGION=$(dbus-send --system --print-reply --dest=com.jci.vbs.settings \
    /com/jci/vbs/settings com.jci.vbs.settings.Query \
    string:"GetRegion" 2>/dev/null)
echo "VBS Region: $REGION"
DEST=$(dbus-send --system --print-reply --dest=com.jci.vbs.settings \
    /com/jci/vbs/settings com.jci.vbs.settings.Query \
    string:"GetDestination" 2>/dev/null)
echo "VBS Destination: $DEST"
echo ""

# 6. Check running services
echo "--- Key Services ---"
for SVC in jciMMUI jcinavi jciVBS Opera; do
    PID=$(pidof $SVC 2>/dev/null || pgrep -f $SVC 2>/dev/null)
    if [ -n "$PID" ]; then
        echo "$SVC: running (PID $PID)"
    else
        echo "$SVC: NOT RUNNING"
    fi
done
echo ""

# 7. Check LD_PRELOAD on services
echo "--- LD_PRELOAD ---"
for SVC in svcjcimmui svcjcinavi; do
    PID=$(pgrep -f $SVC 2>/dev/null | head -1)
    if [ -n "$PID" ]; then
        PRELOAD=$(cat /proc/$PID/environ 2>/dev/null | tr '\0' '\n' | grep LD_PRELOAD)
        echo "$SVC (PID $PID): ${PRELOAD:-none}"
    fi
done
echo ""

# 8. Check navi shim
echo "--- Navigation Shim ---"
if [ -f /data_persist/oem-aa-mod/libpatch-svcjcinavi.so ]; then
    echo "libpatch-svcjcinavi.so: exists ($(wc -c < /data_persist/oem-aa-mod/libpatch-svcjcinavi.so) bytes)"
else
    echo "libpatch-svcjcinavi.so: NOT FOUND"
fi
echo ""

# 9. MMUI logs
echo "--- MMUI HUD/Nav Logs (last 50) ---"
grep -i 'hud\|navi\|CHud\|TurnByTurn\|SetHud' /tmp/mmuiLog* 2>/dev/null | tail -50
echo ""

# 10. dmesg HUD errors
echo "--- dmesg HUD/Nav ---"
dmesg 2>/dev/null | grep -i 'hud\|navi\|vbs' | tail -20
echo ""

# 11. Check patched vehsettingsApp.js
echo "--- vehsettingsApp.js Patch Status ---"
VEHAPP="/jci/gui/apps/vehsettings/js/vehsettingsApp.js"
if grep -q 'tweaks:hud-eu-region' "$VEHAPP" 2>/dev/null; then
    echo "hud-eu-region patch: INSTALLED"
    grep -c 'true /\* tweaks:hud-eu-region' "$VEHAPP" 2>/dev/null | xargs echo "  region!==EU -> true replacements:"
    grep -c 'false /\* tweaks:hud-eu-region' "$VEHAPP" 2>/dev/null | xargs echo "  region===EU -> false replacements:"
    grep -c 'SelectDisplayInformation' "$VEHAPP" 2>/dev/null | xargs echo "  SelectDisplayInformation refs:"
else
    echo "hud-eu-region patch: NOT INSTALLED"
fi
echo ""

# 12. Check _cachedCHudNavindex default
echo "--- Default Nav Mode in JS ---"
grep '_cachedCHudNavindex' "$VEHAPP" 2>/dev/null | head -3
echo ""

# 13. SD card status (affects nav menu availability)
echo "--- SD Card ---"
if [ -d /mnt/sd_nav ]; then
    echo "SD nav mount: exists"
    ls /mnt/sd_nav/ 2>/dev/null | head -3
else
    echo "SD nav mount: NOT FOUND"
fi
echo ""

echo "=== Diagnostic Complete ==="
echo "Send output for analysis"
