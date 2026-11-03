#!/bin/sh
# Tweaks Manager — Pure Installer
# Called by runner: sh installer/tweaks.sh <usb_path> <install|uninstall>
#
# This script is PURE: no UI dialogs, no exec redirect, no reboot.
# All output goes to stdout/stderr, captured by runner's exec > $LOG 2>&1.
# Exit codes: 0=OK, 2=remount fail, 3=missing file, 4=patch sanity, 5=verify fail

set -u

TAG="[tweaks install]"
USB="${1:?usage: tweaks.sh <usb_path> <install|uninstall>}"
ACTION="${2:?usage: tweaks.sh <usb_path> <install|uninstall>}"
INSTALLER_DIR="$USB/tweaks-manager/installer"
VERSION_FILE="$USB/tweaks-manager/VERSION"
if [ -f "$VERSION_FILE" ]; then
    VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
else
    VERSION="0.0.0"
fi

log() { echo "$TAG $*"; }
die() {
    CODE="$1"; shift
    log "FATAL (exit $CODE): $*"
    mount -o remount,ro / 2>/dev/null
    exit "$CODE"
}

log "=== $ACTION start | v$VERSION | from $USB ==="

# ── Preflight ───────────────────────────────────────────────────────
[ -f /jci/sm/sm.conf ] || [ -f /jci/sm/sm_WCP.conf ] || die 3 "not a CMU (no sm.conf)"

if [ "$ACTION" = "install" ]; then
    [ -f "$INSTALLER_DIR/tweaksd" ] || die 3 "daemon binary not found at $INSTALLER_DIR/tweaksd"
fi

# ── Board type detection ────────────────────────────────────────────
if [ -x /jci/scripts/get_board_type.sh ]; then
    /jci/scripts/get_board_type.sh >/dev/null 2>&1; BT=$?
else
    BT=""
fi
if [ "$BT" = "2" ] && [ -f /jci/sm/sm_WCP.conf ]; then
    CONF="/jci/sm/sm_WCP.conf"
    log "WCP hardware (get_board_type.sh=2) -> sm_WCP.conf"
else
    CONF="/jci/sm/sm.conf"
    log "non-WCP hardware (get_board_type.sh=${BT:-n/a}) -> sm.conf"
fi

# ── Remount rootfs rw ───────────────────────────────────────────────
mount -o remount,rw / 2>/dev/null || die 2 "cannot remount / read-write"
log "rootfs remounted rw"

