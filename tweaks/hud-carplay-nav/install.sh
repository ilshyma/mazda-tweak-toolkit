#!/bin/sh
# CarPlay + Android Auto HUD Navigation — Install (unified)
# Deploys 4 LD_PRELOAD shims for CarPlay, Android Auto, svcjcinavi, aap_service
# Based on mazda-hud-toolkit unified installer by ilshyma

set -u
TWEAK_DIR="$(dirname "$0")"
FILES="$TWEAK_DIR/files"
MOD_VERSION=$(cat "$FILES/VERSION" 2>/dev/null | tr -d '[:space:]')
: "${MOD_VERSION:=unknown}"
MOD_DIR=/data_persist/oem-aa-mod
BAK_DIR=/data_persist/hud-mod-backup
MASTER=/etc/devmgr_config_master.xml
SHIMS="blmjcicarplay blmjciaapa svcjcinavi aap_service"
SVCNAVI_MD5=100adcd8b110d4d79afe2dc5e3e769b1

die() { echo "ERROR: $*"; mount -o remount,ro / 2>/dev/null; exit 1; }

echo "CarPlay + AA HUD Navigation v$MOD_VERSION"

# Preflight
if [ ! -f /jci/sm/sm.conf ] && [ ! -f /jci/sm/sm_WCP.conf ]; then
  die "not a CMU"
fi
for s in $SHIMS; do
  [ -f "$FILES/libpatch-$s.so" ] || die "missing libpatch-$s.so"
done
[ -f "$FILES/libpatch.conf" ] || die "missing libpatch.conf"

# Board type detection
BT=""
if [ -x /jci/scripts/get_board_type.sh ]; then
  /jci/scripts/get_board_type.sh >/dev/null 2>&1; BT=$?
fi
if [ "$BT" = "2" ] && [ -f /jci/sm/sm_WCP.conf ]; then
  CONF=/jci/sm/sm_WCP.conf; OTHER=/jci/sm/sm.conf
else
  CONF=/jci/sm/sm.conf; OTHER=/jci/sm/sm_WCP.conf
fi

# Helper: strip all libpatch LD_PRELOAD lines from a config
strip_conf() {
  grep -v 'env_name="LD_PRELOAD"[^>]*libpatch-' "$1" \
    | grep -v 'env_name="LD_LIBRARY_PATH" env_value="/jci/lib:/usr/lib"' > "$2"
}
env_line() {
  printf '            <environ_var env_name="%s" env_value="%s"/>\n' "$1" "$2"
}

# Preflight: verify target services exist and no foreign LD_PRELOAD
check_conf() {
  strip_conf "$1" /tmp/hudmod.chk || return 1
  awk '
    BEGIN { n = split("jciCARPLAY jciAAPA jcinavi aap_service", a); for (i = 1; i <= n; i++) T[a[i]] = 1 }
    /<service / { svc = ""; for (t in T) if (index($0, "name=\"" t "\"")) { svc = t; seen[t] = 1 } }
    svc != "" && /env_name="LD_PRELOAD"/ { print "  foreign LD_PRELOAD in " svc ": " $0; bad = 1 }
    /<\/service>/ { svc = "" }
    END { for (t in T) if (!(t in seen)) { print "  service " t " not found"; bad = 1 }; exit bad }
  ' /tmp/hudmod.chk
  r=$?; rm -f /tmp/hudmod.chk; return $r
}
check_conf "$CONF" || die "$CONF is not as expected (see above) — nothing changed"

mount -o remount,rw / 2>/dev/null || die "remount rw failed"
mkdir -p "$MOD_DIR" "$BAK_DIR" || die "mkdir failed"

backup_once() {
  [ -f "$1" ] || return 0
  b="$BAK_DIR/$(basename "$1").orig"
  src=$1
  [ -n "${2:-}" ] && [ -f "$2" ] && src=$2
  [ -f "$b" ] || cp -a "$src" "$b"
}

# 1) Deploy shims + config
for s in $SHIMS; do
  cp -f "$FILES/libpatch-$s.so" "$MOD_DIR/" || die "copy libpatch-$s.so failed"
  chmod 0644 "$MOD_DIR/libpatch-$s.so"
done
if [ -f "$MOD_DIR/libpatch.conf" ] && ! cmp -s "$FILES/libpatch.conf" "$MOD_DIR/libpatch.conf"; then
  cp -f "$FILES/libpatch.conf" "$MOD_DIR/libpatch.conf.new"
else
  cp -f "$FILES/libpatch.conf" "$MOD_DIR/libpatch.conf"
fi

# Disable force_street_name if svcjcinavi.so is not the known build
NAV_MD5=$(md5sum /jci/navi/svcjcinavi.so 2>/dev/null | cut -d' ' -f1)
if [ -n "$NAV_MD5" ] && [ "$NAV_MD5" != "$SVCNAVI_MD5" ]; then
  sed -i -e 's/^[[:space:]]*force_street_name[[:space:]]*=.*/force_street_name = false/' \
         -e 's/^[[:space:]]*force_street_name_native[[:space:]]*=.*/force_street_name_native = false/' "$MOD_DIR/libpatch.conf"
