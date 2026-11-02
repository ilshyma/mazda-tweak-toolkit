# Tweaks Manager — Knowledge Base
> Auto-maintained by Claude sessions. DO NOT commit to git.
> Last updated: 2026-11-01

## Project Overview

Personal research project for Mazda CMU v74 (74.00.324, EU market).
Unlocks EU-market-restricted features on owner's own Mazda CX-5.
NOT for commercial distribution.

**Owner**: ilshyma (GitHub: ilshyma@users.noreply.github.com)
**Git repo**: /Users/vladstar/mazda-tweak-toolkit (files not yet pushed)
**Working dir**: /Users/vladstar/mazda/tweaks-manager

## Architecture

### Components

```
USB Drive (FAT32, MBR, label "MZD")
├── t                          — trigger binary (CVE-2024-8359)
├── tweaks.sh                  — USB runner script
├── jci-autoupdate             — reflash scanner trigger
├── dataRetrieval_config.txt   — data retrieval trigger
├── *.up                       — encoded shell command payloads (awk/sprintf)
├── MD5SUM                     — integrity checksums (BusyBox md5sum -c compat)
├── s, dev.html, js/, css/, mp3/ — XSS/SSH fallback (from HUD toolkit)
└── tweaks-manager/
    ├── installer/
    │   ├── tweaks.sh          — pure installer (no UI, exit codes 0-5)
    │   └── tweaksd            — ARM binary daemon
    ├── lib/
    │   └── patch.sh           — safe patching library
    ├── jci-app/
    │   └── tweaks-menu.js     — Opera 12 userjs UI
    └── tweaks/
        ├── hud-eu-region/     — HUD EU unlock (v2.0.0, reboot)
        ├── no-disclaimer/     — skip startup disclaimer (v1.0.0, reboot)
        ├── no-camera-warning/ — remove camera warning PNGs (v1.0.0, instant)
        └── touch-while-moving/— touch at any speed (v1.0.0, reboot)
```

```
CMU (on car)
├── /data_persist/tweaks/
│   ├── tweaksd                — daemon binary (ARM)
│   ├── tweaksd.log            — operation log
│   ├── tweaksd_installed      — install marker + version + date
│   ├── dump_done              — dump state file (contains dump path)
│   ├── installed/             — per-tweak installed records (tweak.json copies)
│   ├── backups/               — per-tweak file backups (originals before patch)
│   ├── scripts/               — generated scripts
│   └── lib/
│       └── patch.sh           — patching library
├── /jci/opera/opera_dir/userjs/
│   └── tweaks-menu.js         — UI auto-loaded by Opera 12
└── /jci/scripts/stage_2.sh    — boot autostart: sleep 12 && tweaksd &
```

### Entry Vectors (how USB triggers installation)

1. **CVE-2024-8359**: .up files with encoded `sh` commands trigger via firmware update scanner
   - Two payloads: one for `/mnt/sd[abcd]1/t`, one for `/tmp/mnt/sd[abcd]1/t`
   - The `t` binary runs `tweaks.sh` which calls `installer/tweaks.sh`
2. **XSS fallback**: MP3 autoplay + dev.html → SSH menu → manual trigger button
   - TM button injected into XSS menu by prepare-usb.sh (appended to run.js)

### tweaksd — C Daemon

- **Port**: 8035 (localhost only)
- **PID file**: /tmp/tweaksd.pid
- **Version**: 1.0.0 (hardcoded in main.c:14)
- **Daemonizes** unless `-f` flag
- **Signal handling**: SIGTERM/SIGINT → cleanup, SIGPIPE → ignore

#### API Routes (main.c:286-297)

| Route | Method | Handler | Notes |
|-------|--------|---------|-------|
| `/api/tweaks/list` | GET | handle_list | Refreshes list (installed + USB merge), returns JSON |
| `/api/tweaks/install/{id}` | POST | handle_install | Requires dump first, checks conflicts |
| `/api/tweaks/uninstall/{id}` | POST | handle_uninstall | Tries uninstall.sh, falls back to backup restore |
| `/api/tweaks/status/{id}` | GET | handle_status | Runs check.sh if available |
| `/api/tweaks/conflicts/{id}` | GET | handle_conflicts | Checks conflicts_with field |
| `/api/dump/status` | GET | handle_dump_status | Returns {exists, path} |
| `/api/dump/create` | POST | handle_dump_create | Creates system dump on USB |
| `/api/usb/scan` | GET | handle_usb_scan | Returns {usb_mounted, mount_count, tweaks_dir, new_tweaks[]} |
| `/api/backups/export` | POST | handle_backups_export | `cp -a` backups to USB |
| `/api/log` | GET | handle_log | Last 100 log lines as JSON |
| `/api/log/export` | POST | handle_log_export | `cp` log with timestamp to USB |
| `/api/version` | GET | handle_version | Returns {version, dump_exists} |

