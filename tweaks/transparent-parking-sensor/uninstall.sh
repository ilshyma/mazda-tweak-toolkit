#!/bin/sh
# Semi-Transparent Parking Sensors — Uninstall
# Restores original parking sensor PNGs from backup
#
# Contract: called by tweaksd with env TWEAK_DIR, TWEAKS_LIB, NO_REBOOT=1
# Must not reboot or remount. Exit 0=OK, non-0=error.

IMG="/jci/nativegui/images"
BACKUP="/data_persist/tweaks/backups/transparent-parking-sensor"

if [ ! -f "$BACKUP/.installed" ]; then
    echo "Not installed"
    exit 0
fi

fail=0
count=0
for dir in HorizontalSensors VerticalSensors MiniView; do
    if [ ! -d "$BACKUP/$dir" ]; then
        echo "WARN: no backup for $dir"
        continue
    fi
    for f in "$BACKUP/$dir/"*.png; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        if cp "$f" "$IMG/$dir/$name"; then
            count=$((count + 1))
        else
            echo "FAIL: restore $name"
            fail=$((fail + 1))
        fi
    done
done

rm -f "$BACKUP/.installed"

if [ $fail -ne 0 ]; then
    echo "FAIL: $fail files failed to restore"
    exit 1
fi

echo "restored $count original PNGs"
echo "OK"