fi

# 2) Patch sm configs: LD_PRELOAD for all 4 services
for C in "$CONF" "$OTHER"; do
  [ -f "$C" ] || continue
  backup_once "$C"
  strip_conf "$C" /tmp/hudmod.strip || die "strip failed on $C"
  if [ "$C" = "$CONF" ]; then
    awk -v cp="$(env_line LD_PRELOAD "$MOD_DIR/libpatch-blmjcicarplay.so")" \
        -v lp="$(env_line LD_LIBRARY_PATH /jci/lib:/usr/lib)" \
        -v aa="$(env_line LD_PRELOAD "$MOD_DIR/libpatch-blmjciaapa.so")" \
        -v nv="$(env_line LD_PRELOAD "$MOD_DIR/libpatch-svcjcinavi.so")" \
        -v as="$(env_line LD_PRELOAD "$MOD_DIR/libpatch-aap_service.so")" '
      { print }
      /<service / && /name="jciCARPLAY"/  { print cp; print lp; n++ }
      /<service / && /name="jciAAPA"/     { print aa; n++ }
      /<service / && /name="jcinavi"/     { print nv; n++ }
      /<service / && /name="aap_service"/ { print as; n++ }
      END { if (n != 4) exit 3 }
    ' /tmp/hudmod.strip > /tmp/hudmod.new || die "expected 4 target services in $C"

    # Sanity check: non-mod line count must match
    base=$(grep -vc 'libpatch-\|LD_LIBRARY_PATH" env_value="/jci/lib:/usr/lib"' "$C")
    new=$(grep -vc 'libpatch-\|LD_LIBRARY_PATH" env_value="/jci/lib:/usr/lib"' /tmp/hudmod.new)
    [ "$base" = "$new" ] || die "$C: sanity check failed ($base vs $new non-mod lines), left untouched"

    sed -i '/name="jciCARPLAY"/ s/reset_board="yes"/reset_board="no"/' /tmp/hudmod.new
  else
    cp /tmp/hudmod.strip /tmp/hudmod.new
  fi
  cp /tmp/hudmod.new "$C" || die "write $C failed"
done
rm -f /tmp/hudmod.strip /tmp/hudmod.new

# 3) NaviSupported=TRUE
if [ -f "$MASTER" ]; then
  backup_once "$MASTER"
  sed -i 's#<name>NaviSupported</name><value>FALSE</value>#<name>NaviSupported</name><value>TRUE</value>#' "$MASTER"
fi

# 4) AA system attributes (navigation subscribe for HUD)
for x in aap_system_attributes.xml aap_system_attributes_UCP.xml; do
  [ -f "$FILES/$x" ] || continue
  missing=""
  for f in $(grep -oE '<(root_cert_file|client_cert_file|private_key_file)>[^<]+' "$FILES/$x" | sed 's/^<[a-z_]*>//'); do
    [ -f "$f" ] || missing="$missing $f"
  done
  [ -n "$missing" ] && continue
  backup_once "/etc/$x" "/etc/$x.orig"
  cp -f "$FILES/$x" "/etc/$x"
done

# 5) Retire old splim_bridge daemon (speed limit now built into svcjcinavi shim)
for p in $(ps | grep '[s]plim_udpd\|[s]plim_bridge' | awk '{print $1}'); do kill "$p" 2>/dev/null; done
rm -f /data_persist/splim_udpd_start.sh /data_persist/cp-hud-mod/splim_udpd \
      /data_persist/cp-hud-mod/splim_bridge.sh /data_persist/splim /tmp/splim_v16_last
rm -rf /tmp/splim_v16_cache

sync
mount -o remount,ro / 2>/dev/null

# Verify: log the actual state so tweaksd captures it
echo "=== VERIFY ==="
for s in jciCARPLAY jciAAPA jcinavi aap_service; do
  line=$(awk -v s="name=\"$s\"" 'index($0,s) && /<service /{f=1;next} f&&/LD_PRELOAD/{print;exit} f&&/<\/service>/{exit}' "$CONF")
  echo "  $s: $(echo "$line" | grep -oE 'libpatch-[a-z_]+\.so' || echo MISSING)"
done
echo "  NaviSupported=$(grep -oE '<name>NaviSupported</name><value>[A-Z]+' "$MASTER" 2>/dev/null | grep -oE '[A-Z]+$')"
echo "  config: $(grep -E '^(hud_transport|force_street_name|force_street_name_native|use_protocol_v1_6)' "$MOD_DIR/libpatch.conf" 2>/dev/null | tr '\n' ' ')"
echo "  shims:"
for s in $SHIMS; do
  f="$MOD_DIR/libpatch-$s.so"
  if [ -f "$f" ]; then
    echo "    $s: $(wc -c < "$f") bytes"
  else
    echo "    $s: MISSING"
  fi
done
echo "=== END ==="

echo '{"ok":true,"reboot":true}'
(sleep 5 && reboot) >/dev/null 2>&1 &
