#!/bin/sh
# Camera Safety Warning Removal — Install
# Replaces SafetyText_*.png overlays with 1x1 transparent PNGs

IMG_DIR="/jci/nativegui/images"

if [ ! -d "$IMG_DIR" ]; then
    echo "E1: nativegui images dir not found"
    exit 1
fi

# Check at least one safety text PNG exists
if ! ls "$IMG_DIR"/SafetyText_*.png >/dev/null 2>&1; then
    echo "E1: no SafetyText PNGs found"
    exit 1
fi

mount -o remount,rw / 2>/dev/null

# Create minimal 1x1 transparent PNG (68 bytes)
# PNG header + IHDR + IDAT + IEND as hex
BLANK_PNG="/tmp/tweaks_blank.png"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n\xb4\x00\x00\x00\x00IEND\xaeB`\x82' > "$BLANK_PNG"

# Replace all SafetyText PNGs
count=0
fail=0
for f in "$IMG_DIR"/SafetyText_*.png; do
    [ -f "$f" ] || continue
    if cp "$BLANK_PNG" "$f"; then
        echo "replaced $(basename "$f")"
        count=$((count + 1))
    else
        echo "FAIL: cp $f"
        fail=$((fail + 1))
    fi
done

rm -f "$BLANK_PNG"

mount -o remount,ro / 2>/dev/null

if [ $fail -ne 0 ]; then
    echo "FAIL: $fail of $((count + fail)) files failed"
    exit 1
fi

echo "replaced $count SafetyText PNGs"
echo "OK"
