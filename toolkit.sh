#!/bin/bash
# ============================================================================
#  Tweaks Manager — Toolkit
# ============================================================================
#  Interactive menu to build and prepare the Tweaks Manager for CMU.
#
#    1  Build tweaksd              — cross-compile ARM static binary
#    2  Prepare USB                — detect drive, copy everything
#    3  SSH Deploy                 — push directly to CMU over SSH
#    4  SSH Validate               — check installation on CMU
#    5  SSH Reboot CMU
#    S  SSH Shell (interactive)
#    0  Exit
# ============================================================================
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

# SSH config (optional — only needed for menu 3-5/S)
KEY="$DIR/../mazda-hud-toolkit/id_rsa_cmu"
CMU=cmu@192.168.53.1
PORT=36000

if [ -f "$KEY" ]; then
  chmod 600 "$KEY" 2>/dev/null
  SSHOPTS="-i $KEY -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes"
  SSH="ssh $SSHOPTS -p $PORT $CMU"
  SCP="scp $SSHOPTS -P $PORT"
  HAS_SSH=1
else
  HAS_SSH=0
fi

# --- colors ------------------------------------------------------------------
if [ -t 1 ]; then
  C_R=$'\033[31m';   C_G=$'\033[32m';   C_Y=$'\033[33m'
  C_B=$'\033[34m';   C_M=$'\033[35m';   C_C=$'\033[36m'
  C_BR=$'\033[1;31m';C_BG=$'\033[1;32m';C_BY=$'\033[1;33m'
  C_BC=$'\033[1;36m';C_BM=$'\033[1;35m'
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m';  C_0=$'\033[0m'
else
  C_R="";C_G="";C_Y="";C_B="";C_M="";C_C=""
  C_BR="";C_BG="";C_BY="";C_BC="";C_BM=""
  C_BOLD="";C_DIM="";C_0=""
fi

ok(){   printf "%s✓%s %s\n"  "$C_BG" "$C_0" "$*"; }
err(){  printf "%s✗%s %s\n"  "$C_BR" "$C_0" "$*"; }
warn(){ printf "%s!%s %s\n"  "$C_BY" "$C_0" "$*"; }
info(){ printf "%s▸%s %s\n"  "$C_BC" "$C_0" "$*"; }
hdr(){  echo; printf "%s═══ %s ═══%s\n" "$C_BC" "$*" "$C_0"; }

# ============================================================================
#  1. Build
# ============================================================================
build() {
  hdr "Build tweaksd (ARM musl static)"

  if ! command -v zig >/dev/null 2>&1; then
    err "zig not found — install with: brew install zig"
    return 1
  fi

  info "building..."
  if make -C "$DIR/tweaksd" clean all 2>&1 | sed 's/^/  /'; then
    local sz
    sz=$(wc -c < "$DIR/tweaksd/tweaksd" | tr -d ' ')
    local typ
    typ=$(file "$DIR/tweaksd/tweaksd" 2>/dev/null)
    echo
    if echo "$typ" | grep -q "ARM.*statically linked"; then
      ok "tweaksd: ARM static, $sz bytes"
    else
      warn "tweaksd built ($sz bytes) but type: $typ"
    fi
  else
    err "build failed"
    return 1
  fi
}

# ============================================================================
#  2. Prepare USB
# ============================================================================
prepare_usb() {
  hdr "Prepare USB drive"

  # Check binary exists
  if [ ! -f "$DIR/tweaksd/tweaksd" ]; then
    warn "tweaksd not built yet — building now..."
    build || { err "cannot prepare USB without tweaksd binary"; return 1; }
  fi

  # Detect USB drives
  info "detecting external USB drives..."
  echo

  local tmp
  tmp=$(mktemp -t twkusb) || { err "mktemp failed"; return 1; }

  # Find mounted volumes that look like USB drives (external, removable)
  # Method 1: diskutil (macOS)
  if command -v diskutil >/dev/null 2>&1; then
    diskutil list external 2>/dev/null | grep -E '^/dev/disk[0-9]+ \(external' > "$tmp"

    set --
    local n=0
    local line id dev sz name vol
    while IFS= read -r line; do
      id="${line%% *}"
      dev="${id##*/}"
      sz=$(diskutil info "$id" 2>/dev/null | awk -F': *' '/^ *Disk Size/{print $2; exit}')
      name=$(diskutil info "$id" 2>/dev/null | awk -F': *' '/^ *Device \/ Media Name/{print $2; exit}')
      # Find volume mount point
      vol=$(diskutil list "$id" 2>/dev/null | grep -oE '/Volumes/[^ ]+' | head -1)
      if [ -z "$vol" ]; then
        # Try to find mounted partition
        vol=$(mount | grep "${id}s" | awk '{print $3}' | head -1)
      fi
      if [ -z "$vol" ]; then
        vol="(not mounted)"
      fi
      n=$((n+1))
      set -- "$@" "$vol|${sz:-?} — ${name:-USB drive}"
    done < "$tmp"
    rm -f "$tmp"

    # Also check for already-mounted /Volumes that aren't system
    for v in /Volumes/*/; do
      [ -d "$v" ] || continue
      local vname="${v%/}"
      vname="${vname##*/}"
      case "$vname" in
        "Macintosh HD"|"Macintosh HD - Data"|"Recovery"|"Preboot") continue ;;
      esac
      # Check if already found
      local found=0
      local e
      for e in "$@"; do
        if echo "$e" | grep -q "$vname"; then found=1; break; fi
      done
      if [ "$found" -eq 0 ]; then
        local dsz
        dsz=$(df -h "/Volumes/$vname" 2>/dev/null | tail -1 | awk '{print $2}')
        n=$((n+1))
        set -- "$@" "/Volumes/$vname|${dsz:-?} — $vname"
      fi
    done
  else
    # Linux: check /media, /mnt, /run/media
    for mp in /media/*/* /mnt/* /run/media/*/*; do
      [ -d "$mp" ] || continue
      local dsz
      dsz=$(df -h "$mp" 2>/dev/null | tail -1 | awk '{print $2}')
      n=$((n+1))
      set -- "$@" "$mp|${dsz:-?} — $(basename "$mp")"
    done
  fi

  if [ "$#" -eq 0 ]; then
    err "no external USB drive found"
    info "plug in a FAT32-formatted USB drive and try again"
    return 1
  fi

  echo "Pick USB drive to prepare:"
  echo
  local i=1
  local e mnt lbl
  for e in "$@"; do
    mnt="${e%%|*}"
    lbl="${e#*|}"
    printf "  %s%d%s  %-30s  %s\n" "$C_BOLD" "$i" "$C_0" "$mnt" "$lbl"
    i=$((i+1))
  done
  printf "  %s0%s  cancel\n" "$C_BOLD" "$C_0"
  echo
  printf "> "
  read CH
  case "$CH" in
    ""|0) warn "cancelled"; return 0 ;;
    [1-9]|[1-9][0-9]) : ;;
    *) warn "invalid"; return 0 ;;
  esac
  if [ "$CH" -lt 1 ] || [ "$CH" -gt "$#" ]; then
    warn "invalid choice"; return 0
  fi

  local sel USB
  eval "sel=\${$CH}"
  USB="${sel%%|*}"

  if [ "$USB" = "(not mounted)" ]; then
    err "drive not mounted — mount it first"
    return 1
  fi
  if [ ! -d "$USB" ]; then
    err "mount point does not exist: $USB"
    return 1
  fi

  echo
  info "target: $USB"
  echo

  # ── Copy files ──

  info "1/5 · trampoline check"
  if [ -f "$USB/t" ]; then
    ok "  trampoline 't' present"
  else
    warn "  trampoline 't' not found — copy from hud-toolkit if needed"
  fi

  info "2/5 · installer entry point"
  export COPYFILE_DISABLE=1
  cp "$DIR/installer/tweaks.sh" "$USB/tweaks.sh" || { err "copy failed"; return 1; }
  ok "  tweaks.sh copied"

  info "3/5 · installer files"
  mkdir -p "$USB/tweaks-manager/installer"
  cp "$DIR/tweaksd/tweaksd" "$USB/tweaks-manager/installer/tweaksd" || { err "copy failed"; return 1; }
  chmod 755 "$USB/tweaks-manager/installer/tweaksd"
  ok "  tweaksd binary: $(wc -c < "$USB/tweaks-manager/installer/tweaksd" | tr -d ' ') bytes"

  info "4/5 · JCI app (userjs)"
  mkdir -p "$USB/tweaks-manager/jci-app"
  cp "$DIR/jci-app/tweaks-bootstrap.js" "$USB/tweaks-manager/jci-app/" || { err "copy failed"; return 1; }
  cp "$DIR/jci-app/tweaksApp.js" "$USB/tweaks-manager/jci-app/" || { err "copy failed"; return 1; }
  ok "  bootstrap + app JS"

  info "5/5 · tweaks"
  mkdir -p "$USB/tweaks-manager/tweaks"
  local tweak_count=0
  for tweak_dir in "$DIR/tweaks"/*/; do
    [ -d "$tweak_dir" ] || continue
    local tweak_id
    tweak_id=$(basename "$tweak_dir")
    mkdir -p "$USB/tweaks-manager/tweaks/$tweak_id"
    cp "$tweak_dir"/* "$USB/tweaks-manager/tweaks/$tweak_id/" 2>/dev/null || true
    tweak_count=$((tweak_count+1))
  done
  ok "  $tweak_count tweaks copied"

  # Strip macOS junk
  find "$USB/tweaks-manager" "$USB/tweaks.sh" \
    \( -name '._*' -o -name '.DS_Store' \) \
    -exec rm -rf {} + 2>/dev/null || true

  sync

  # ── Verify ──
  echo
  info "verifying..."
  local problems=0
  for f in tweaks.sh tweaks-manager/installer/tweaksd \
           tweaks-manager/jci-app/tweaks-bootstrap.js \
           tweaks-manager/jci-app/tweaksApp.js; do
    if [ -f "$USB/$f" ]; then
      local src_md5 dst_md5
      case "$f" in
        tweaks.sh)                               src_md5=$(md5 -q "$DIR/installer/tweaks.sh" 2>/dev/null) ;;
        tweaks-manager/installer/tweaksd)        src_md5=$(md5 -q "$DIR/tweaksd/tweaksd" 2>/dev/null) ;;
        tweaks-manager/jci-app/tweaks-bootstrap.js) src_md5=$(md5 -q "$DIR/jci-app/tweaks-bootstrap.js" 2>/dev/null) ;;
        tweaks-manager/jci-app/tweaksApp.js)     src_md5=$(md5 -q "$DIR/jci-app/tweaksApp.js" 2>/dev/null) ;;
      esac
      dst_md5=$(md5 -q "$USB/$f" 2>/dev/null)
      if [ "$src_md5" = "$dst_md5" ]; then
        ok "  $f"
      else
        err "  $f — md5 mismatch!"; problems=$((problems+1))
      fi
    else
      err "  MISSING: $f"; problems=$((problems+1))
    fi
  done

  # Check for AppleDouble junk
  local junk
  junk=$(find "$USB/tweaks-manager" -name '._*' 2>/dev/null | wc -l | tr -d ' ')
  if [ "${junk:-0}" -gt 0 ]; then
    err "  $junk AppleDouble sidecar files leaked"; problems=$((problems+1))
  fi

  echo
  if [ "$problems" -eq 0 ]; then
    ok "═══ USB READY ═══"
    echo
    info "structure:"
    find "$USB/tweaks-manager" -type f 2>/dev/null | sed "s|$USB/||" | sort | head -30 | sed 's/^/  /'
    echo
    info "install: insert USB → CMU detects .up → trampoline → tweaks.sh"
  else
    err "$problems problem(s) — check USB and try again"
  fi
}

# ============================================================================
#  SSH helpers
# ============================================================================
check_ssh() {
  if [ "$HAS_SSH" -eq 0 ]; then
    err "SSH key not found: $KEY"
    return 1
  fi
  if ping -c 2 -t 2 192.168.53.1 >/dev/null 2>&1 && \
     $SSH 'uname -a && uptime' 2>/dev/null; then
    ok "SSH ok"
  else
    err "SSH not reachable"
    return 1
  fi
}

push_file() {
  local src="$1" dst="$2" label="${3:-$(basename "$1")}"
  [ -f "$src" ] || { err "missing: $src"; return 1; }
  local want
  want=$(md5 -q "$src" 2>/dev/null || md5sum "$src" 2>/dev/null | awk '{print $1}')
  info "  → $label  →  $dst"
  local i=1 got
  while [ "$i" -le 3 ]; do
    [ "$i" -gt 1 ] && { warn "    retry $i/3..."; sleep 2; }
    if $SCP "$src" "$CMU:$dst" 2>&1 | sed 's/^/      /'; then
      got=$($SSH "md5sum '$dst' 2>/dev/null | awk '{print \$1}'" 2>/dev/null)
      if [ "$got" = "$want" ]; then ok "    verified"; return 0; fi
      warn "    md5 mismatch"
    fi
    i=$((i+1))
  done
  err "  failed after 3 attempts"; return 1
}

# ============================================================================
#  3. SSH Deploy
# ============================================================================
ssh_deploy() {
  hdr "SSH Deploy to CMU"
  [ -f "$DIR/tweaksd/tweaksd" ] || { err "tweaksd not built"; return 1; }
  local problems=0

  info "1/5 · remount rw"
  $SSH 'mount -o remount,rw /' || { err "remount failed"; return 1; }

  info "2/5 · tweaksd daemon"
  $SSH 'mkdir -p /data_persist/tweaks/installed /data_persist/tweaks/backups /data_persist/tweaks/scripts'
  push_file "$DIR/tweaksd/tweaksd" "/data_persist/tweaks/tweaksd" || problems=$((problems+1))
  $SSH 'chmod 755 /data_persist/tweaks/tweaksd'

  info "3/5 · Opera userjs"
  $SSH 'mkdir -p /jci/opera/opera_dir/userjs'
  push_file "$DIR/jci-app/tweaks-bootstrap.js" "/jci/opera/opera_dir/userjs/tweaks-bootstrap.js" || problems=$((problems+1))
  push_file "$DIR/jci-app/tweaksApp.js" "/jci/opera/opera_dir/userjs/tweaksApp.js" || problems=$((problems+1))
  $SSH '
    INI=/jci/opera/opera_home/opera.ini
    if grep -q "User JavaScript=0" "$INI" 2>/dev/null; then
      sed -i "s/User JavaScript=0/User JavaScript=1/" "$INI"
    elif ! grep -q "User JavaScript=1" "$INI" 2>/dev/null; then
      sed -i "/\[User Prefs\]/a User JavaScript=1" "$INI"
    fi
  '

  info "4/5 · autorun"
  $SSH '
    mkdir -p /data_persist/dev/bin
    AUTORUN=/data_persist/dev/bin/autorun
    [ -f "$AUTORUN" ] || { echo "#!/bin/sh" > "$AUTORUN"; chmod 755 "$AUTORUN"; }
    grep -q "tweaksd" "$AUTORUN" || cat >> "$AUTORUN" << "EOF"

# Tweaks Manager daemon
sleep 10
if [ -x /data_persist/tweaks/tweaksd ]; then
    /data_persist/tweaks/tweaksd &
fi
EOF
  '

  info "5/5 · cleanup + finalize"
  $SSH '
    # Legacy cleanup
    sed -i "/_tweaks\//d" /jci/gui/index.html 2>/dev/null
    rm -rf /jci/gui/apps/_tweaks 2>/dev/null
    for SM in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do
      [ -f "$SM" ] && sed -i "/<service.*name=\"tweaksd\"/,/<\/service>/d" "$SM" 2>/dev/null
    done
    echo "installed" > /data_persist/tweaks/tweaksd_installed
    echo "0.1.0" >> /data_persist/tweaks/tweaksd_installed
    date "+%Y-%m-%d %H:%M:%S" >> /data_persist/tweaks/tweaksd_installed
    mount -o remount,ro / 2>/dev/null; sync
  '

  if [ "$problems" -eq 0 ]; then
    ok "deploy complete"
    info "starting tweaksd..."
    $SSH 'killall tweaksd 2>/dev/null; sleep 1; /data_persist/tweaks/tweaksd &' 2>/dev/null
    sleep 2
    local api
    api=$($SSH 'wget -q -O- http://127.0.0.1:8035/api/version 2>/dev/null || curl -s http://127.0.0.1:8035/api/version 2>/dev/null' 2>/dev/null)
    if echo "$api" | grep -q "version"; then
      ok "API: $api"
    fi
    info "reboot CMU (option 5) to load userjs into Applications menu"
  else
    err "$problems problem(s) during deploy"
  fi
}

# ============================================================================
#  4. SSH Validate
# ============================================================================
ssh_validate() {
  hdr "Validate installation"
  $SSH '
    echo "── tweaksd ──"
    echo "  binary: $([ -x /data_persist/tweaks/tweaksd ] && echo OK || echo MISSING)"
    echo "  running: $(pgrep tweaksd | wc -l)"
    echo "  API: $(wget -q -O- http://127.0.0.1:8035/api/version 2>/dev/null || curl -s http://127.0.0.1:8035/api/version 2>/dev/null || echo FAIL)"
    echo
    echo "── userjs ──"
    echo "  User JavaScript: $(grep "User JavaScript" /jci/opera/opera_home/opera.ini 2>/dev/null)"
    ls -la /jci/opera/opera_dir/userjs/tweaks*.js 2>/dev/null | sed "s/^/  /" || echo "  MISSING"
    echo
    echo "── autorun ──"
    grep tweaksd /data_persist/dev/bin/autorun 2>/dev/null | sed "s/^/  /" || echo "  NOT IN AUTORUN"
    echo
    echo "── install ──"
    cat /data_persist/tweaks/tweaksd_installed 2>/dev/null | sed "s/^/  /" || echo "  NOT INSTALLED"
    echo
    echo "── system ──"
    echo "  fw: $(grep JCI_SW_VER /jci/version.ini 2>/dev/null | sed "s/.*=\"//" | sed "s/\".*//")"
    echo "  clock: $(date)"
    echo "  legacy index.html: $(grep -c "_tweaks/" /jci/gui/index.html 2>/dev/null || echo 0) refs"
    echo "  legacy sm.conf: $(grep -c tweaksd /jci/sm/sm.conf 2>/dev/null || echo 0) refs"
  '
}

