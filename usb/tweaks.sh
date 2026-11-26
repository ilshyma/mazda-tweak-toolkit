#!/bin/sh
# Tweaks Manager 2.0 — USB Runner
# USB-only architecture: tweaksd runs from USB, UI is temporary.
# Flow: lock → log → snapshot → verify → start daemon → deploy UI → ready.
#
# Trigger: CVE-2024-8359 .up filename injection → t trampoline → this script.

MYDIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
TWEAKSD_USB="$MYDIR/tweaks-manager/installer/tweaksd"
USERJS_SRC="$MYDIR/tweaks-manager/jci-app/tweaks-menu.js"
LIB_SRC="$MYDIR/tweaks-manager/lib/patch.sh"
DLG=/jci/tools/jci-dialog
TITLE="Tweaks Manager"
USB_VER_FILE="$MYDIR/tweaks-manager/VERSION"
if [ -f "$USB_VER_FILE" ]; then
    VERSION=$(cat "$USB_VER_FILE" | tr -d '[:space:]')
else
    VERSION="0.0.0"
fi
LOCKDIR="/tmp/tweaks-manager.lock"

hwclock --hctosys 2>/dev/null
echo 1 > "/sys/class/gpio/Watchdog Disable/value" 2>/dev/null

# ── Parse firmware ──────────────────────────────────────────────────
FW=$(grep '^JCI_SW_VER=' /jci/version.ini 2>/dev/null | cut -d'"' -f2 | sed 's/MAZ_CMU-150_//')
: "${FW:=??}"
FLAVOR=$(grep '^JCI_SW_FLAVOR=' /jci/version.ini 2>/dev/null | cut -d'"' -f2 | sed 's/cmu150_//')
ARCH=$(uname -m 2>/dev/null || echo "??")
STAMP=$(date "+%Y%m%d-%H%M%S" 2>/dev/null || echo "unknown")
TS=$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "??")
FACTS="v$VERSION | FW ${FW:-?} ${FLAVOR:-?} | $ARCH | $STAMP"

# ── Lock (mkdir-based, with stale recovery) ─────────────────────────
take_lock() {
    if mkdir "$LOCKDIR" 2>/dev/null; then
        echo $$ > "$LOCKDIR/pid"
        return 0
    fi
    OLDPID=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [ -n "$OLDPID" ] && ! kill -0 "$OLDPID" 2>/dev/null; then
        rm -rf "$LOCKDIR"
        mkdir "$LOCKDIR" 2>/dev/null && echo $$ > "$LOCKDIR/pid" && return 0
    fi
    return 1
}

release_lock() {
    rm -rf "$LOCKDIR" 2>/dev/null
}

if ! take_lock; then
    [ -x "$DLG" ] && "$DLG" --info --no-cancel --title "$TITLE" \
        --text "Already running.\nWait for the previous operation to finish." &
    sleep 5; killall -q jci-dialog 2>/dev/null
    exit 1
fi
cleanup() {
    release_lock
}
trap 'cleanup' EXIT

# ── Remount USB rw for logging ──────────────────────────────────────
MNT=$(awk -v d="$MYDIR/" 'index(d, $2 "/") == 1 && length($2) > length(m) { m = $2 } END { print m }' /proc/mounts 2>/dev/null)
[ -n "$MNT" ] && [ "$MNT" != / ] && mount -o remount,rw "$MNT" 2>/dev/null

LOGBASE="$MYDIR/logs"
LOGNOTE=""
if ! { mkdir -p "$LOGBASE" && touch "$LOGBASE/.w" && rm -f "$LOGBASE/.w"; } 2>/dev/null; then
    LOGBASE=/tmp/tweaks-logs
    LOGNOTE="USB read-only: logs in $LOGBASE on the unit"
    mkdir -p "$LOGBASE"
fi

n=$(ls -d "$LOGBASE"/[0-9][0-9][0-9]_* 2>/dev/null | sed 's#.*/\([0-9]*\)_.*#\1#' | sort -n | tail -1)
n=$(echo "${n:-0}" | sed 's/^0*//'); n=$(( ${n:-0} + 1 )); n=$(printf '%03d' "$n" 2>/dev/null || echo "$n")
RUN="$LOGBASE/${n}_run_$STAMP"
mkdir -p "$RUN"
LOG="$RUN/run.log"