#### Key Data Structures (tweaks.h)

```c
tweak_t {
    id[64], name[128], version[32], description[256], author[64]
    min_firmware[16], max_firmware[16]
    regions[8][8], region_count
    modifies[MAX_MODIFIES][256], modifies_count    // files this tweak patches
    conflicts_with[MAX_CONFLICTS][64], conflicts_count
    depends_on[MAX_DEPENDS][64], depends_count
    requires_reboot                                 // 0 or 1
    // runtime:
    installed, installed_version[32], source_path[512], update_available
}
```

#### Install Flow (tweaks.c:280)

1. Validate tweak id (only `[a-zA-Z0-9_-]` — command injection protection)
2. Check busy lock (no concurrent operations)
3. Find tweak by id in list
4. Verify `source_path` exists (USB mounted)
5. `mount -o remount,rw /`
6. `tweaks_backup_files()` — copies each file in `modifies[]` to `/data_persist/tweaks/backups/{id}/`
7. Runs `sh '{source_path}/install.sh'` via popen (script does its own mount/remount/reboot)
8. **Re-mount rw** (script left rootfs ro)
9. Copies tweak.json to `/data_persist/tweaks/installed/{id}/`
10. `mount -o remount,ro /`
11. Returns `{ok, reboot}`

**Scripts are self-contained** — handle own remount rw/ro and `(sleep 5 && reboot) &`.
**tweaksd is resilient** — re-mounts rw after pclose() for bookkeeping cp.

#### Uninstall Flow (tweaks.c:378)

1. Validate tweak id
2. Check busy lock
3. Verify installed dir exists
4. `mount -o remount,rw /`
5. Try `uninstall.sh` from USB source first
6. If no USB script, try from installed dir
7. If no script at all, `tweaks_restore_files()` from backup
8. **Check script exit code** — abort if non-zero (keeps installed record)
9. **Re-mount rw** (script left rootfs ro)
10. Remove installed record: `rm -rf installed/{id}`
11. `mount -o remount,ro /`
12. Returns `{ok, reboot}`

#### Version Comparison (tweaks.c:510)

`version_compare(a, b)` — semver `%d.%d.%d` comparison via sscanf, returns difference.
`tweaks_merge_lists()` — sets `update_available=1` when USB version > installed version.

#### Backup/Export

- **tweaks_export_backups**: `cp -a` from `/data_persist/tweaks/backups` to `USB/tweaks-manager/backups/` — BLIND COPY, no diff
- **tweaksd_log_export**: Creates NEW timestamped file each time: `cp LOG_FILE USB/tweaks-manager/logs/tweaksd_YYYYMMDD_HHMMSS.log`

### Patching System (lib/patch.sh)

Safe patching library with atomic commit and rollback:

1. `patch_begin(file, marker)` — copies file to `.tweaks-work`
2. `patch_sed(expr, desc)` — sed on work file, checks md5 for change
3. `patch_sed_range(range, expr, desc)` — ranged sed
4. `patch_insert_after(pattern, newline, desc)` — insert after match
5. `patch_append(code, desc)` — append to file
6. `patch_append_file(srcfile, desc)` — append file contents
7. `patch_verify(pattern, desc)` — grep check (must match)
8. `patch_verify_not(pattern, desc)` — grep check (must NOT match)
9. `patch_verify_count(pattern, expected, desc)` — count check
10. `patch_commit()` — atomic: backup original → mv work → original
11. `patch_rollback(file)` — restore from `.tweaks-bak`

Markers: each patch leaves `/* tweaks:{id} */` comments for idempotency detection.
Cross-platform: `_sed_i()` handles macOS vs BusyBox `sed -i` difference.

### tweaks-menu.js — Opera 12 UI

- **Engine**: Opera 12 Presto (NO CSS vars, NO flexbox, NO grid, NO ES6)
- **All styles**: inline via `setS(el, {prop: val})` helper
- **Loaded as**: Opera userjs from `/jci/opera/opera_dir/userjs/`
- **Button**: Fixed bottom-right "TWEAKS", shown only when `framework._currentAppUiaId === 'syssettings' || 'vehsettings'`
- **Overlay**: Fullscreen fixed div, z-index 99999

