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
    # ── System backup to USB (before any changes) ─────────────────
    log "[1/7] Creating system backup on USB..."
    BAK_USB="$USB/tweaks-manager/backup"
    mkdir -p "$BAK_USB/jci_scripts" "$BAK_USB/etc" "$BAK_USB/jci_opera" "$BAK_USB/jci_sm" 2>/dev/null
    for F in /jci/scripts/stage_wifi.sh /jci/scripts/stage_2.sh; do
        [ -f "$F" ] && cp -a "$F" "$BAK_USB/jci_scripts/" 2>/dev/null
    done
    if [ -L /etc/passwd ]; then
        cp -aL /etc/passwd "$BAK_USB/etc/passwd" 2>/dev/null
    elif [ -f /etc/passwd ]; then
        cp -a /etc/passwd "$BAK_USB/etc/" 2>/dev/null
    fi
    [ -f /jci/opera/opera_home/opera.ini ] && cp -a /jci/opera/opera_home/opera.ini "$BAK_USB/jci_opera/" 2>/dev/null
    for F in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do
        [ -f "$F" ] && cp -a "$F" "$BAK_USB/jci_sm/" 2>/dev/null
    done
    [ -f /jci/gui/index.html ] && cp -a /jci/gui/index.html "$BAK_USB/" 2>/dev/null
    log "[1/7] Backup saved to USB: tweaks-manager/backup/"

    # ── Network infrastructure (permanent — never removed) ────────
    # WiFi AP, iptables flush, SSH on port 22 with password auth.
    # These are installed ONCE and persist through uninstall/reinstall.
    # Factory sshd (port 36000, key-only) is not touched.
    log "[2/7] Setting up network infrastructure..."
    STAGE_WIFI="/jci/scripts/stage_wifi.sh"
    SSHD_CONF="/data_persist/tweaks/sshd_tweaks.conf"
    if [ -f "$STAGE_WIFI" ]; then
        # Break /etc/passwd symlink (stock points to read-only squashfs)
        if [ -L /etc/passwd ]; then
            REAL=$(readlink -f /etc/passwd 2>/dev/null)
            if [ -z "$REAL" ]; then
                REAL=$(readlink /etc/passwd 2>/dev/null)
            fi
            if [ -n "$REAL" ] && [ -f "$REAL" ]; then
                if cp "$REAL" /etc/passwd.tmp && mv /etc/passwd.tmp /etc/passwd; then
                    log "[2/7] broke /etc/passwd symlink -> writable copy"
                else
                    rm -f /etc/passwd.tmp
                    ln -sf "$REAL" /etc/passwd
                    log "[2/7] WARN: atomic copy failed, symlink restored"
                fi
            else
                for CAND in /config-mfg/passwd /jci/passwd /etc/passwd.orig; do
                    if [ -f "$CAND" ]; then
                        cp "$CAND" /etc/passwd.tmp && mv /etc/passwd.tmp /etc/passwd
                        log "[2/7] broke /etc/passwd symlink -> copy from $CAND"
                        break
                    fi
                done
                if [ ! -f /etc/passwd ]; then
                    echo "root:x:0:0:root:/root:/bin/sh" > /etc/passwd
                    log "[2/7] WARN: no passwd source found, created minimal /etc/passwd"
                fi
            fi
        fi
        if [ ! -f /etc/passwd ]; then
            echo "root:x:0:0:root:/root:/bin/sh" > /etc/passwd
            log "[2/7] WARN: /etc/passwd was missing, created minimal"
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
        # Permanent network lines (no markers — survive uninstall)
        # WiFi AP
        if ! grep -q 'jci-wifiap.sh start' "$STAGE_WIFI" 2>/dev/null; then
            echo '/jci/scripts/jci-wifiap.sh start 2>/dev/null' >> "$STAGE_WIFI"
            log "[2/7] WiFi AP added to stage_wifi.sh"
        else
            log "[2/7] WiFi AP already in stage_wifi.sh"
        fi
        # iptables flush
        if ! grep -q 'iptables -F' "$STAGE_WIFI" 2>/dev/null; then
            { echo 'iptables -F 2>/dev/null'; echo 'iptables -P INPUT ACCEPT 2>/dev/null'; } >> "$STAGE_WIFI"
            log "[2/7] iptables flush added to stage_wifi.sh"
        else
            log "[2/7] iptables flush already in stage_wifi.sh"
        fi
        # SSH dirs
        if ! grep -q 'mkdir -p /var/empty/sshd' "$STAGE_WIFI" 2>/dev/null; then
            echo 'mkdir -p /var/empty/sshd /tmp/ssh 2>/dev/null' >> "$STAGE_WIFI"
        fi
        # SSH daemon (port 22, password auth)
        if ! grep -q 'sshd_tweaks.conf' "$STAGE_WIFI" 2>/dev/null; then
            echo '/usr/sbin/sshd -f /data_persist/tweaks/sshd_tweaks.conf 2>/dev/null' >> "$STAGE_WIFI"
            log "[2/7] SSH autostart added to stage_wifi.sh"
        else
            log "[2/7] SSH autostart already in stage_wifi.sh"
        fi
        # Strip old markers if present (keep the actual commands)
        if grep -q '# tweaks:ssh-safety' "$STAGE_WIFI" 2>/dev/null; then
            sed -i '/# tweaks:ssh-safety/d' "$STAGE_WIFI"
            log "[2/7] removed old ssh-safety markers"
        fi
        if grep -q '# tweaks:ssh-access' "$STAGE_WIFI" 2>/dev/null; then
            sed -i '/# tweaks:ssh-access/d' "$STAGE_WIFI"
            log "[2/7] removed old ssh-access marker"
        fi
        # Start sshd right now
        /usr/sbin/sshd -f "$SSHD_CONF" 2>/dev/null || true
        # Start WiFi AP right now
        /jci/scripts/jci-wifiap.sh start 2>/dev/null || true
        # Flush iptables right now
        iptables -F 2>/dev/null
        iptables -P INPUT ACCEPT 2>/dev/null
        log "[2/7] Network ready — WiFi AP + SSH (port 22, pass:jci) + iptables flushed"
    else
        log "[2/7] WARN: stage_wifi.sh not found, network infrastructure not set up"
    fi

    log "[3/7] Copying daemon..."
    mkdir -p /data_persist/tweaks/installed
    mkdir -p /data_persist/tweaks/backups
    mkdir -p /data_persist/tweaks/scripts
    mkdir -p /data_persist/tweaks/lib

    cp "$INSTALLER_DIR/tweaksd" /data_persist/tweaks/tweaksd || die 3 "copy tweaksd failed"
    chmod 755 /data_persist/tweaks/tweaksd

    if [ -f "$INSTALLER_DIR/../lib/patch.sh" ]; then
        cp "$INSTALLER_DIR/../lib/patch.sh" /data_persist/tweaks/lib/patch.sh || log "[3/7] WARN: failed to copy patch.sh"
        chmod 755 /data_persist/tweaks/lib/patch.sh
        log "[3/7] patch.sh copied"
    fi
    log "[3/7] daemon copied"

    # ── Named backup (idempotent) ───────────────────────────────────
    log "[4/7] Backing up configs..."
    BAK="/data_persist/$(basename "$CONF").bak_tweaks"
    if [ -f "$BAK" ]; then
        log "[4/7] backup exists at $BAK, skipping"
    else
        cp -a "$CONF" "$BAK" || die 3 "backup of $CONF failed"
        log "[4/7] backup -> $BAK"
    fi

    # ── Stale cleanup from inactive config ──────────────────────────
    for OTHER in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do
        [ "$OTHER" = "$CONF" ] && continue
        [ -f "$OTHER" ] || continue
        if grep -q 'name="tweaksd"' "$OTHER"; then
            OBAK="/data_persist/$(basename "$OTHER").bak_tweaks"
            [ -f "$OBAK" ] || cp -a "$OTHER" "$OBAK"
            awk '/<service.*name="tweaksd"/{skip=1} /<\/service>/{if(skip){skip=0;next}} !skip' "$OTHER" > "$OTHER.tmp" && mv "$OTHER.tmp" "$OTHER"
            log "[4/7] removed stale tweaksd service from $OTHER"
        fi
    done

    # ── Boot autostart (tweaksd only — removable via markers) ───────
    log "[5/7] Setting up tweaksd boot autostart..."

    # Migrate: remove old stage_2.sh block if present
    STAGE2="/jci/scripts/stage_2.sh"
    if grep -q '# tweaks:tweaksd-autostart:begin' "$STAGE2" 2>/dev/null; then
        if [ -f "$PATCH_LIB" ]; then
            . "$PATCH_LIB"
            patch_begin "$STAGE2"
            patch_remove_block "tweaks:tweaksd-autostart" "migrate tweaksd from stage_2 to stage_wifi"
            patch_commit
        else
            awk '/# tweaks:tweaksd-autostart:begin/{skip=1;next} /# tweaks:tweaksd-autostart:end/{skip=0;next} !skip' \
                "$STAGE2" > "$STAGE2.tmp" && mv "$STAGE2.tmp" "$STAGE2"
        fi
        log "[5/7] migrated: removed old autostart from stage_2.sh"
    fi
    # Clean legacy unmarked tweaksd lines from stage_2.sh
    if grep -q "tweaksd" "$STAGE2" 2>/dev/null; then
        awk '/# Tweaks Manager/{skip=1;next} skip && /^\) &/{skip=0;next} skip{next} {print}' \
            "$STAGE2" > "$STAGE2.tmp" && mv "$STAGE2.tmp" "$STAGE2"
        sed -i '/^[[:space:]]*\/data_persist\/tweaks\/tweaksd/d' "$STAGE2"
        log "[5/7] cleaned up legacy tweaksd lines from stage_2.sh"
    fi

    # Add autostart to stage_wifi.sh (alongside network infra)
    if ! grep -q '# tweaks:tweaksd-autostart:begin' "$STAGE_WIFI" 2>/dev/null; then
        if [ -f "$PATCH_LIB" ]; then
            . "$PATCH_LIB"
            patch_begin "$STAGE_WIFI"
            patch_append_block "tweaks:tweaksd-autostart" '/data_persist/tweaks/tweaksd 2>/dev/null' "tweaksd boot autostart"
            patch_commit
        else
            cat >> "$STAGE_WIFI" << 'AUTOSTART'

