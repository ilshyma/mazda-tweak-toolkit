#!/bin/sh
# SSH Access — Uninstall
# Removes sshd autostart from stage_wifi.sh and stops sshd
#
# Contract: called by tweaksd with env TWEAK_DIR, TWEAKS_LIB, NO_REBOOT=1
# Must not reboot or remount. Exit 0=OK, non-0=error.

STAGE="/jci/scripts/stage_wifi.sh"
BACKUP="/data_persist/tweaks/backups/ssh-access"

if ! grep -q '# tweaks:ssh-access' "$STAGE" 2>/dev/null; then
    echo "Not installed"
    exit 0
fi

# Remove the appended block
sed -i '/# tweaks:ssh-access/,/\/usr\/sbin\/sshd/d' "$STAGE"

# Kill running sshd
killall sshd 2>/dev/null || true

echo "SSH disabled"
echo "OK"
