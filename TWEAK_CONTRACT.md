# Tweak Developer Contract

> How to create a tweak for Tweaks Manager on Mazda CMU v74.

## Directory Structure

A tweak is a folder named by its **id** (lowercase, hyphens allowed):

```
my-tweak/
├── tweak.json      # manifest (required)
├── install.sh      # install script (required)
├── uninstall.sh    # uninstall script (required)
└── files/          # any resources the scripts need (optional)
    └── ...
```

Place the folder under `tweaks-manager/tweaks/<id>/` on the USB drive.

## Manifest: tweak.json

```json
{
  "id": "my-tweak",
  "name": "Human-Readable Name",
  "version": "1.0.0",
  "description": "One-line description of what this tweak does",
  "author": "your-name",
  "min_firmware": "74.00.324",
  "max_firmware": "74.00.324A",
  "requires_reboot": true,
  "regions": ["EU", "NA"],
  "modifies": [
    "/jci/path/to/file-this-tweak-changes"
  ],
  "conflicts_with": ["other-tweak-id"],
  "depends_on": ["required-tweak-id"]
}
```

### Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Unique identifier. `[a-z0-9-]` only. Must match folder name. |
| `name` | string | yes | Display name shown in the UI (max 128 chars). |
| `version` | string | yes | Semver `MAJOR.MINOR.PATCH`. Used for update detection. |
| `description` | string | yes | One-liner for the tweak card (max 256 chars). |
| `author` | string | yes | Credit line. |
| `min_firmware` | string | no | Minimum CMU firmware version (inclusive). |
| `max_firmware` | string | no | Maximum CMU firmware version (inclusive). |
| `requires_reboot` | bool | yes | `true` if changes take effect only after reboot. The manager shows a Reboot button — your script must **never** reboot. |
| `regions` | string[] | no | Region codes: `"EU"`, `"NA"`, `"JP"`, `"ADR"`. Empty = all regions. |
| `modifies` | string[] | yes | Absolute paths of files/dirs this tweak changes. The manager backs them up before install and restores on uninstall. Also used for conflict detection. |
| `conflicts_with` | string[] | no | IDs of tweaks that cannot be installed alongside this one. |
| `depends_on` | string[] | no | IDs of tweaks that must be installed first. |

## Scripts

### Environment

The manager calls your scripts with these env vars:

| Variable | Description |
|----------|-------------|
| `NO_REBOOT` | Always `1`. Your script must **never** call `reboot`. |
| `TWEAK_DIR` | Absolute path to your tweak's folder (where `tweak.json` lives). Use this to reference your `files/` directory: `$TWEAK_DIR/files/...` |
| `TWEAKS_LIB` | Path to shared `patch.sh` library (see below). |

### Rules

1. **No reboot.** The manager decides when to reboot based on `requires_reboot`. Your script must never call `reboot`, `shutdown`, or `init`.

2. **No remount.** The manager handles `mount -o remount,rw /` before calling your script and `mount -o remount,ro /` after. Your script runs on a read-write rootfs.

3. **No UI dialogs.** Never call `jci-dialog`. The manager handles all user interaction.

4. **Exit codes.** Return `0` on success, non-zero on failure. The manager captures stdout/stderr and logs it.

5. **Idempotent.** Running install twice should be safe. Check if already installed and exit 0.

6. **BusyBox ash.** CMU runs BusyBox — no bash. No arrays, no `[[ ]]`, no process substitution. Use `[ ]`, `$(cmd)`, and POSIX constructs only.

7. **Use `$TWEAK_DIR`** to reference your files. Do not hardcode paths or use `$(dirname "$0")`. The fallback pattern for standalone testing is:
   ```sh
   : "${TWEAK_DIR:=$(dirname "$0")}"
   ```

### install.sh

