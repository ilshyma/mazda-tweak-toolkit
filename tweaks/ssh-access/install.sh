#!/bin/sh
# SSH Access — Install
# Starts sshd and makes it persistent across reboots via stage_wifi.sh
#
# After install, connect to CMU Wi-Fi AP and:
#   ssh root@192.168.53.1 -o PubkeyAcceptedAlgorithms=+ssh-rsa
#   password: jci
#
# Contract: called by tweaksd with env TWEAK_DIR, TWEAKS_LIB, NO_REBOOT=1
# Must not reboot or remount. Exit 0=OK, non-0=error.

STAGE="/jci/scripts/stage_wifi.sh"
BACKUP="/data_persist/tweaks/backups/ssh-access"

if ! [ -f "$STAGE" ]; then
    echo "E1: $STAGE not found"
    exit 1
fi

# Already installed?
if grep -q '# tweaks:ssh-access' "$STAGE" 2>/dev/null; then
    /usr/sbin/sshd 2>/dev/null || true
    echo "Already installed"
    echo "OK"
    exit 0
fi

# Backup original
mkdir -p "$BACKUP"
cp -a "$STAGE" "$BACKUP/stage_wifi.sh.bak"

# Set root password
echo "root:jci" | chpasswd 2>/dev/null || {
    HASH=$(echo -n 'jci' | openssl passwd -1 -stdin 2>/dev/null)
    if [ -n "$HASH" ]; then
        sed -i "s|^root:[^:]*:|root:${HASH}:|" /etc/shadow 2>/dev/null
    fi
}

# Append sshd start to stage_wifi.sh
cat >> "$STAGE" << 'PATCH'

# tweaks:ssh-access — persistent SSH daemon
/usr/sbin/sshd 2>/dev/null
PATCH

# Start sshd right now
/usr/sbin/sshd 2>/dev/null || true

echo "SSH enabled — connect to 192.168.53.1 user:root pass:jci"
echo "OK"