# ── SINGLE exec redirect — captures EVERYTHING from here on ────────
exec > "$LOG" 2>&1

echo "=== Tweaks Manager runner | $FACTS | uptime $(cut -d' ' -f1 /proc/uptime 2>/dev/null) | from $MYDIR | mount $MNT"
[ -n "$LOGNOTE" ] && echo "NOTE: $LOGNOTE"

log() { echo "[$(date "+%H:%M:%S" 2>/dev/null)] $*"; }

# ── Portable sed -i (macOS needs '', busybox does not) ─────────────
_sed_i() {
    if [ "$(uname)" = "Darwin" ]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# ── Panel fallback (XSS progress for JCI GUI) ──────────────────────
panel() {
    echo "window.__usbStatus='$1';" > /tmp/tweaks-usb-status.js 2>/dev/null
}

# ── Result (photographable screen + file) ───────────────────────────
result() {
    CODE="$1"; HEAD="$2"; DETAIL="$3"; ADVICE="${4:-}"
    case "$CODE" in
        OK) TEXT="$HEAD" ;;
        *)  TEXT="ERROR $CODE: $HEAD" ;;
    esac
    [ -n "$DETAIL" ] && TEXT="$TEXT\n$DETAIL"
    [ -n "$ADVICE" ] && TEXT="$TEXT\n$ADVICE"
    TEXT="$TEXT\n$FACTS"
    [ -n "$LOGNOTE" ] && TEXT="$TEXT\n$LOGNOTE"
    printf '%b\n' "$TEXT" > "$RUN/RESULT.txt"
    echo "log: $(basename "$LOGBASE")/$(basename "$RUN")" >> "$RUN/RESULT.txt"
    cp "$RUN/RESULT.txt" "$LOGBASE/LAST_RESULT.txt" 2>/dev/null
    snapshot
    panel "$CODE: $HEAD"
    if [ -x "$DLG" ]; then
        "$DLG" --info --no-cancel --title "$TITLE" \
            --text "$(printf '%b' "$TEXT")\n\nLog: $(basename "$LOGBASE")/$(basename "$RUN")" &
        sleep 8; kill $! 2>/dev/null
    fi
}

# ── System snapshot ─────────────────────────────────────────────────
snapshot() {
    {
        echo "=== $TITLE | $FACTS | uptime $(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
        echo "--- version.ini"
        grep -E '^JCI_(SW_VER|SW_FLAVOR|SW_VER_PATCH|OEM_PART_NUMBER)=' /jci/version.ini 2>&1
        echo "--- mounts"
        (mount 2>/dev/null || cat /proc/mounts 2>/dev/null) | grep -E 'jci|data_persist|system|rootfs|sd[a-d]'
        echo "--- df"
        df -k / /data_persist 2>/dev/null
        echo "--- board type"
        if [ -x /jci/scripts/get_board_type.sh ]; then
            /jci/scripts/get_board_type.sh >/dev/null 2>&1; echo "exit=$?"
        else
            echo "get_board_type.sh not found"
        fi
        echo "--- opera.ini userjs"
        grep -i 'user javascript' /jci/opera/opera_home/opera.ini 2>&1
        echo "--- userjs dir"
        ls -la /jci/opera/opera_dir/userjs/ 2>&1
        echo "--- data_persist/tweaks"
        ls -la /data_persist/tweaks/ 2>&1
        echo "--- processes"
        ps aux 2>/dev/null | grep -E 'tweaks|opera|jci' | grep -v grep
        echo "--- dmesg tail"
        dmesg 2>/dev/null | tail -20
    } > "$RUN/system.txt" 2>&1
}
snapshot
log "Snapshot saved"

# ── MD5 verification ────────────────────────────────────────────────
if [ -f "$MYDIR/MD5SUM" ]; then
    log "Verifying USB file integrity..."
    panel "Checking files..."
    cd "$MYDIR" && md5sum -c MD5SUM > "$RUN/md5check.txt" 2>&1
    if [ $? -ne 0 ]; then
        log "FATAL: MD5 verification failed"
        cat "$RUN/md5check.txt"
        result "E_MD5" "USB file integrity check failed." "Re-download the package." ""
        exit 1
    fi
    cd /
    log "MD5 verification passed"