#### UI Flow

1. Button click → `showUI()`
2. `loadData()`:
   - GET /api/version → fail = "tweaksd not running"
   - GET /api/usb/scan → no USB = blocked screen (renderNoUsb)
   - `doSync()` → POST /api/backups/export + POST /api/log/export → status bar
   - GET /api/dump/status → no dump = renderNoDump (CREATE DUMP button)
   - GET /api/tweaks/list → renderTweaks (card list)

#### Touch Scrolling

Custom implementation for CMU (no native scroll support):
- mousedown → record startY + scrollTop
- mousemove → calculate delta, set scrollTop
- mouseup/mouseout → clear state
- `data-action` attribute on interactive elements prevents scroll hijack

#### Colors (hardcoded, no CSS vars)

```
BG=#0b1120, HDR_BG=#0f172a, CARD_BG=#111827, CARD_BD=#1e293b
GREEN=#22c55e, YELLOW=#eab308, CYAN=#06b6d4, RED=#ef4444, BLUE=#38bdf8
TXT=#e2e8f0, TXT2=#94a3b8, TXT3=#64748b, BTN_BG=#1e293b, BTN_BG2=#374151
```

### USB Layout on CMU

Mount paths scanned (usb.c):
- `/tmp/mnt/sd{a,b,c,d}1`
- `/mnt/sd{a,b,c,d}1`

Detection: `stat()` on each path, check `S_ISDIR`.
Tweaks dir: `{mount}/tweaks-manager/tweaks/`

### CMU System Details

- **Firmware**: 74.00.324 (EU)
- **OS**: Linux (BusyBox — limited util flags)
- **Rootfs**: normally read-only, needs `mount -o remount,rw /` for writes
- **Board type**: `/jci/scripts/get_board_type.sh` → exit code (2=WCP)
- **Config**: `/jci/sm/sm.conf` or `/jci/sm/sm_WCP.conf` (WCP hardware)
- **GUI**: Chromium-like JCI framework, Opera 12 Presto for userjs
- **D-Bus**: `com.jci.vbs.settings` for vehicle settings (HUD, etc.)
- **XSS**: `/cgi-bin/cmdProc?cmd=...` for shell commands via HTTP

### Tweak Details

| ID | Name | Version | Reboot | Modifies |
|----|------|---------|--------|----------|
| hud-eu-region | HUD EU Region Unlock | 2.0.0 | yes | vehsettingsApp.js |
| no-disclaimer | No More Disclaimer | 1.0.0 | yes | systemApp.js |
| no-camera-warning | Camera Safety Warning Removal | 1.0.0 | no | 10x SafetyText PNGs |
| touch-while-moving | Touchscreen While Moving | 1.0.0 | yes | Common.js |
| hud-carplay-nav | CarPlay + AA HUD Navigation | 2.4.3 | yes | sm.conf, sm_WCP.conf, devmgr_config_master.xml, aap_system_attributes*.xml |

#### hud-carplay-nav install.sh (unified)

Deploys 4 LD_PRELOAD shims (not text-based patching — binary deployment):
1. Detect board type → pick sm.conf or sm_WCP.conf
2. Copy 4 shims + libpatch.conf to /data_persist/oem-aa-mod/
3. Patch active sm config: LD_PRELOAD for jciCARPLAY, jciAAPA, jcinavi, aap_service
4. Set NaviSupported=TRUE in /etc/devmgr_config_master.xml
5. Install AA system attribute XMLs (if unit has the referenced certificates)
6. Retire old splim_bridge daemon (speed limit now built into svcjcinavi shim)

Binary files shipped in tweaks/hud-carplay-nav/files/:
- libpatch-blmjcicarplay.so — CarPlay HUD shim (km/h fix)
- libpatch-blmjciaapa.so — Android Auto shim (touch, HUD, mute-pauses-phone)
- libpatch-svcjcinavi.so — OEM nav merge shim (speed limit, street name fix)
- libpatch-aap_service.so — AA GAL 1.6 navigation protocol
- libpatch.conf — runtime config for all shims
- aap_system_attributes*.xml — AA nav subscribe config

