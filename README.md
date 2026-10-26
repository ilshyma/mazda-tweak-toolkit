# Mazda Tweak Toolkit

Native tweak manager for Mazda CMU v74 (74.00.324 / 324A).  
Install, update and manage tweaks from the head unit's system menu — no laptop required after initial setup.

## Architecture

```
Opera/Presto GUI ──XHR──► tweaksd (C, ARM, :8035) ──sh──► tweak scripts
```

Three layers:
- **GUI** — JCI app injected via VDT proxy, `List2Tmplt` / `Dialog3Tmplt`
- **tweaksd** — HTTP daemon on localhost:8035, manages state in `/data_persist/tweaks/`
- **Tweak scripts** — `install.sh` / `uninstall.sh` per tweak, auto-discovered from USB

## Features

- Auto-discovery of new tweaks from USB (`tweaks-manager/tweaks/`)
- Semver versioning with update detection
- Mandatory system dump before first install (saved to USB)
- Per-tweak file backup with USB export
- Operation logging with USB export
- Conflict detection (declared + file-level)
- NA + EU firmware support

## Initial install

USB stick with `.up` injection payload (CVE-2024-8359). Run `installer/toolkit.sh /Volumes/USB` to prepare the stick.

## Adding a tweak

Create a folder in `tweaks-manager/tweaks/` on USB:

```
my-tweak/
├── tweak.json      # id, name, version, modifies[], regions[]
├── install.sh      # runs on CMU
└── uninstall.sh    # runs on CMU (fallback: restore from backup)
```

Insert USB → open Tweaks in system menu → tweak appears automatically.

## Building

```sh
cd tweaksd && make
# requires: zig (for cross-compilation to arm-linux-gnueabi)
```

## License

MIT License — see [LICENSE](LICENSE).
