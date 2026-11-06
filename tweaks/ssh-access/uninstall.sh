#!/bin/sh
# SSH Access — Uninstall
# Stops our sshd (port 22) and removes autostart from stage_wifi.sh.
# Factory sshd (port 36000) is not affected.
#
# Contract: called by tweaksd with env TWEAK_DIR, TWEAKS_LIB, NO_REBOOT=1
# Must not reboot. Exit 0=OK, non-0=error.

STAGE="/jci/scripts/stage_wifi.sh"
SSHD_CONF="/data_persist/tweaks/sshd_tweaks.conf"
SSHD_PID="/var/run/sshd_tweaks.pid"

if ! grep -q '# tweaks:ssh-access' "$STAGE" 2>/dev/null; then
    echo "Not installed"
    exit 0
fi

mount -o remount,rw / 2>/dev/null

# Remove the appended block from stage_wifi.sh
sed -i '/# tweaks:ssh-access/,/sshd_tweaks\.conf/d' "$STAGE"

# Kill only our sshd (port 22), not factory (port 36000)
if [ -f "$SSHD_PID" ]; then
    kill "$(cat "$SSHD_PID")" 2>/dev/null
    rm -f "$SSHD_PID"
fi

mount -o remount,ro / 2>/dev/null

# Clean up config (on data_persist, no remount needed)
rm -f "$SSHD_CONF"

echo "SSH (port 22) disabled. Factory SSH (port 36000) unchanged."
echo "OK"
