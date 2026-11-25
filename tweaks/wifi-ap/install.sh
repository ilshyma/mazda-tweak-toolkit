#!/bin/sh
# WiFi Access Point — Install
# Enables WiFi AP on the CMU with iptables flush.
# Patches stage_wifi.sh for persistent WiFi AP on boot.

TWEAK_DIR="${TWEAK_DIR:-$(dirname "$0")}"
LIB="${TWEAKS_LIB:-/data_persist/tweaks/lib/patch.sh}"
[ -f "$LIB" ] || LIB="$TWEAK_DIR/../../lib/patch.sh"
. "$LIB"

STAGE_WIFI="/jci/scripts/stage_wifi.sh"

if [ ! -f "$STAGE_WIFI" ]; then
    echo "E1: stage_wifi.sh not found"
    exit 1
fi

# Break /etc/passwd symlink if needed (prerequisite for password auth)
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
    echo "root:x:0:0:root:/root:/bin/sh" > /etc/passwd
    echo "created minimal /etc/passwd"
fi

if grep -q '# tweaks:wifi-ap:begin' "$STAGE_WIFI" 2>/dev/null; then
    echo "Already installed"
    echo "OK"
    exit 0
fi

patch_begin "$STAGE_WIFI" "wifi-ap"

patch_append_block "tweaks:wifi-ap" \
'/jci/scripts/jci-wifiap.sh start 2>/dev/null
iptables -F 2>/dev/null
iptables -P INPUT ACCEPT 2>/dev/null' \
"WiFi AP + iptables flush"

patch_verify 'tweaks:wifi-ap:begin' "marker exists"

RES=$(patch_commit)
RET=$?

if [ $RET -ne 0 ]; then
    echo "$RES"
    exit 1
fi
echo "$RES"

# Apply immediately
/jci/scripts/jci-wifiap.sh start 2>/dev/null || true
iptables -F 2>/dev/null
iptables -P INPUT ACCEPT 2>/dev/null
echo "WiFi AP enabled (192.168.53.1)"
