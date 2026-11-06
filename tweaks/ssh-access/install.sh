#!/bin/sh
# SSH Access — Install
# Runs a SEPARATE sshd on port 22 with password auth enabled.
# Factory sshd (port 36000, key-only) is left untouched.
#
# After install, connect to CMU Wi-Fi AP and:
#   ssh root@192.168.53.1 -p 22
#   password: jci
#
# Contract: called by tweaksd with env TWEAK_DIR, TWEAKS_LIB, NO_REBOOT=1
# Must not reboot. Exit 0=OK, non-0=error.

STAGE="/jci/scripts/stage_wifi.sh"
BACKUP="/data_persist/tweaks/backups/ssh-access"
SSHD_CONF="/data_persist/tweaks/sshd_tweaks.conf"
SSHD_PID="/var/run/sshd_tweaks.pid"

if ! [ -f "$STAGE" ]; then
    echo "E1: $STAGE not found"
    exit 1
fi

# Already installed?
if grep -q '# tweaks:ssh-access' "$STAGE" 2>/dev/null; then
    # Make sure our sshd is running
    if [ -f "$SSHD_PID" ] && kill -0 "$(cat "$SSHD_PID")" 2>/dev/null; then
        : # already running
    else
        /usr/sbin/sshd -f "$SSHD_CONF" 2>/dev/null || true
    fi
    echo "Already installed"
    echo "OK"
    exit 0
fi

mount -o remount,rw / 2>/dev/null

# Backup original
mkdir -p "$BACKUP"
cp -a "$STAGE" "$BACKUP/stage_wifi.sh.bak"

# Set root password
echo "root:jci" | chpasswd 2>/dev/null || {
    HASH=$(echo -n 'jci' | openssl passwd -1 -stdin 2>/dev/null)
    [ -n "$HASH" ] && sed -i "s|^root:[^:]*:|root:${HASH}:|" /etc/shadow 2>/dev/null
}

# Create custom sshd config (port 22, password auth, separate from factory)
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

# Append sshd start to stage_wifi.sh (uses our custom config)
cat >> "$STAGE" << 'PATCH'

# tweaks:ssh-access — persistent SSH daemon (port 22, password auth)
/usr/sbin/sshd -f /data_persist/tweaks/sshd_tweaks.conf 2>/dev/null
PATCH

# Start sshd right now
/usr/sbin/sshd -f "$SSHD_CONF" 2>/dev/null || true

mount -o remount,ro / 2>/dev/null

echo "SSH enabled — ssh root@192.168.53.1 -p 22 pass:jci"
echo "OK"
