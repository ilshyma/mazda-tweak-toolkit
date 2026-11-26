#!/bin/sh
# Camera Safety Warning Removal — Install
# Replaces all SafetyText_*.png overlays with 1x1 transparent PNGs.
# Backs up originals to /data_persist for uninstall.
#
# Contract: called by tweaksd with env TWEAK_DIR, TWEAKS_LIB, NO_REBOOT=1
# Must not reboot or remount. Exit 0=OK, non-0=error.

IMG_DIR="/jci/nativegui/images"
BACKUP="/data_persist/tweaks/backups/no-camera-warning"

if [ ! -d "$IMG_DIR" ]; then
    echo "E1: nativegui images dir not found"
    exit 1
fi

if ! ls "$IMG_DIR"/SafetyText_*.png >/dev/null 2>&1; then
    echo "E2: no SafetyText PNGs found"
    exit 1
fi

if [ -f "$BACKUP/.installed" ]; then
    echo "Already installed"
    echo "OK"
    exit 0
fi

# Backup originals
mkdir -p "$BACKUP"
cp -a "$IMG_DIR"/SafetyText_*.png "$BACKUP/" 2>/dev/null
echo "backed up $(ls "$BACKUP"/SafetyText_*.png 2>/dev/null | wc -l) originals"

# Create minimal 1x1 transparent PNG (68 bytes)
BLANK_PNG="/tmp/tweaks_blank.png"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n\xb4\x00\x00\x00\x00IEND\xaeB`\x82' > "$BLANK_PNG"

# Replace all SafetyText PNGs
count=0
fail=0
for f in "$IMG_DIR"/SafetyText_*.png; do
    [ -f "$f" ] || continue
    if cp "$BLANK_PNG" "$f"; then
        count=$((count + 1))
    else
        echo "FAIL: cp $(basename "$f")"
        fail=$((fail + 1))
    fi
done

rm -f "$BLANK_PNG"

if [ $fail -ne 0 ]; then
    echo "FAIL: $fail of $((count + fail)) files failed"
    exit 1
fi

echo "1" > "$BACKUP/.installed"
echo "replaced $count SafetyText PNGs"
echo "OK"