```sh
#!/bin/sh
# My Tweak — Install
#
# Contract: called by tweaksd with env TWEAK_DIR, TWEAKS_LIB, NO_REBOOT=1
# Must not reboot or remount. Exit 0=OK, non-0=error.

: "${TWEAK_DIR:=$(dirname "$0")}"
BACKUP="/data_persist/tweaks/backups/my-tweak"

# Idempotency check
if [ -f "$BACKUP/.installed" ]; then
    echo "Already installed"
    echo "OK"
    exit 0
fi

# Backup originals
mkdir -p "$BACKUP"
cp -a /jci/path/to/original "$BACKUP/"

# Apply changes
cp "$TWEAK_DIR/files/patched-file" /jci/path/to/original

# Mark installed
echo "1" > "$BACKUP/.installed"
echo "OK"
```

### uninstall.sh

```sh
#!/bin/sh
# My Tweak — Uninstall
#
# Contract: called by tweaksd with env TWEAK_DIR, TWEAKS_LIB, NO_REBOOT=1
# Must not reboot or remount. Exit 0=OK, non-0=error.

BACKUP="/data_persist/tweaks/backups/my-tweak"

if [ ! -f "$BACKUP/.installed" ]; then
    echo "Not installed"
    exit 0
fi

# Restore originals
cp "$BACKUP/original" /jci/path/to/original

rm -f "$BACKUP/.installed"
echo "OK"
```

## Shared Library: patch.sh

Available at `$TWEAKS_LIB`. Provides helpers for common patching operations (text replacement in config files, appending blocks with markers). Source it in your script:

```sh
. "$TWEAKS_LIB"
```

## Lifecycle

The user sees this flow in the Tweaks Manager UI:

```
USB inserted ──► AVAILABLE ON USB ──► [SETUP] ──► READY ──► [INSTALL] ──► INSTALLED
                                        │                                    │
                              copies tweak folder                    runs install.sh
                              from USB to CMU                        (rootfs is rw)
                              /data_persist/tweaks/                      │
                              available/<id>/                    if requires_reboot:
                                                                 shows REBOOT / LATER
```

- **SETUP**: Copies the entire tweak folder from USB to `/data_persist/tweaks/available/<id>/`. No scripts are run. USB can be removed after this.
- **INSTALL**: Runs `install.sh` from the local copy. The manager handles rootfs remount, backup of `modifies[]` files, and conflict checks before your script runs.
- **UNINSTALL**: Runs `uninstall.sh`. The manager also calls `tweaks_restore_files()` for anything in `modifies[]`.
- **UPDATE**: Runs `uninstall.sh` (old version), then `install.sh` (new version) when a newer `version` is detected on USB.

## CMU Environment Quick Reference

| Detail | Value |
|--------|-------|
| Architecture | ARM (armv7l) |
| Shell | BusyBox ash |
| Screen | 800×480, 7" |
| Rootfs | Read-only by default, remounted rw by manager |
| Persistent storage | `/data_persist/` (survives reboots) |
| Tweaks data | `/data_persist/tweaks/` |
| Backups | `/data_persist/tweaks/backups/<id>/` |
| Opera browser | Opera 12 Presto (no ES6, no CSS vars, no flexbox) |
| Firmware tested | 74.00.324, 74.00.324A |

## Checklist

Before submitting a tweak, verify:

- [ ] `tweak.json` has all required fields
- [ ] `id` matches folder name, uses only `[a-z0-9-]`
- [ ] `version` is valid semver
- [ ] `modifies` lists every file/dir your scripts touch
- [ ] `requires_reboot` is set correctly
- [ ] `install.sh` and `uninstall.sh` exist and are executable
- [ ] Scripts do not call `reboot`, `shutdown`, or `mount -o remount`
- [ ] Scripts do not call `jci-dialog`
- [ ] Scripts use `$TWEAK_DIR` for file references
- [ ] Scripts are idempotent (safe to run twice)
- [ ] Scripts work with BusyBox ash (no bash-isms)
- [ ] Scripts exit 0 on success, non-zero on failure
