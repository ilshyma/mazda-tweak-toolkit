#!/bin/sh
# CarPlay + Android Auto HUD Navigation — Uninstall (unified)
# Removes all libpatch LD_PRELOAD shims, restores configs from backup

set -u
SELF_DIR=$(dirname "$0")
MOD_VERSION=$(cat "$SELF_DIR/files/VERSION" 2>/dev/null | tr -d '[:space:]')
: "${MOD_VERSION:=unknown}"
MOD_DIR=/data_persist/oem-aa-mod
BAK_DIR=/data_persist/hud-mod-backup
MASTER=/etc/devmgr_config_master.xml

echo "CarPlay + AA HUD Navigation v$MOD_VERSION — uninstall"
[ -f /jci/sm/sm.conf ] || [ -f /jci/sm/sm_WCP.conf ] || { echo "not a CMU"; exit 1; }
mount -o remount,rw / 2>/dev/null || { echo "remount rw failed"; exit 1; }

# Strip all libpatch LD_PRELOAD lines from both sm configs
for C in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do
  [ -f "$C" ] || continue
  grep -v 'env_name="LD_PRELOAD"[^>]*libpatch-' "$C" \
    | grep -v 'env_name="LD_LIBRARY_PATH" env_value="/jci/lib:/usr/lib"' > /tmp/hudmod.u \
    && sed -i '/name="jciCARPLAY"/ s/reset_board="no"/reset_board="yes"/' /tmp/hudmod.u \
    && cp /tmp/hudmod.u "$C"
  rm -f /tmp/hudmod.u
  echo "stripped LD_PRELOAD from $C"
done

# NaviSupported=FALSE
sed -i 's#<name>NaviSupported</name><value>TRUE</value>#<name>NaviSupported</name><value>FALSE</value>#' "$MASTER" 2>/dev/null
echo "NaviSupported=FALSE"

# Restore AA system attributes from backup
for x in aap_system_attributes.xml aap_system_attributes_UCP.xml; do
  if [ -f "$BAK_DIR/$x.orig" ]; then
    cp -a "$BAK_DIR/$x.orig" "/etc/$x"
    echo "restored /etc/$x from backup"
  elif [ -f "/etc/$x.orig" ]; then
    cp -a "/etc/$x.orig" "/etc/$x"
    echo "restored /etc/$x from .orig"
  fi
done

# Remove shim directory
rm -rf "$MOD_DIR"
rm -f /tmp/hud_oem_speed /tmp/hud_carplay_active
echo "removed $MOD_DIR"

# Also clean up old cp-hud-mod if present
rm -rf /data_persist/cp-hud-mod
rm -f /data_persist/splim_udpd_start.sh /data_persist/splim /mnt/data_persist/splim

sync
mount -o remount,ro / 2>/dev/null

echo '{"ok":true,"reboot":true}'
[ "${NO_REBOOT:-0}" != "1" ] && (sleep 5 && reboot) >/dev/null 2>&1 &
