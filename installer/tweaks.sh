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
PATCH_LIB="${TWEAKS_LIB:-/data_persist/tweaks/lib/patch.sh}"
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
    # ── SSH safety net (before anything else) ──────────────────────
    # Separate sshd on port 22 with password auth.
    # Factory sshd (port 36000, key-only) is not touched.
    log "[0/5] Enabling SSH safety net..."
    STAGE_WIFI="/jci/scripts/stage_wifi.sh"
    SSHD_CONF="/data_persist/tweaks/sshd_tweaks.conf"
    if [ -f "$STAGE_WIFI" ]; then
        # Break /etc/passwd symlink (stock points to read-only squashfs)
        if [ -L /etc/passwd ]; then
            REAL=$(readlink -f /etc/passwd 2>/dev/null)
            if [ -z "$REAL" ]; then
                # BusyBox readlink -f returns empty when target is gone;
                # try the raw symlink target instead
                REAL=$(readlink /etc/passwd 2>/dev/null)
            fi
            if [ -n "$REAL" ] && [ -f "$REAL" ]; then
                if cp "$REAL" /etc/passwd.tmp && mv /etc/passwd.tmp /etc/passwd; then
                    log "[0/5] broke /etc/passwd symlink -> writable copy"
                else
                    rm -f /etc/passwd.tmp
                    ln -sf "$REAL" /etc/passwd
                    log "[0/5] WARN: atomic copy failed, symlink restored — SSH may not work"
                fi
            else
                # Target doesn't exist; try known stock locations
                for CAND in /config-mfg/passwd /jci/passwd /etc/passwd.orig; do
                    if [ -f "$CAND" ]; then
                        cp "$CAND" /etc/passwd.tmp && mv /etc/passwd.tmp /etc/passwd
                        log "[0/5] broke /etc/passwd symlink -> copy from $CAND"
                        break
                    fi
                done
                if [ ! -f /etc/passwd ]; then
                    # Last resort: generate a minimal passwd so the system keeps running
                    echo "root:x:0:0:root:/root:/bin/sh" > /etc/passwd
                    log "[0/5] WARN: no passwd source found, created minimal /etc/passwd"
                fi
            fi
        fi
        if [ ! -f /etc/passwd ]; then
            # Safety: if /etc/passwd is missing for any reason, create a minimal one
            echo "root:x:0:0:root:/root:/bin/sh" > /etc/passwd
            log "[0/5] WARN: /etc/passwd was missing, created minimal"
        fi
        # Set password for uid 0 user (stock CMU uses 'cmu', not 'root')
        UID0_USER=$(awk -F: '$3==0{print $1;exit}' /etc/passwd)
        echo "${UID0_USER:-cmu}:jci" | chpasswd 2>/dev/null || {
            HASH=$(openssl passwd -1 jci 2>/dev/null)
            [ -n "$HASH" ] && sed -i "s|^${UID0_USER:-cmu}:[^:]*:|${UID0_USER:-cmu}:${HASH}:|" /etc/passwd 2>/dev/null
        }
        # Create custom sshd config (port 22, password auth)
        mkdir -p /data_persist/tweaks
        cat > "$SSHD_CONF" << 'SSHCONF'
Port 22
AddressFamily inet
Protocol 2
PermitRootLogin yes
StrictModes no
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePrivilegeSeparation no
Compression no
ClientAliveInterval 15
ClientAliveCountMax 4
PidFile /var/run/sshd_tweaks.pid
Subsystem sftp /usr/libexec/sftp-server
SSHCONF
        # Persistent sshd autostart (idempotent — checks begin/end markers)
        if ! grep -q '# tweaks:ssh-safety:begin' "$STAGE_WIFI" 2>/dev/null; then
            SSH_BAK="/data_persist/tweaks/backups/ssh-access"
            mkdir -p "$SSH_BAK"
            [ ! -f "$SSH_BAK/stage_wifi.sh.bak" ] && cp -a "$STAGE_WIFI" "$SSH_BAK/stage_wifi.sh.bak"
            if [ -f "$PATCH_LIB" ]; then
                . "$PATCH_LIB"
                patch_begin "$STAGE_WIFI"
                patch_append_block "tweaks:ssh-safety" '/usr/sbin/sshd -f /data_persist/tweaks/sshd_tweaks.conf 2>/dev/null' "sshd autostart"
                patch_commit
            else
                cat >> "$STAGE_WIFI" << 'SSHPATCH'

