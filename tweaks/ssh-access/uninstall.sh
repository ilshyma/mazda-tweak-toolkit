#!/bin/sh
# SSH Access — Uninstall
# Removes SSH autostart from stage_wifi.sh, stops sshd, removes config

TWEAK_DIR="${TWEAK_DIR:-$(dirname "$0")}"
LIB="${TWEAKS_LIB:-/data_persist/tweaks/lib/patch.sh}"
[ -f "$LIB" ] || LIB="$TWEAK_DIR/../../lib/patch.sh"
. "$LIB"

STAGE_WIFI="/jci/scripts/stage_wifi.sh"

if ! grep -q 'tweaks:ssh-access:begin' "$STAGE_WIFI" 2>/dev/null; then
    echo "Not installed"
    exit 0
fi

patch_begin "$STAGE_WIFI" "ssh-access"
patch_remove_block "tweaks:ssh-access" "SSH autostart block"
patch_verify_not 'tweaks:ssh-access' "markers removed"

RES=$(patch_commit)
RET=$?

if [ $RET -ne 0 ]; then
    echo "$RES"
    exit 1
fi
echo "$RES"

# Stop sshd on port 22
if [ -f /var/run/sshd_tweaks.pid ]; then
    kill $(cat /var/run/sshd_tweaks.pid) 2>/dev/null
    rm -f /var/run/sshd_tweaks.pid
fi

# Remove config
rm -f /data_persist/tweaks/sshd_tweaks.conf 2>/dev/null

# Restore /etc/passwd symlink if we broke it during install
PASSWD_BAK="/data_persist/tweaks/backups/ssh-access"
if [ -f "$PASSWD_BAK/passwd_symlink_target" ]; then
    TARGET=$(cat "$PASSWD_BAK/passwd_symlink_target")
    if [ -n "$TARGET" ] && [ -f "$TARGET" ]; then
        ln -sf "$TARGET" /etc/passwd
        echo "restored /etc/passwd symlink -> $TARGET"
    fi
    rm -f "$PASSWD_BAK/passwd_symlink_target"
fi

echo "SSH stopped and config removed"

[ "${NO_REBOOT:-0}" != "1" ] && (sleep 5 && reboot) >/dev/null 2>&1 &
