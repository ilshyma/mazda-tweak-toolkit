#!/bin/sh
# Tweaks Manager — Runner
# Owns ALL I/O: USB remount, logging, lock, UI dialogs, snapshot, result, reboot.
# Installer is called as a subprocess; its stdout/stderr is captured by our exec.
#
# Trigger: CVE-2024-8359 .up filename injection → t trampoline → this script.

MYDIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
INSTALLER="$MYDIR/tweaks-manager/installer/tweaks.sh"
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
trap 'release_lock' EXIT

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

# ── Error code mapping ──────────────────────────────────────────────
explain_failure() {
    case "$1" in
        1)   echo "E_GENERAL: installer reported an error" ;;
        2)   echo "E_REMOUNT: cannot remount filesystem" ;;
        3)   echo "E_NOFILE: required file missing from USB" ;;
        4)   echo "E_PATCH: config patch failed sanity check" ;;
        5)   echo "E_VERIFY: post-install verification failed" ;;
        *)   echo "E_UNKNOWN: installer exit code $1" ;;
    esac
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
        echo "--- autorun"
        cat /data_persist/dev/bin/autorun 2>&1
        echo "--- tweaksd installed?"
        cat /data_persist/tweaks/tweaksd_installed 2>&1
        echo "--- data_persist/tweaks"
        ls -la /data_persist/tweaks/ 2>&1
        echo "--- sm.conf LD_PRELOAD"
        grep -n 'LD_PRELOAD\|tweaks' /jci/sm/sm.conf 2>&1
        grep -n 'LD_PRELOAD\|tweaks' /jci/sm/sm_WCP.conf 2>&1
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

if [ ! -f "$INSTALLER" ]; then
    log "FATAL: installer not found at $INSTALLER"
    result "E_NOFILE" "tweaks-manager folder not found on USB." "Re-create the USB stick." ""
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

# ── Run installer and handle result ─────────────────────────────────
run_installer() {
    ACTION="$1"
    log "--- Calling installer: $ACTION ---"
    panel "Running $ACTION..."

    sh "$INSTALLER" "$MYDIR" "$ACTION"
    RC=$?

    if [ $RC -eq 0 ]; then
        log "--- Installer finished OK ---"
        result "OK" "Tweaks Manager ${ACTION}ed successfully." "" ""
        finish "Tweaks Manager ${ACTION}ed."
    else
        ERRCODE=$(explain_failure $RC)
        log "--- Installer FAILED: exit $RC ($ERRCODE) ---"
        result "$ERRCODE" "Installation failed (exit $RC)." "Check logs on the USB stick." ""
    fi
}

# ── Version comparison (semver: returns 0 if $1 > $2) ─────────────
ver_newer() {
    a1=$(echo "$1" | cut -d. -f1); a1=${a1:-0}
    b1=$(echo "$1" | cut -d. -f2); b1=${b1:-0}
    c1=$(echo "$1" | cut -d. -f3); c1=${c1:-0}
    a2=$(echo "$2" | cut -d. -f1); a2=${a2:-0}
    b2=$(echo "$2" | cut -d. -f2); b2=${b2:-0}
    c2=$(echo "$2" | cut -d. -f3); c2=${c2:-0}
    [ "$a1" -gt "$a2" ] && return 0
    [ "$a1" -lt "$a2" ] && return 1
    [ "$b1" -gt "$b2" ] && return 0
    [ "$b1" -lt "$b2" ] && return 1
    [ "$c1" -gt "$c2" ] && return 0
    return 1
}

# ── Manage menu (already installed) ────────────────────────────────
show_manage_menu() {
    "$DLG" --question --title "$TITLE" \
        --text "Tweaks Manager v$INST_VER\nFirmware: $FW" \
        --ok-label "Reinstall" --cancel-label "Uninstall"
    if [ $? -eq 0 ]; then
        log "User chose: Reinstall"
        run_installer install
    else
        log "User chose: Uninstall path"
        "$DLG" --question --title "$TITLE" \
            --text "Remove Tweaks Manager?\n\nUninstall tweaks first via the app." \
            --ok-label "Uninstall" --cancel-label "Cancel"
        if [ $? -eq 0 ]; then
            log "User confirmed uninstall"
            run_installer uninstall
        else
            log "User cancelled uninstall"
        fi
    fi
}

# ── Menu ────────────────────────────────────────────────────────────
if [ -f /data_persist/tweaks/tweaksd_installed ]; then
    INST_VER=$(head -2 /data_persist/tweaks/tweaksd_installed 2>/dev/null | tail -1)
    [ -z "$INST_VER" ] && INST_VER="?"
    log "Installed v$INST_VER, USB v$VERSION"

    if ver_newer "$VERSION" "$INST_VER"; then
        log "Update available: v$INST_VER -> v$VERSION"

        "$DLG" --question --title "$TITLE" \
            --text "Update available!\n\nInstalled: v$INST_VER\nOn USB: v$VERSION\n\nFirmware: $FW" \
            --ok-label "Update" --cancel-label "Skip"
        if [ $? -eq 0 ]; then
            log "User chose: Update v$INST_VER -> v$VERSION"
            run_installer install
        else
            log "User skipped update"
            "$DLG" --question --title "$TITLE" \
                --text "Tweaks Manager v$INST_VER\nFirmware: $FW" \
                --ok-label "Manage" --cancel-label "Close"
            if [ $? -ne 0 ]; then log "User closed"; exit 0; fi
            show_manage_menu
        fi
    else
        log "Up to date v$INST_VER"
        "$DLG" --question --title "$TITLE" \
            --text "Tweaks Manager v$INST_VER (up to date)\nFirmware: $FW" \
            --ok-label "Manage" --cancel-label "Close"
        if [ $? -ne 0 ]; then log "User closed"; exit 0; fi
        show_manage_menu
    fi
else
    log "Not installed, showing install flow"

    "$DLG" --question --title "$TITLE" \
        --text "Tweaks Manager v$VERSION\nFirmware: $FW\n\nAdds tweaks app to Applications." \
        --ok-label "Install" --cancel-label "Close"
    if [ $? -ne 0 ]; then log "User closed"; exit 0; fi

    "$DLG" --question --title "$TITLE" \
        --text "Install Tweaks Manager?\n\n- Daemon on /data_persist\n- Autorun on boot\n\n$FACTS" \
        --ok-label "Install" --cancel-label "Cancel"
    if [ $? -eq 0 ]; then
        log "User confirmed install"
        run_installer install
    else
        log "User cancelled install"
    fi
fi

log "=== runner done ==="