# tweaks:ssh-safety:begin
/usr/sbin/sshd -f /data_persist/tweaks/sshd_tweaks.conf 2>/dev/null
# tweaks:ssh-safety:end
SSHPATCH
            fi
            log "[0/5] sshd autostart added to stage_wifi.sh"
        else
            log "[0/5] sshd autostart already present"
        fi
        # Start sshd right now
        /usr/sbin/sshd -f "$SSHD_CONF" 2>/dev/null || true
        log "[0/5] SSH ready — ssh ${UID0_USER:-cmu}@192.168.53.1 -p 22 pass:jci"
    else
        log "[0/5] WARN: stage_wifi.sh not found, SSH not enabled"
    fi

    log "[1/5] Copying daemon..."
    mkdir -p /data_persist/tweaks/installed
    mkdir -p /data_persist/tweaks/backups
    mkdir -p /data_persist/tweaks/scripts
    mkdir -p /data_persist/tweaks/lib

    cp "$INSTALLER_DIR/tweaksd" /data_persist/tweaks/tweaksd || die 3 "copy tweaksd failed"
    chmod 755 /data_persist/tweaks/tweaksd

    if [ -f "$INSTALLER_DIR/../lib/patch.sh" ]; then
        cp "$INSTALLER_DIR/../lib/patch.sh" /data_persist/tweaks/lib/patch.sh || log "[1/5] WARN: failed to copy patch.sh"
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
        cp -a "$CONF" "$BAK" || die 3 "backup of $CONF failed"
        log "[2/5] backup -> $BAK"
    fi

    # ── Stale cleanup from inactive config ──────────────────────────
    for OTHER in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do
        [ "$OTHER" = "$CONF" ] && continue
        [ -f "$OTHER" ] || continue
        if grep -q 'name="tweaksd"' "$OTHER"; then
            OBAK="/data_persist/$(basename "$OTHER").bak_tweaks"
            [ -f "$OBAK" ] || cp -a "$OTHER" "$OBAK"
            awk '/<service.*name="tweaksd"/{skip=1} /<\/service>/{if(skip){skip=0;next}} !skip' "$OTHER" > "$OTHER.tmp" && mv "$OTHER.tmp" "$OTHER"
            log "[2/5] removed stale tweaksd service from $OTHER"
        fi
    done

    # ── Boot autostart (permanent daemon) ─────────────────────────────
    log "[3/5] Setting up boot autostart..."
    STAGE2="/jci/scripts/stage_2.sh"
    STAGE2_BAK="/data_persist/tweaks/backups/_stage_2.sh"
    if ! grep -q '# tweaks:tweaksd-autostart:begin' "$STAGE2" 2>/dev/null; then
        if [ ! -f "$STAGE2_BAK" ]; then
            cp -a "$STAGE2" "$STAGE2_BAK"
        fi
        # Remove any legacy unmarked tweaksd lines first
        if grep -q "tweaksd" "$STAGE2" 2>/dev/null; then
            awk '/# Tweaks Manager/{skip=1;next} skip && /^\) &/{skip=0;next} skip{next} {print}' \
                "$STAGE2" > "$STAGE2.tmp" && mv "$STAGE2.tmp" "$STAGE2"
            sed -i '/^[[:space:]]*\/data_persist\/tweaks\/tweaksd/d' "$STAGE2"
            log "[3/5] cleaned up legacy unmarked tweaksd lines"
        fi
        if [ -f "$PATCH_LIB" ]; then
            . "$PATCH_LIB"
            patch_begin "$STAGE2"
            patch_append_block "tweaks:tweaksd-autostart" '/data_persist/tweaks/tweaksd 2>/dev/null' "tweaksd boot autostart"
            patch_commit
        else
            cat >> "$STAGE2" << 'AUTOSTART'

