#!/bin/sh
# HUD Navigation Fix — run via SSH on CMU
# Attempts to restore HUD turn-by-turn navigation arrows
# Usage: sh fix-hud-nav.sh [diagnose|fix|reset]
#   diagnose — show current state only (default)
#   fix      — try to re-enable navigation via D-Bus
#   reset    — toggle navigation off then on (last resort)

ACTION="${1:-diagnose}"

log() { echo "[hud-fix] $*"; }

get_vbs() {
    dbus-send --system --print-reply --dest=com.jci.vbs.settings \
        /com/jci/vbs/settings com.jci.vbs.settings.Query \
        string:"$1" $2 2>/dev/null | grep -E 'variant|string|int32|boolean' | head -1
}

set_vbs() {
    dbus-send --system --dest=com.jci.vbs.settings \
        /com/jci/vbs/settings com.jci.vbs.settings.Set \
        string:"$1" $2 2>/dev/null
}

send_mmui() {
    dbus-send --system --dest=com.jci.lds \
        /com/jci/lds com.jci.lds.Send \
        string:"$1" string:"$2" 2>/dev/null
}

diagnose() {
    log "=== Current HUD Navigation State ==="

    log "HUD installed: $(get_vbs GetCMUControlReq int32:26)"
    log "HUD on/off:    $(get_vbs GetCMUControlReq int32:24)"
    log "HUD nav:       $(get_vbs GetCMUControlReq int32:25)"
    log "HUD nav mode:  $(get_vbs GetCMUControlReq int32:27)"
    log "HUD error:     $(get_vbs GetCMUControlReq int32:28)"

    log ""
    log "Checking MMUI process..."
    MMUI_PID=$(pgrep -f svcjcimmui 2>/dev/null)
    if [ -n "$MMUI_PID" ]; then
        log "jciMMUI running: PID $MMUI_PID"
        PRELOAD=$(cat /proc/$MMUI_PID/environ 2>/dev/null | tr '\0' '\n' | grep LD_PRELOAD)
        log "LD_PRELOAD: ${PRELOAD:-none}"
    else
        log "jciMMUI: NOT RUNNING!"
    fi

    log ""
    log "Checking navi service..."
    NAVI_PID=$(pgrep -f svcjcinavi 2>/dev/null)
    if [ -n "$NAVI_PID" ]; then
        log "jcinavi running: PID $NAVI_PID"
        PRELOAD=$(cat /proc/$NAVI_PID/environ 2>/dev/null | tr '\0' '\n' | grep LD_PRELOAD)
        log "LD_PRELOAD: ${PRELOAD:-none}"
    else
        log "jcinavi: NOT RUNNING!"
    fi

    log ""
    log "Recent MMUI HUD messages:"
    grep -i 'SetHud\|HUDNav\|CHud\|TurnByTurn\|Navigation' /tmp/mmuiLog* 2>/dev/null | tail -20

    log ""
    log "dmesg HUD:"
    dmesg 2>/dev/null | grep -i 'hud\|chud' | tail -10
}

do_fix() {
    log "=== Attempting HUD Navigation Fix ==="

    log "Step 1: Re-enabling HUD navigation via VBS..."
    set_vbs "SetCMUControlReq" "int32:25 variant:int32:1"
    sleep 1
    log "VBS nav state after: $(get_vbs GetCMUControlReq int32:25)"

    log ""
    log "Step 2: Setting navigation mode to LaneGuidance..."
    set_vbs "SetCMUControlReq" "int32:27 variant:string:Navigation_LaneGuidance"
    sleep 1
    log "VBS nav mode after: $(get_vbs GetCMUControlReq int32:27)"

    log ""
    log "If arrows still don't show, try: sh fix-hud-nav.sh reset"
}

do_reset() {
    log "=== HUD Navigation Reset ==="

    log "Step 1: Turning HUD navigation OFF..."
    set_vbs "SetCMUControlReq" "int32:25 variant:int32:2"
    sleep 2

    log "Step 2: Turning HUD navigation back ON..."
    set_vbs "SetCMUControlReq" "int32:25 variant:int32:1"
    sleep 1

    log "Step 3: Forcing mode to LaneGuidance..."
    set_vbs "SetCMUControlReq" "int32:27 variant:string:Navigation_LaneGuidance"
    sleep 1

    log "State after reset:"
    log "  nav:  $(get_vbs GetCMUControlReq int32:25)"
    log "  mode: $(get_vbs GetCMUControlReq int32:27)"

    log ""
    log "If still broken, the VBS D-Bus API params may differ."
    log "Run 'sh fix-hud-nav.sh diagnose' and send output for analysis."
}

case "$ACTION" in
    diagnose) diagnose ;;
    fix)      diagnose; echo ""; do_fix ;;
    reset)    diagnose; echo ""; do_reset ;;
    *)        echo "Usage: sh fix-hud-nav.sh [diagnose|fix|reset]" ;;
esac
