#!/bin/sh
# Semi-Transparent Parking Sensors — Install
# Replaces stock parking sensor PNGs with semi-transparent versions
# so the reverse camera image is visible through the overlay.
#
# Original: vic_bam85 / Diginix (MZD-AIO)
#
# Contract: called by tweaksd with env TWEAK_DIR, TWEAKS_LIB, NO_REBOOT=1
# Must not reboot or remount. Exit 0=OK, non-0=error.

: "${TWEAK_DIR:=$(dirname "$0")}"
IMG="/jci/nativegui/images"
BACKUP="/data_persist/tweaks/backups/transparent-parking-sensor"

for dir in HorizontalSensors VerticalSensors MiniView; do
    if [ ! -d "$IMG/$dir" ]; then
        echo "E1: $IMG/$dir not found"
        exit 1
    fi
    if [ ! -d "$TWEAK_DIR/files/$dir" ]; then
        echo "E3: files/$dir missing"
        exit 3
    fi
done

if [ -f "$BACKUP/.installed" ]; then
    echo "Already installed"
    echo "OK"
    exit 0
fi

# Backup originals
mkdir -p "$BACKUP/HorizontalSensors" "$BACKUP/VerticalSensors" "$BACKUP/MiniView"

for dir in HorizontalSensors VerticalSensors MiniView; do
    cp -a "$IMG/$dir/"*.png "$BACKUP/$dir/" 2>/dev/null
    echo "backed up $dir"
done

# Copy transparent PNGs over stock ones
fail=0
count=0
for dir in HorizontalSensors VerticalSensors MiniView; do
    for f in "$TWEAK_DIR/files/$dir/"*.png; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        if cp "$f" "$IMG/$dir/$name"; then
            count=$((count + 1))
        else
            echo "FAIL: cp $name -> $IMG/$dir/"
            fail=$((fail + 1))
        fi
    done
done

if [ $fail -ne 0 ]; then
    echo "FAIL: $fail files failed to copy"
    exit 1
fi

echo "1" > "$BACKUP/.installed"
echo "replaced $count PNGs with semi-transparent versions"
echo "OK"