# tweaks:tweaksd-autostart:begin
/data_persist/tweaks/tweaksd 2>/dev/null
# tweaks:tweaksd-autostart:end
AUTOSTART
        fi
        log "[3/5] boot autostart added to stage_2.sh"
    else
        log "[3/5] boot autostart already present"
    fi

    # Legacy autorun cleanup
    if [ -f /data_persist/dev/bin/autorun ] && grep -q "tweaksd" /data_persist/dev/bin/autorun 2>/dev/null; then
        sed -i '/tweaksd/d' /data_persist/dev/bin/autorun
        sed -i '/# Tweaks Manager daemon/d' /data_persist/dev/bin/autorun
        log "[3/5] cleaned up legacy autorun"
    fi

    # ── Deploy Settings icon (Opera userjs) ──────────────────────
    log "[4/5] Deploying tweaks-menu.js to Opera userjs..."
    USERJS_DIR="/jci/opera/opera_dir/userjs"
    USERJS_SRC="$USB/tweaks-manager/jci-app/tweaks-menu.js"
    mkdir -p "$USERJS_DIR"
    if [ -f "$USERJS_SRC" ]; then
        cp "$USERJS_SRC" "$USERJS_DIR/tweaks-menu.js"
        log "[4/5] tweaks-menu.js deployed"
    else
        log "[4/5] WARN: tweaks-menu.js not found on USB"
    fi
    # Clean up old bootstrap/app approach (now using overlay button)
    rm -f "$USERJS_DIR/tweaks-bootstrap.js"
    rm -f "$USERJS_DIR/tweaksApp.js"
    # Enable User JavaScript in Opera
    OPERA_INI="/jci/opera/opera_home/opera.ini"
    if [ -f "$OPERA_INI" ]; then
        if grep -q "User JavaScript=0" "$OPERA_INI" 2>/dev/null; then
            sed -i "s/User JavaScript=0/User JavaScript=1/" "$OPERA_INI"
            log "[4/5] User JavaScript enabled in opera.ini"
        elif ! grep -q "User JavaScript=1" "$OPERA_INI" 2>/dev/null; then
            sed -i '/\[User Prefs\]/a User JavaScript=1' "$OPERA_INI"
            log "[4/5] User JavaScript=1 added to opera.ini"
        else
            log "[4/5] User JavaScript already enabled"
        fi
    else
        log "[4/5] WARN: opera.ini not found"
    fi
    # Clean up legacy wizard UI
    rm -rf /data_persist/tweaks/wizard
    rm -f /data_persist/tweaks/.wizard_state
    # Clean up legacy index.html injections
    if grep -q '_tweaks/' /jci/gui/index.html 2>/dev/null; then
        sed -i '/_tweaks\/tweaks-bootstrap.js/d' /jci/gui/index.html
        sed -i '/_tweaks\/tweaksApp.js/d' /jci/gui/index.html
        rm -rf /jci/gui/apps/_tweaks
        log "[4/5] cleaned up old index.html injections"
    fi

    # ── Finalize ────────────────────────────────────────────────────
    log "[5/5] Finalizing..."
    { echo "installed"; echo "$VERSION"; echo "$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null)"; } > /tmp/tweaksd_installed.tmp
    mv /tmp/tweaksd_installed.tmp /data_persist/tweaks/tweaksd_installed

    log "[5/5] daemon ready (permanent, starts on boot)"

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
        log "boot autostart: OK"
    else
        log "boot autostart: MISSING"
    fi
    if [ -f /jci/opera/opera_dir/userjs/tweaks-menu.js ]; then
        log "popup (userjs): OK"
    else
        log "popup (userjs): MISSING"
    fi

    log "=== install complete ==="

    # ── Show result on head unit ────────────────────────────────────
    sleep 2
    /jci/tools/jci-dialog \
        --info \
        --title="Tweaks Manager" \
        --text="Installed! Reboot to activate." \
        --ok-label="OK" &
}