# ============================================================================
#  MENU
# ============================================================================
while :; do
  echo
  printf "%s Tweaks Manager Toolkit %s\n" "$C_BOLD" "$C_0"

  printf "\n%s══════════════════════════════════════════════════════════%s\n" "$C_BG" "$C_0"
  printf "%s  LOCAL%s\n" "$C_BG" "$C_0"
  printf "%s══════════════════════════════════════════════════════════%s\n" "$C_BG" "$C_0"
  printf "  %s1%s   Build tweaksd  (cross-compile ARM binary)\n"           "$C_BOLD" "$C_0"
  printf "  %s2%s   Prepare USB  %s★ pick drive, copy everything%s\n"     "$C_BOLD" "$C_0" "$C_BM" "$C_0"

  printf "\n%s══════════════════════════════════════════════════════════%s\n" "$C_BY" "$C_0"
  printf "%s  SSH  (requires CMU WiFi connection)%s\n" "$C_BY" "$C_0"
  printf "%s══════════════════════════════════════════════════════════%s\n" "$C_BY" "$C_0"
  printf "  %s3%s   Deploy  (push all files to CMU)\n"                     "$C_BOLD" "$C_0"
  printf "  %s4%s   Validate  (check installation)\n"                      "$C_BOLD" "$C_0"
  printf "  %s5%s   Reboot CMU\n"                                          "$C_BOLD" "$C_0"
  printf "  %sS%s   Shell  (interactive SSH)\n"                             "$C_BOLD" "$C_0"

  printf "\n%s══════════════════════════════════════════════════════════%s\n" "$C_DIM" "$C_0"
  printf "  %s9%s   Check SSH\n" "$C_BOLD" "$C_0"
  printf "  %s0%s   Exit\n"      "$C_BOLD" "$C_0"
  echo

  printf "> "
  read C
  case "$C" in
    1) build ;;
    2) prepare_usb ;;
    3) check_ssh && ssh_deploy ;;
    4) check_ssh && ssh_validate ;;
    5) check_ssh && { $SSH 'sync && reboot'; ok "reboot sent"; } ;;
    S|s) check_ssh && $SSH ;;
    9) check_ssh ;;
    0|q|Q|"") exit 0 ;;
    *) warn "invalid" ;;
  esac
done