# ═══════════════════════════════════════════════════════════════════
#  INSTALL
# ═══════════════════════════════════════════════════════════════════
do_install() {
    log "[1/5] Copying daemon..."
    mkdir -p /data_persist/tweaks/installed
    mkdir -p /data_persist/tweaks/backups
    mkdir -p /data_persist/tweaks/scripts
    mkdir -p /data_persist/tweaks/lib

    cp "$INSTALLER_DIR/tweaksd" /data_persist/tweaks/tweaksd || die 3 "copy tweaksd failed"
    chmod 755 /data_persist/tweaks/tweaksd

    if [ -f "$INSTALLER_DIR/../lib/patch.sh" ]; then
        cp "$INSTALLER_DIR/../lib/patch.sh" /data_persist/tweaks/lib/patch.sh
        chmod 755 /data_persist/tweaks/lib/patch.sh
        log "[1/5] patch.sh copied"
    fi
    log "[1/5] daemon copied"

    # ── Named backup (idempotent) ───────────────────────────────────
    log "[2/5] Backing up configs..."
    BAK="/data_persist/$(basename "$CONF").bak_tweaks"
    if [ -f "$BAK" ]; then
        log "[2/5] backup exists at $BAK, skipping"
    else
        cp -a "$CONF" "$BAK"
        log "[2/5] backup -> $BAK"
    fi

    OPERA_INI_BAK="/data_persist/opera.ini.bak_tweaks"
    if [ -f /jci/opera/opera_home/opera.ini ] && [ ! -f "$OPERA_INI_BAK" ]; then
        cp -a /jci/opera/opera_home/opera.ini "$OPERA_INI_BAK"
        log "[2/5] backed up opera.ini"
    fi

    # ── Stale cleanup from inactive config ──────────────────────────
    for OTHER in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do
        [ "$OTHER" = "$CONF" ] && continue
        [ -f "$OTHER" ] || continue
        if grep -q "tweaksd" "$OTHER"; then
            OBAK="/data_persist/$(basename "$OTHER").bak_tweaks"
            [ -f "$OBAK" ] || cp -a "$OTHER" "$OBAK"
            sed -i '/tweaksd/d' "$OTHER"
            log "[2/5] removed stale tweaksd from $OTHER"
        fi
    done

    # ── Boot autostart via stage_2.sh ──────────────────────────────
    log "[3/5] Setting up boot autostart..."
    STAGE2="/jci/scripts/stage_2.sh"
    STAGE2_BAK="/data_persist/tweaks/backups/_stage_2.sh"

    if [ -f "$STAGE2" ]; then
        if grep -q "tweaksd" "$STAGE2"; then
            log "[3/5] tweaksd already in stage_2.sh"
        else
            # Backup original stage_2.sh (once)
            if [ ! -f "$STAGE2_BAK" ]; then
                cp -a "$STAGE2" "$STAGE2_BAK"
                log "[3/5] backed up stage_2.sh"
            fi
            cat >> "$STAGE2" << 'STAGE2EOF'

# Tweaks Manager — autostart daemon on boot
(
    sleep 12
    if [ -x /data_persist/tweaks/tweaksd ]; then
        /data_persist/tweaks/tweaksd &
    fi
) &
STAGE2EOF
            log "[3/5] added tweaksd to stage_2.sh"
        fi
    else
        log "[3/5] WARN: stage_2.sh not found, skipping boot autostart"
    fi

    # Legacy autorun cleanup (old method that didn't work)
    if [ -f /data_persist/dev/bin/autorun ] && grep -q "tweaksd" /data_persist/dev/bin/autorun 2>/dev/null; then
        sed -i '/tweaksd/d' /data_persist/dev/bin/autorun
        sed -i '/# Tweaks Manager daemon/d' /data_persist/dev/bin/autorun
        log "[3/5] cleaned up legacy autorun"
    fi

    # ── Deploy Tweaks Menu UI (Opera userjs) ───────────────────────
    log "[4/5] Deploying tweaks-menu.js..."
    USERJS_DIR="/jci/opera/opera_dir/userjs"
    MENU_SRC="$USB/tweaks-manager/jci-app/tweaks-menu.js"
    if [ -f "$MENU_SRC" ]; then
        mkdir -p "$USERJS_DIR"
        cp "$MENU_SRC" "$USERJS_DIR/tweaks-menu.js"
        log "[4/5] tweaks-menu.js deployed to $USERJS_DIR"

        # Enable User JavaScript in opera.ini if disabled
        OPERA_INI="/jci/opera/opera_home/opera.ini"
        if [ -f "$OPERA_INI" ]; then
            if grep -q 'User JavaScript=0' "$OPERA_INI"; then
                sed -i 's/User JavaScript=0/User JavaScript=1/' "$OPERA_INI"
                log "[4/5] enabled User JavaScript in opera.ini"
            elif grep -q 'User JavaScript=1' "$OPERA_INI"; then
                log "[4/5] User JavaScript already enabled"
            fi
        fi
    else
        log "[4/5] WARN: tweaks-menu.js not found on USB"
    fi
    # Remove old index.html injections if present (caused boot loop)
    if grep -q '_tweaks/' /jci/gui/index.html 2>/dev/null; then
        sed -i '/_tweaks\/tweaks-bootstrap.js/d' /jci/gui/index.html
        sed -i '/_tweaks\/tweaksApp.js/d' /jci/gui/index.html
        rm -rf /jci/gui/apps/_tweaks
        log "[4/5] cleaned up old index.html injections"
    fi

    # ── Finalize ────────────────────────────────────────────────────
    log "[5/5] Finalizing..."
    echo "installed" > /data_persist/tweaks/tweaksd_installed
    echo "$VERSION" >> /data_persist/tweaks/tweaksd_installed
    echo "$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null)" >> /data_persist/tweaks/tweaksd_installed

    # Start daemon now
    /data_persist/tweaks/tweaksd &
    log "[5/5] daemon started (PID $!)"

    # ── Verify ──────────────────────────────────────────────────────
    sync
    mount -o remount,ro / 2>/dev/null

    log "=== VERIFY ==="
    if [ -f /data_persist/tweaks/tweaksd_installed ]; then
        log "install marker: OK"
    else
        log "install marker: MISSING"
    fi
    if [ -x /data_persist/tweaks/tweaksd ]; then
        log "daemon binary: OK ($(wc -c < /data_persist/tweaks/tweaksd) bytes)"
    else
        log "daemon binary: MISSING"
    fi
    if grep -q "tweaksd" /jci/scripts/stage_2.sh 2>/dev/null; then
        log "boot autostart: OK (stage_2.sh)"
    else
        log "boot autostart: MISSING"
    fi
    if [ -f /jci/opera/opera_dir/userjs/tweaks-menu.js ]; then
        log "tweaks-menu.js: OK"
    else
        log "tweaks-menu.js: MISSING"
    fi
    if grep -q 'User JavaScript=1' /jci/opera/opera_home/opera.ini 2>/dev/null; then
        log "User JavaScript: enabled"
    else
        log "User JavaScript: DISABLED (tweaks menu won't load)"
    fi

    log "=== install complete ==="
}