# ═══════════════════════════════════════════════════════════════════
#  UNINSTALL
# ═══════════════════════════════════════════════════════════════════
do_uninstall() {
    log "[1/5] Stopping daemon..."
    killall tweaksd 2>/dev/null
    # Close firewall ports opened by tweaksd (wlan0 only)
    iptables -D INPUT -i wlan0 -p tcp --dport 8035 -j ACCEPT 2>/dev/null
    iptables -D INPUT -i wlan0 -p tcp --dport 22 -j ACCEPT 2>/dev/null
    log "[1/5] daemon stopped, firewall ports closed"

    log "[2/5] Cleaning UI files..."
    # Keep tweaks-menu.js — lightweight popup, needed for re-install from USB
    rm -f /jci/opera/opera_dir/userjs/tweaks-bootstrap.js
    rm -f /jci/opera/opera_dir/userjs/tweaksApp.js
    log "[2/5] legacy userjs removed (popup kept for re-install)"
    # Legacy wizard cleanup
    rm -rf /data_persist/tweaks/wizard
    rm -f /data_persist/tweaks/.wizard_state
    log "[2/5] wizard UI removed (legacy)"

    log "[3/5] Removing boot autostart..."
    STAGE2="/jci/scripts/stage_2.sh"
    STAGE2_BAK="/data_persist/tweaks/backups/_stage_2.sh"
    # Primary: surgical removal by markers
    if grep -q '# tweaks:tweaksd-autostart:begin' "$STAGE2" 2>/dev/null; then
        if [ -f "$PATCH_LIB" ]; then
            . "$PATCH_LIB"
            patch_begin "$STAGE2"
            patch_remove_block "tweaks:tweaksd-autostart" "tweaksd boot autostart"
            patch_commit
        else
            awk '/# tweaks:tweaksd-autostart:begin/{skip=1;next} /# tweaks:tweaksd-autostart:end/{skip=0;next} !skip' \
                "$STAGE2" > "$STAGE2.tmp" && mv "$STAGE2.tmp" "$STAGE2"
        fi
        log "[3/5] tweaksd block removed from stage_2.sh"
    # Fallback: legacy unmarked block — awk removes whole subshell safely
    elif grep -q "tweaksd" "$STAGE2" 2>/dev/null; then
        awk '/# Tweaks Manager/{skip=1;next} skip && /^\) &/{skip=0;next} skip{next} {print}' \
            "$STAGE2" > "$STAGE2.tmp" && mv "$STAGE2.tmp" "$STAGE2"
        # Remove any remaining standalone tweaksd launch lines (outside block)
        sed -i '/^[[:space:]]*\/data_persist\/tweaks\/tweaksd/d' "$STAGE2"
        log "[3/5] removed tweaksd from stage_2.sh (legacy)"
    else
        log "[3/5] tweaksd not found in stage_2.sh, nothing to remove"
    fi

    # Legacy autorun cleanup
    AUTORUN=/data_persist/dev/bin/autorun
    if [ -f "$AUTORUN" ] && grep -q "tweaksd" "$AUTORUN" 2>/dev/null; then
        sed -i '/# Tweaks Manager daemon/d' "$AUTORUN"
        sed -i '/tweaksd/d' "$AUTORUN"
        log "[3/5] cleaned up legacy autorun"
    fi

    # Legacy sm.conf cleanup
    for SM in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do
        [ -f "$SM" ] || continue
        if grep -q "tweaksd" "$SM"; then
            awk '/<service.*name="tweaksd"/{skip=1} /<\/service>/{if(skip){skip=0;next}} !skip' "$SM" > "$SM.tmp" && mv "$SM.tmp" "$SM"
            log "[3/5] removed tweaksd service from $SM"
        fi
    done

    # Legacy index.html cleanup
    if grep -q "_tweaks/" /jci/gui/index.html 2>/dev/null; then
        sed -i '/_tweaks\/tweaks-bootstrap.js/d' /jci/gui/index.html
        sed -i '/_tweaks\/tweaksApp.js/d' /jci/gui/index.html
        rm -rf /jci/gui/apps/_tweaks
        log "[3/5] removed legacy index.html injections"
    fi

    log "[4/5] Removing SSH tweaks..."
    STAGE_WIFI="/jci/scripts/stage_wifi.sh"
    # Primary: surgical removal by markers (preserves wifi-ap-autostart etc.)
    if grep -q '# tweaks:ssh-safety:begin' "$STAGE_WIFI" 2>/dev/null && [ -f "$PATCH_LIB" ]; then
        . "$PATCH_LIB"
        patch_begin "$STAGE_WIFI"
        patch_remove_block "tweaks:ssh-safety" "sshd autostart in stage_wifi.sh"
        patch_commit
        log "[4/5] SSH block removed from stage_wifi.sh (marker-based)"
    # Inline fallback: new markers present but PATCH_LIB unavailable (USB removed)
    elif grep -q '# tweaks:ssh-safety:begin' "$STAGE_WIFI" 2>/dev/null; then
        awk '/# tweaks:ssh-safety:begin/{skip=1;next} /# tweaks:ssh-safety:end/{skip=0;next} !skip' \
            "$STAGE_WIFI" > "$STAGE_WIFI.tmp" && mv "$STAGE_WIFI.tmp" "$STAGE_WIFI"
        log "[4/5] SSH block removed from stage_wifi.sh (inline fallback)"
    # Fallback: old-style marker without begin/end
    elif grep -q '# tweaks:ssh-access' "$STAGE_WIFI" 2>/dev/null; then
        # Only delete the marker line and the sshd line, NOT everything to EOF
        sed -i '/# tweaks:ssh-access/d' "$STAGE_WIFI" 2>/dev/null
        sed -i '/sshd_tweaks\.conf/d' "$STAGE_WIFI" 2>/dev/null
        log "[4/5] removed ssh-access from stage_wifi.sh (legacy, line-by-line)"
    fi
    # Stop tweaks sshd (port 22), leave factory sshd (port 36000) alone
    if [ -f /var/run/sshd_tweaks.pid ]; then
        kill "$(cat /var/run/sshd_tweaks.pid)" 2>/dev/null
        rm -f /var/run/sshd_tweaks.pid
    fi
    rm -f /data_persist/tweaks/sshd_tweaks.conf
    # Restore /etc/passwd — try symlink to stock, fall back to known sources
    if [ ! -f /etc/passwd ] && [ ! -L /etc/passwd ]; then
        # /etc/passwd is completely missing (broken install) — recover it
        if [ -f /config-mfg/passwd ]; then
            ln -s /config-mfg/passwd /etc/passwd
            log "[4/5] restored /etc/passwd symlink (was missing)"
        else
            # No stock source found; create a minimal passwd so the system boots
            echo "root:x:0:0:root:/root:/bin/sh" > /etc/passwd
            log "[4/5] WARN: created minimal /etc/passwd (no stock source found)"
        fi
    elif [ -f /config-mfg/passwd ] && [ ! -L /etc/passwd ]; then
        ln -sf /config-mfg/passwd /etc/passwd
        log "[4/5] restored /etc/passwd symlink"
    fi
    log "[4/5] SSH tweaks removed (factory sshd untouched)"

    log "[5/5] Removing daemon..."
    rm -f /data_persist/tweaks/tweaksd
    rm -f /data_persist/tweaks/tweaksd_installed
    log "[5/5] daemon and marker removed"

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
    if [ -f /jci/opera/opera_dir/userjs/tweaks-menu.js ]; then
        log "popup (userjs): kept (for re-install)"
    fi
    if grep -q 'tweaks:ssh-safety' /jci/scripts/stage_wifi.sh 2>/dev/null || \
       grep -q 'tweaks:ssh-access' /jci/scripts/stage_wifi.sh 2>/dev/null; then
        log "SSH autostart: STILL EXISTS (bad)"
    else
        log "SSH autostart: removed OK"
    fi

    log "=== uninstall complete ==="
}

# ── Dispatch ────────────────────────────────────────────────────────
case "$ACTION" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *)         die 1 "unknown action: $ACTION (expected install or uninstall)" ;;
esac