# tweaks:tweaksd-autostart:begin
/data_persist/tweaks/tweaksd 2>/dev/null
# tweaks:tweaksd-autostart:end
AUTOSTART
        fi
        log "[5/7] boot autostart added to stage_wifi.sh"
    else
        log "[5/7] boot autostart already present in stage_wifi.sh"
    fi

    # Legacy autorun cleanup — remove broken remnants from v1.3.1 uninstall bug
    AUTORUN="/data_persist/dev/bin/autorun"
    if [ -f "$AUTORUN" ]; then
        if grep -q "tweaksd" "$AUTORUN" 2>/dev/null; then
            sed -i '/tweaksd/d' "$AUTORUN"
            sed -i '/# Tweaks Manager daemon/d' "$AUTORUN"
            log "[5/7] cleaned up legacy autorun tweaksd lines"
        fi
        LINES=$(grep -cv '^[[:space:]]*$' "$AUTORUN" 2>/dev/null || echo 0)
        if [ "$LINES" -le 3 ]; then
            CONTENT=$(grep -v '^[[:space:]]*$\|^#' "$AUTORUN" 2>/dev/null || true)
            case "$CONTENT" in
                *fi*|*sleep*|"") rm -f "$AUTORUN"; log "[5/7] removed broken autorun" ;;
            esac
        fi
    fi

    # ── Deploy Settings icon (Opera userjs) ──────────────────────
    log "[6/7] Deploying tweaks-menu.js to Opera userjs..."
    USERJS_DIR="/jci/opera/opera_dir/userjs"
    USERJS_SRC="$USB/tweaks-manager/jci-app/tweaks-menu.js"
    mkdir -p "$USERJS_DIR"
    if [ -f "$USERJS_SRC" ]; then
        cp "$USERJS_SRC" "$USERJS_DIR/tweaks-menu.js"
        log "[6/7] tweaks-menu.js deployed"
    else
        log "[6/7] WARN: tweaks-menu.js not found on USB"
    fi
    # Clean up old bootstrap/app approach (now using overlay button)
    rm -f "$USERJS_DIR/tweaks-bootstrap.js"
    rm -f "$USERJS_DIR/tweaksApp.js"
    # Enable User JavaScript in Opera
    OPERA_INI="/jci/opera/opera_home/opera.ini"
    if [ -f "$OPERA_INI" ]; then
        if grep -q "User JavaScript=0" "$OPERA_INI" 2>/dev/null; then
            sed -i "s/User JavaScript=0/User JavaScript=1/" "$OPERA_INI"
            log "[6/7] User JavaScript enabled in opera.ini"
        elif ! grep -q "User JavaScript=1" "$OPERA_INI" 2>/dev/null; then
            sed -i '/\[User Prefs\]/a User JavaScript=1' "$OPERA_INI"
            log "[6/7] User JavaScript=1 added to opera.ini"
        else
            log "[6/7] User JavaScript already enabled"
        fi
    else
        log "[6/7] WARN: opera.ini not found"
    fi
    # Clear Opera bytecode/script cache so new userjs loads on restart
    rm -rf /jci/opera/opera_home/cache4 2>/dev/null
    rm -rf /jci/opera/opera_home/opcache 2>/dev/null
    rm -rf /jci/opera/opera_home/pstorage 2>/dev/null
    rm -rf /jci/opera/opera_home/vps 2>/dev/null
    log "[6/7] Opera cache cleared"
    # Restart Opera so it reloads userjs from disk (SM restarts it)
    killall opera 2>/dev/null
    log "[6/7] Opera restarted (userjs will reload)"
    # Clean up legacy wizard UI
    rm -rf /data_persist/tweaks/wizard
    rm -f /data_persist/tweaks/.wizard_state
    # Clean up legacy index.html injections
    if grep -q '_tweaks/' /jci/gui/index.html 2>/dev/null; then
        sed -i '/_tweaks\/tweaks-bootstrap.js/d' /jci/gui/index.html
        sed -i '/_tweaks\/tweaksApp.js/d' /jci/gui/index.html
        rm -rf /jci/gui/apps/_tweaks
        log "[6/7] cleaned up old index.html injections"
    fi

    # ── Finalize ────────────────────────────────────────────────────
    log "[7/7] Finalizing..."
    { echo "installed"; echo "$VERSION"; echo "$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null)"; } > /tmp/tweaksd_installed.tmp
    mv /tmp/tweaksd_installed.tmp /data_persist/tweaks/tweaksd_installed

    # Kill any running tweaksd (old binary on wrong port) and start the new one
    killall tweaksd 2>/dev/null
    sleep 1
    /data_persist/tweaks/tweaksd 2>/dev/null
    if killall -0 tweaksd 2>/dev/null; then
        log "[7/7] daemon started (v$VERSION, starts on boot)"
    else
        log "[7/7] WARN: daemon failed to start, will start on next boot"
    fi

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
    if grep -q "tweaksd" /jci/scripts/stage_wifi.sh 2>/dev/null; then
        log "boot autostart: OK"
    else
        log "boot autostart: MISSING"
    fi
    if [ -f /jci/opera/opera_dir/userjs/tweaks-menu.js ]; then
        log "popup (userjs): OK"
    else
        log "popup (userjs): MISSING"
    fi
    if grep -q 'jci-wifiap.sh start' /jci/scripts/stage_wifi.sh 2>/dev/null; then
        log "WiFi AP: OK (permanent)"
    else
        log "WiFi AP: MISSING"
    fi
    if grep -q 'iptables -F' /jci/scripts/stage_wifi.sh 2>/dev/null; then
        log "iptables flush: OK (permanent)"
    else
        log "iptables flush: MISSING"
    fi
    if grep -q 'sshd_tweaks.conf' /jci/scripts/stage_wifi.sh 2>/dev/null; then
        log "SSH autostart: OK (permanent)"
    else
        log "SSH autostart: MISSING"
    fi
    if [ -d "$BAK_USB" ]; then
        log "USB backup: OK ($BAK_USB)"
    else
        log "USB backup: MISSING"
    fi

    log "=== install complete ==="

    # ── Show result on head unit ────────────────────────────────────
    sleep 2
    /jci/tools/jci-dialog \
        --info \
        --title="Tweaks Manager" \
        --text="Installed! Reboot to activate.\n\nBackup files saved to USB.\nCopy tweaks-manager/backup/ to your computer." \
        --ok-label="OK" &
}