fi

# ── Finish with choice ──────────────────────────────────────────────
finish() {
    MSG="${1:-Done.}"
    if [ -x "$DLG" ]; then
        "$DLG" --question --title "$TITLE" \
            --text "$MSG\n\nRemove USB drive now.\n\n$FACTS" \
            --ok-label "Reboot (5s)" --cancel-label "Stay"
        if [ $? -eq 0 ]; then
            log "User chose: Reboot"
            panel "Rebooting..."
            sync
            sleep 5
            reboot
        else
            log "User chose: Stay"
            panel "Done (no reboot)"
        fi
    else
        log "No dialog available, rebooting in 5s"
        sync
        sleep 5
        reboot
    fi
}

# ── Preflight ───────────────────────────────────────────────────────
if [ ! -x "$DLG" ]; then
    log "FATAL: jci-dialog not found at $DLG"
    echo "E1: jci-dialog not found"
    exit 1
fi

if [ ! -x "$TWEAKSD_USB" ]; then
    log "FATAL: tweaksd binary not found at $TWEAKSD_USB"
    result "E_NOFILE" "tweaksd binary not found on USB." "Re-create the USB stick." ""
    exit 1
fi

# ── Firmware warning ────────────────────────────────────────────────
FW_NUM=$(echo "$FW" | sed 's/[A-Za-z]*$//')
if [ "$FW_NUM" != "74.00.324" ]; then
    log "WARNING: firmware $FW — not 74.00.324"
    "$DLG" --question --title "Check Firmware" \
        --text "WARNING: Firmware $FW detected.\n\nTested only on 74.00.324.\nVerify your version before continuing.\n\n$FACTS" \
        --ok-label "Continue anyway" --cancel-label "Cancel"
    if [ $? -ne 0 ]; then
        log "User cancelled on FW warning"
        exit 0
    fi
    log "User continued despite FW warning"
fi

# ── Main menu (3 choices) ──────────────────────────────────────────
# jci-dialog supports only 2 buttons, so: first ask Start/Recovery,
# then confirm each choice (with Close as cancel on the first dialog).
"$DLG" --question --title "$TITLE" \
    --text "Tweaks Manager v$VERSION\nFirmware: $FW\n\nChoose an action:" \
    --ok-label "Start Manager" --cancel-label "Recovery"
CHOICE=$?

if [ $CHOICE -eq 0 ]; then
    # User chose Start — confirm
    "$DLG" --question --title "$TITLE" \
        --text "Start tweak manager from USB?\n(Daemon runs only while USB is inserted)" \
        --ok-label "Start" --cancel-label "Close"
    if [ $? -ne 0 ]; then
        log "User cancelled start"
        exit 0
    fi
    log "User confirmed start"
else
    # User chose Recovery — confirm
    "$DLG" --question --title "$TITLE" \
        --text "Recovery: remove all tweaks traces from CMU?\n\nThis will:\n- Remove UI overlay (tweaks-menu.js)\n- Restore opera.ini\n- Remove tweak patches from stage_wifi.sh\n- Stop tweaksd/sshd processes\n\nCMU will reboot after cleanup." \
        --ok-label "Clean up" --cancel-label "Close"
    if [ $? -ne 0 ]; then
        log "User cancelled recovery"
        exit 0
    fi
    log "User confirmed recovery"

    # ── Recovery: clean up CMU ─────────────────────────────────────
    log "=== RECOVERY MODE ==="
    panel "Recovery..."
    mount -o remount,rw / 2>/dev/null

    # Remove tweaks-menu.js
    if [ -f /jci/opera/opera_dir/userjs/tweaks-menu.js ]; then
        rm -f /jci/opera/opera_dir/userjs/tweaks-menu.js
        log "Removed tweaks-menu.js"
    fi

    # Restore opera.ini — remove UserJS lines
    OPERA_INI="/jci/opera/opera_home/opera.ini"
    if [ -f "$OPERA_INI" ]; then
        _sed_i '/^User JavaScript=1$/d' "$OPERA_INI" 2>/dev/null
        _sed_i '/^User JavaScript File=/d' "$OPERA_INI" 2>/dev/null
        log "Cleaned opera.ini"
    fi

    # Remove ALL tweak marker blocks from stage_wifi.sh
    STAGE_WIFI="/jci/scripts/stage_wifi.sh"
    if [ -f "$STAGE_WIFI" ] && grep -q '# tweaks:' "$STAGE_WIFI" 2>/dev/null; then
        _sed_i '/# tweaks:.*:begin/,/# tweaks:.*:end/d' "$STAGE_WIFI" 2>/dev/null
        log "Removed tweak markers from stage_wifi.sh"
    fi

    mount -o remount,ro / 2>/dev/null

    # Kill running processes
    killall tweaksd 2>/dev/null && log "Killed tweaksd"
    killall sshd 2>/dev/null && log "Killed sshd"

    # Clean data_persist traces
    rm -rf /data_persist/tweaks 2>/dev/null && log "Removed /data_persist/tweaks"

    log "=== Recovery complete ==="
    result "OK" "Recovery complete." "All tweaks traces removed.\nCMU will reboot now." ""
    sync
    sleep 3
    reboot
    exit 0
