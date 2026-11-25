#!/bin/sh
# SSH Access — Install
# Enables SSH on port 22 with password authentication.
# Sets root/cmu password to 'jci', creates sshd config, adds autostart.

TWEAK_DIR="${TWEAK_DIR:-$(dirname "$0")}"
LIB="${TWEAKS_LIB:-/data_persist/tweaks/lib/patch.sh}"
[ -f "$LIB" ] || LIB="$TWEAK_DIR/../../lib/patch.sh"
. "$LIB"

STAGE_WIFI="/jci/scripts/stage_wifi.sh"
SSHD_CONF="/data_persist/tweaks/sshd_tweaks.conf"

if [ ! -f "$STAGE_WIFI" ]; then
    echo "E1: stage_wifi.sh not found"
    exit 1
fi

# Break /etc/passwd symlink if needed
if [ -L /etc/passwd ]; then
    REAL=$(readlink -f /etc/passwd 2>/dev/null || readlink /etc/passwd 2>/dev/null)
    if [ -n "$REAL" ] && [ -f "$REAL" ]; then
        cp "$REAL" /etc/passwd.tmp && mv /etc/passwd.tmp /etc/passwd
        echo "broke /etc/passwd symlink -> writable copy"
    else
        for CAND in /config-mfg/passwd /jci/passwd /etc/passwd.orig; do
            if [ -f "$CAND" ]; then
                cp "$CAND" /etc/passwd.tmp && mv /etc/passwd.tmp /etc/passwd
                echo "broke symlink -> copy from $CAND"
                break
            fi
        done
    fi
fi
if [ ! -f /etc/passwd ]; then
    cat > /etc/passwd << 'PW'
root:x:0:0:root:/root:/bin/sh
cmu:x:0:0:root:/root:/bin/sh
sshd:x:74:74:sshd:/var/empty/sshd:/sbin/nologin
PW
    echo "created minimal /etc/passwd"
fi

# Set password for uid 0 user
UID0_USER=$(awk -F: '$3==0{print $1;exit}' /etc/passwd)
echo "${UID0_USER:-cmu}:jci" | chpasswd 2>/dev/null || {
    HASH=$(openssl passwd -1 jci 2>/dev/null)
    [ -n "$HASH" ] && sed -i "s|^${UID0_USER:-cmu}:[^:]*:|${UID0_USER:-cmu}:${HASH}:|" /etc/passwd 2>/dev/null
}
echo "password set for ${UID0_USER:-cmu}"

# Create sshd config
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
echo "sshd config created"

# Create required dirs
mkdir -p /var/empty/sshd /tmp/ssh /etc/ssh 2>/dev/null

# Generate host keys if missing
[ ! -f /etc/ssh_host_rsa_key ] && ssh-keygen -t rsa -f /etc/ssh_host_rsa_key -N '' 2>/dev/null
[ ! -f /etc/ssh_host_dsa_key ] && ssh-keygen -t dsa -f /etc/ssh_host_dsa_key -N '' 2>/dev/null
[ ! -f /etc/ssh/ssh_host_rsa_key ] && cp /etc/ssh_host_rsa_key /etc/ssh/ 2>/dev/null
[ ! -f /etc/ssh/ssh_host_dsa_key ] && cp /etc/ssh_host_dsa_key /etc/ssh/ 2>/dev/null

if grep -q '# tweaks:ssh-access:begin' "$STAGE_WIFI" 2>/dev/null; then
    echo "Already installed (autostart block exists)"
    echo "OK"
    exit 0
fi

patch_begin "$STAGE_WIFI" "ssh-access"

patch_append_block "tweaks:ssh-access" \
'mkdir -p /var/empty/sshd /tmp/ssh 2>/dev/null
/usr/sbin/sshd -f /data_persist/tweaks/sshd_tweaks.conf 2>/dev/null' \
"SSH autostart"

patch_verify 'tweaks:ssh-access:begin' "marker exists"

RES=$(patch_commit)
RET=$?

if [ $RET -ne 0 ]; then
    echo "$RES"
    exit 1
fi
echo "$RES"

# Start sshd now
/usr/sbin/sshd -f "$SSHD_CONF" 2>/dev/null || true
echo "SSH enabled on port 22 (user: ${UID0_USER:-cmu}, pass: jci)"