# ═══════════════════════════════════════════════════════════════════
#  UNINSTALL
# ═══════════════════════════════════════════════════════════════════
do_uninstall() {
    log "[1/4] Stopping daemon..."
    killall tweaksd 2>/dev/null
    log "[1/4] daemon stopped"

    log "[2/4] Cleaning userjs..."
    rm -f /jci/opera/opera_dir/userjs/tweaks-menu.js
    rm -f /jci/opera/opera_dir/userjs/tweaks-bootstrap.js
    rm -f /jci/opera/opera_dir/userjs/tweaksApp.js

    OPERA_INI="/jci/opera/opera_home/opera.ini"
    OPERA_INI_BAK="/data_persist/opera.ini.bak_tweaks"
    if [ -f "$OPERA_INI_BAK" ]; then
        cp -a "$OPERA_INI_BAK" "$OPERA_INI"
        log "[2/4] opera.ini restored from backup"
    elif [ -f "$OPERA_INI" ] && grep -q 'User JavaScript=1' "$OPERA_INI"; then
        sed -i 's/User JavaScript=1/User JavaScript=0/' "$OPERA_INI"
        log "[2/4] disabled User JavaScript in opera.ini (no backup)"
    fi
    log "[2/4] userjs removed"

    log "[3/4] Removing boot autostart..."
    STAGE2="/jci/scripts/stage_2.sh"
    STAGE2_BAK="/data_persist/tweaks/backups/_stage_2.sh"
    if [ -f "$STAGE2_BAK" ]; then
        cp -a "$STAGE2_BAK" "$STAGE2"
        log "[3/4] stage_2.sh restored from backup"
    elif grep -q "tweaksd" "$STAGE2" 2>/dev/null; then
        sed -i '/# Tweaks Manager/,/^) &$/d' "$STAGE2"
        sed -i '/tweaksd/d' "$STAGE2"
        log "[3/4] removed tweaksd from stage_2.sh (no backup)"
    fi

    # Legacy autorun cleanup
    AUTORUN=/data_persist/dev/bin/autorun
    if [ -f "$AUTORUN" ] && grep -q "tweaksd" "$AUTORUN" 2>/dev/null; then
        sed -i '/# Tweaks Manager daemon/d' "$AUTORUN"
        sed -i '/tweaksd/d' "$AUTORUN"
        log "[3/4] cleaned up legacy autorun"
    fi

    # Legacy sm.conf cleanup
    for SM in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do
        [ -f "$SM" ] || continue
        if grep -q "tweaksd" "$SM"; then
            sed -i '/<service.*name="tweaksd"/,/<\/service>/d' "$SM"
            log "[3/4] removed tweaksd service from $SM"
        fi
    done

    # Legacy index.html cleanup
    if grep -q "_tweaks/" /jci/gui/index.html 2>/dev/null; then
        sed -i '/_tweaks\/tweaks-bootstrap.js/d' /jci/gui/index.html
        sed -i '/_tweaks\/tweaksApp.js/d' /jci/gui/index.html
        rm -rf /jci/gui/apps/_tweaks
        log "[3/4] removed legacy index.html injections"
    fi

    log "[4/4] Removing daemon..."
    rm -f /data_persist/tweaks/tweaksd
    rm -f /data_persist/tweaks/tweaksd_installed
    log "[4/4] daemon and marker removed"

    # ── Verify ──────────────────────────────────────────────────────
    sync
    mount -o remount,ro / 2>/dev/null

    log "=== VERIFY ==="
    if [ -f /data_persist/tweaks/tweaksd_installed ]; then
        log "install marker: STILL EXISTS (bad)"
    else
        log "install marker: removed OK"
    fi
    if [ -f /data_persist/tweaks/tweaksd ]; then
        log "daemon binary: STILL EXISTS (bad)"
    else
        log "daemon binary: removed OK"
    fi
    if grep -q "tweaksd" /jci/scripts/stage_2.sh 2>/dev/null; then
        log "boot autostart: STILL EXISTS (bad)"
    else
        log "boot autostart: removed OK"
    fi

    log "=== uninstall complete ==="
}

# ── Dispatch ────────────────────────────────────────────────────────
case "$ACTION" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *)         die 1 "unknown action: $ACTION (expected install or uninstall)" ;;
esac