fi

# ── Deploy patch library ────────────────────────────────────────────
log "Deploying patch library..."
mkdir -p /data_persist/tweaks/lib
if [ -f "$LIB_SRC" ]; then
    cp "$LIB_SRC" /data_persist/tweaks/lib/patch.sh
    log "patch.sh copied to /data_persist/tweaks/lib/"
else
    log "WARN: patch.sh not found on USB at $LIB_SRC"
fi

# ── Ensure tweaks directories exist ─────────────────────────────────
mkdir -p /data_persist/tweaks/installed
mkdir -p /data_persist/tweaks/backups
mkdir -p /data_persist/tweaks/scripts

# ── Start tweaksd from USB ──────────────────────────────────────────
log "Starting tweaksd from USB..."
panel "Starting daemon..."

if killall -0 tweaksd 2>/dev/null; then
    log "tweaksd already running, killing old instance"
    killall tweaksd 2>/dev/null
    sleep 1
fi

"$TWEAKSD_USB" </dev/null >/dev/null 2>&1
sleep 2

if [ -f /tmp/tweaksd.pid ] && kill -0 $(cat /tmp/tweaksd.pid) 2>/dev/null; then
    log "tweaksd daemonized (PID $(cat /tmp/tweaksd.pid)) from $TWEAKSD_USB"
    panel "tweaksd running"
else
    log "FATAL: tweaksd failed to start"
    result "E_DAEMON" "tweaksd failed to start." "Check logs." ""
    exit 1
fi

# ── Deploy tweaks-menu.js to Opera userjs ───────────────────────────
log "Deploying tweaks-menu.js to Opera..."
panel "Deploying UI..."

OPERA_USERJS="/jci/opera/opera_dir/userjs"
OPERA_INI="/jci/opera/opera_home/opera.ini"

mount -o remount,rw / 2>/dev/null

if ! grep -qi 'User JavaScript=1' "$OPERA_INI" 2>/dev/null; then
    if grep -qi '\[User Prefs\]' "$OPERA_INI" 2>/dev/null; then
        sed -i '/\[User Prefs\]/a User JavaScript=1' "$OPERA_INI" 2>/dev/null
    else
        printf '\n[User Prefs]\nUser JavaScript=1\n' >> "$OPERA_INI" 2>/dev/null
    fi
    log "Enabled User JavaScript in opera.ini"
fi

if ! grep -qi 'User JavaScript File=' "$OPERA_INI" 2>/dev/null; then
    sed -i "/\[User Prefs\]/a User JavaScript File=$OPERA_USERJS" "$OPERA_INI" 2>/dev/null
fi

mkdir -p "$OPERA_USERJS"
cp "$USERJS_SRC" "$OPERA_USERJS/tweaks-menu.js"
log "tweaks-menu.js deployed to $OPERA_USERJS"

mount -o remount,ro / 2>/dev/null

# ── Restart Opera to load userjs ────────────────────────────────────
log "Restarting Opera to load UI..."
panel "Restarting UI..."

killall opera 2>/dev/null
sleep 3
log "Opera restarted — UI will auto-open"

# ── Done ────────────────────────────────────────────────────────────
log "=== Tweaks Manager 2.0 ready ==="
panel "Ready"

finish "Tweaks Manager ready.\n\nUI will appear in a few seconds.\nManage tweaks from the overlay."
