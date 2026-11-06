#!/bin/sh
# Semi-Transparent Parking Sensors — Install
# Replaces MiniView parking sensor PNGs with semi-transparent versions
# so the reverse camera image is visible through the corner overlay.
# Full-screen sensor views (HorizontalSensors, VerticalSensors) stay opaque.
#
# Original: vic_bam85 / Diginix (MZD-AIO)
#
# Contract: called by tweaksd with env TWEAK_DIR, TWEAKS_LIB, NO_REBOOT=1
# Must not reboot or remount. Exit 0=OK, non-0=error.

: "${TWEAK_DIR:=$(dirname "$0")}"
IMG="/jci/nativegui/images"
BACKUP="/data_persist/tweaks/backups/transparent-parking-sensor"

if [ ! -d "$IMG/MiniView" ]; then
    echo "E1: $IMG/MiniView not found"
    exit 1
fi
if [ ! -d "$TWEAK_DIR/files/MiniView" ]; then
    echo "E3: files/MiniView missing"
    exit 3
fi

if [ -f "$BACKUP/.installed" ]; then
    echo "Already installed"
    echo "OK"
    exit 0
fi

# Backup originals
mkdir -p "$BACKUP/MiniView"
cp -a "$IMG/MiniView/"*.png "$BACKUP/MiniView/" 2>/dev/null
echo "backed up MiniView"

# Copy transparent PNGs over stock ones (MiniView only)
fail=0
count=0
for f in "$TWEAK_DIR/files/MiniView/"*.png; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    if cp "$f" "$IMG/MiniView/$name"; then
        count=$((count + 1))
    else
        echo "FAIL: cp $name -> $IMG/MiniView/"
        fail=$((fail + 1))
    fi
done

if [ $fail -ne 0 ]; then
    echo "FAIL: $fail files failed to copy"
    exit 1
fi

echo "1" > "$BACKUP/.installed"
echo "replaced $count MiniView PNGs with semi-transparent versions"
echo "OK"