# ═══════════════════════════════════════════════════════════════════
#  UNINSTALL
#  WiFi AP, SSH, and iptables are PERMANENT — never removed.
#  Only tweaksd daemon and its autostart are removed.
# ═══════════════════════════════════════════════════════════════════
do_uninstall() {
    log "[1/4] Stopping daemon..."
    killall tweaksd 2>/dev/null
    log "[1/4] daemon stopped"

    log "[2/4] Cleaning UI files..."
    rm -f /jci/opera/opera_dir/userjs/tweaks-bootstrap.js
    rm -f /jci/opera/opera_dir/userjs/tweaksApp.js
    log "[2/4] legacy userjs removed (popup kept for re-install)"
    # Legacy wizard cleanup
    rm -rf /data_persist/tweaks/wizard
    rm -f /data_persist/tweaks/.wizard_state
    log "[2/4] wizard UI removed (legacy)"

    log "[3/4] Removing tweaksd boot autostart..."
    STAGE_WIFI="/jci/scripts/stage_wifi.sh"
    # Remove tweaksd autostart from stage_wifi.sh (marker-based)
    if grep -q '# tweaks:tweaksd-autostart:begin' "$STAGE_WIFI" 2>/dev/null; then
        if [ -f "$PATCH_LIB" ]; then
            . "$PATCH_LIB"
            patch_begin "$STAGE_WIFI"
            patch_remove_block "tweaks:tweaksd-autostart" "tweaksd boot autostart"
            patch_commit
        else
            awk '/# tweaks:tweaksd-autostart:begin/{skip=1;next} /# tweaks:tweaksd-autostart:end/{skip=0;next} !skip' \
                "$STAGE_WIFI" > "$STAGE_WIFI.tmp" && mv "$STAGE_WIFI.tmp" "$STAGE_WIFI"
        fi
        log "[3/4] tweaksd block removed from stage_wifi.sh"
    fi
    # Legacy: remove from stage_2.sh (old location)
    STAGE2="/jci/scripts/stage_2.sh"
    if grep -q '# tweaks:tweaksd-autostart:begin' "$STAGE2" 2>/dev/null; then
        if [ -f "$PATCH_LIB" ]; then
            . "$PATCH_LIB"
            patch_begin "$STAGE2"
            patch_remove_block "tweaks:tweaksd-autostart" "tweaksd boot autostart (legacy)"
            patch_commit
        else
            awk '/# tweaks:tweaksd-autostart:begin/{skip=1;next} /# tweaks:tweaksd-autostart:end/{skip=0;next} !skip' \
                "$STAGE2" > "$STAGE2.tmp" && mv "$STAGE2.tmp" "$STAGE2"
        fi
        log "[3/4] removed legacy tweaksd block from stage_2.sh"
    elif grep -q "tweaksd" "$STAGE2" 2>/dev/null; then
        awk '/# Tweaks Manager/{skip=1;next} skip && /^\) &/{skip=0;next} skip{next} {print}' \
            "$STAGE2" > "$STAGE2.tmp" && mv "$STAGE2.tmp" "$STAGE2"
        sed -i '/^[[:space:]]*\/data_persist\/tweaks\/tweaksd/d' "$STAGE2"
        log "[3/4] removed legacy tweaksd from stage_2.sh"
    fi

    # Legacy autorun cleanup
    AUTORUN=/data_persist/dev/bin/autorun
    if [ -f "$AUTORUN" ]; then
        if grep -q "tweaksd" "$AUTORUN" 2>/dev/null; then
            sed -i '/# Tweaks Manager daemon/d' "$AUTORUN"
            sed -i '/tweaksd/d' "$AUTORUN"
            log "[3/4] cleaned up legacy autorun"
        fi
        LINES=$(grep -cv '^[[:space:]]*$' "$AUTORUN" 2>/dev/null || echo 0)
        if [ "$LINES" -le 3 ]; then
            CONTENT=$(grep -v '^[[:space:]]*$\|^#' "$AUTORUN" 2>/dev/null || true)
            case "$CONTENT" in
                *fi*|*sleep*|"") rm -f "$AUTORUN"; log "[3/4] removed broken autorun" ;;
            esac
        fi
    fi

    # Legacy sm.conf cleanup
    for SM in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do
        [ -f "$SM" ] || continue
        if grep -q "tweaksd" "$SM"; then
            awk '/<service.*name="tweaksd"/{skip=1} /<\/service>/{if(skip){skip=0;next}} !skip' "$SM" > "$SM.tmp" && mv "$SM.tmp" "$SM"
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
    if grep -q '# tweaks:tweaksd-autostart:begin' /jci/scripts/stage_wifi.sh 2>/dev/null; then
        log "tweaksd autostart: STILL EXISTS (bad)"
    else
        log "tweaksd autostart: removed OK"
    fi
    if grep -q "tweaksd" /jci/scripts/stage_2.sh 2>/dev/null; then
        log "legacy autostart: STILL EXISTS (bad)"
    else
        log "legacy autostart: removed OK"
    fi
    # WiFi/SSH/iptables should still be present — they are permanent
    if grep -q 'jci-wifiap.sh start' /jci/scripts/stage_wifi.sh 2>/dev/null; then
        log "WiFi AP: OK (permanent, kept)"
    fi
    if grep -q 'sshd_tweaks.conf' /jci/scripts/stage_wifi.sh 2>/dev/null; then
        log "SSH: OK (permanent, kept)"
    fi
    if [ -f /jci/opera/opera_dir/userjs/tweaks-menu.js ]; then
        log "popup (userjs): kept (for re-install)"
    fi

    log "=== uninstall complete ==="
}

# ── Dispatch ────────────────────────────────────────────────────────
case "$ACTION" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *)         die 1 "unknown action: $ACTION (expected install or uninstall)" ;;
esac