Backups: /data_persist/hud-mod-backup/*.orig (independent of patch.sh backup system)
Source: /Users/vladstar/Documents/mazda-hud-install/gh-work/mazda-hud-toolkit/files/unified/

#### hud-eu-region install.sh

Three patches using patch.sh library:
1. `region !== "Region_Europe"` → `true /* tweaks:hud-eu-region */` (unlock Street Info)
2. `region === "Region_Europe"` → `false /* tweaks:hud-eu-region */` (unlock extended nav modes)
3. Append: runtime injection of "Display Information" item to HUD tab list via prototype override

Idempotency check: `grep -q 'tweaks:hud-eu-region'` before patching.
HUD detection: D-Bus query `GetCMUControlReq int32:26` — if "0", no HUD.

### Build & Deploy

- **Cross-compile**: ARM target (toolchain not documented here yet)
- **Makefile**: `make -C tweaksd` (must produce ARM binary)
- **prepare-usb.sh**: Formats USB (FAT32/MBR/MZD), copies all payloads, creates .up files, generates MD5SUM
- **Verification**: checks ARM binary, .up payloads, AppleDouble cleanup

### Security Constraints

- Owner email MUST NEVER be exposed publicly
- Git config: user.name "ilshyma", user.email "ilshyma@users.noreply.github.com"
- Code not yet pushed to any repo
- Personal research only

## Design Decisions & Open Questions

### Decided
- USB is mandatory gate — TM inaccessible without USB
- Mandatory sync (backup + logs to USB) every time TM opens
- System dump required before any install
- Reboot button should be tied to install operations, not standalone
- Progress UI needed during install operations

### Open / In Progress
- **Sync mechanism**: Currently blind `cp -a` (backups) and new-timestamped-file (logs). Proposed: `cp -u` for incremental, single `/api/sync` endpoint
- **Menu structure**: Flat list → drill-down (list → detail with install/uninstall/upgrade)
- **Tweak upgrade**: Safe upgrade = uninstall old + install new (patches are text replacements that expect original content)
- **Auto-upgrade during sync**: Risky — see upgrade analysis below

### Upgrade Analysis

The patching system works by text replacement (`sed` + `patch_append`). Each install.sh expects to find ORIGINAL content in the target file:
- `hud-eu-region`: looks for `region !== "Region_Europe"` — if v1.0.0 already changed this, v2.0.0 install.sh won't find the pattern
- Each tweak has a `/* tweaks:{id} */` marker for idempotency

**Safe upgrade path**: uninstall old → install new. This is necessary because:
1. v0.1.0 replaced pattern A→B
2. v0.2.0 expects to find A (original) to replace with C
3. If B is present, v0.2.0 install.sh will either fail (pattern not found) or skip (no change)

The backup system stores originals per-tweak in `/data_persist/tweaks/backups/{id}/`. Uninstall restores from these backups, returning the file to its original state, after which a fresh install of the new version will work.

## File Index

### tweaksd (C daemon)
- `tweaksd/main.c` — entry, API handlers, daemonize
- `tweaksd/tweaks.c` — scan, merge, install, uninstall, backup, restore, version_compare, JSON output
- `tweaksd/tweaks.h` — tweak_t struct, function declarations, path constants
- `tweaksd/httpd.c` — HTTP server (port 8035, localhost, single-threaded)
- `tweaksd/httpd.h` — request/route types, port/buffer constants
- `tweaksd/usb.c` — USB mount scanning, tweaks/dump dir finding
- `tweaksd/usb.h` — mount paths, MAX_PATH, USB_TWEAKS_DIR
- `tweaksd/dump.c` — system dump creation (shell script in /tmp)
- `tweaksd/dump.h` — DUMP_STATE_FILE path
- `tweaksd/log.c` — operation logging, log read, log export
- `tweaksd/log.h` — LOG_FILE path, LOG_MAX_READ
- `tweaksd/jsmn.h` — embedded JSMN parser (header-only)

### Installer
- `installer/tweaks.sh` — pure installer script (5 steps: copy, backup, autostart, userjs, finalize)

### UI
- `jci-app/tweaks-menu.js` — Opera 12 overlay UI (v2, dark cyberpunk theme)

### Patching
- `lib/patch.sh` — safe patching library (begin/sed/append/verify/commit/rollback)

### Tweaks (each has tweak.json + install.sh + uninstall.sh)
- `tweaks/hud-eu-region/`
- `tweaks/no-disclaimer/`
- `tweaks/no-camera-warning/`
- `tweaks/touch-while-moving/`

### USB Preparation
- `prepare-usb.sh` — format USB, copy payloads, create .up injections, verify
