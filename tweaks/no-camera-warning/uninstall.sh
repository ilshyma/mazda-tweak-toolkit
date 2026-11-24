#!/bin/sh
# Camera Safety Warning Removal — Uninstall
# Restores original SafetyText_*.png files from backup.
#
# Contract: called by tweaksd with env TWEAK_DIR, TWEAKS_LIB, NO_REBOOT=1
# Must not reboot or remount. Exit 0=OK, non-0=error.

IMG_DIR="/jci/nativegui/images"
BACKUP="/data_persist/tweaks/backups/no-camera-warning"

if [ ! -f "$BACKUP/.installed" ]; then
    echo "Not installed"
    exit 0
fi

if ! ls "$BACKUP"/SafetyText_*.png >/dev/null 2>&1; then
    echo "E1: backup PNGs missing — cannot restore"
    exit 1
fi

count=0
fail=0
for f in "$BACKUP"/SafetyText_*.png; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    if cp "$f" "$IMG_DIR/$name"; then
        count=$((count + 1))
    else
        echo "FAIL: restore $name"
        fail=$((fail + 1))
    fi
done

if [ $fail -ne 0 ]; then
    echo "FAIL: $fail files failed to restore"
    exit 1
fi

rm -f "$BACKUP/.installed"

echo "restored $count SafetyText PNGs"
echo "OK"
