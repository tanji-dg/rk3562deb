# Design: Pre-Publication Cleanup for rkdebian

**Date:** 2026-04-12  
**Status:** Approved

## Goal

Make the rkdebian repository safe and polished to publish publicly on GitHub, with correct attribution, a permissive license, and no stale/unwanted artifacts.

---

## 1. License Change

Replace `LICENSE` (CC BY-NC-SA 4.0) with **MIT**.

- CC BY-NC-SA is too restrictive for community engagement and professional attention (NonCommercial blocks FAANG engineers from forking/contributing freely).
- MIT is the most permissive and widely recognized option; signals openness.
- The existing downstream notice in README ("Linux kernel, U-Boot, Debian packages, and third-party drivers retain their respective upstream licenses") is correct and stays unchanged.

Update `README.md` license section to reflect MIT.

---

## 2. README Changes

### 2a. New `## Attribution` section

Credit all third-party binary components included in the repo:

- **Mali GPU binaries** (`debs/*.deb`, `mali/libmali-bifrost-g52-g13p0-gbm.so`):
  - [christianhaitian/rk3566_core_builds](https://github.com/christianhaitian/rk3566_core_builds/tree/master/mali/aarch64)
  - [tsukumijima/libmali-rockchip](https://github.com/tsukumijima/libmali-rockchip/releases)
- **Seekwave Wi-Fi firmware** (`overlay/firmware/*.bin`, `wifi/*.bin`):
  - Seekwave Technology Co. Ltd — provided by vendor; driver open-sourced
- **Seekwave Wi-Fi/BT driver source** (`overlay/drivers/net/wireless/ea6621q/`):
  - Seekwave Technology Co. Ltd — open-source driver provided by vendor

### 2b. New `## Default Credentials` section

Document the build system defaults so users know what to log in with and that they must change them:

- User: `chaos`, password: `chaos` (passwordless sudo)
- Root password: `root`
- Note: change both passwords on first boot (`passwd` / `sudo passwd root`)

### 2c. Minor fixes

- **Benchmark section (line 100):** Replace `chaos@192.168.2.109` with `<tablet-ip>` — local IP has no place in public docs.
- **Source Tree section:** Expand to include `debs/`, `mali/`, `wifi/`, and `tools/` directories with one-line descriptions.
- **`RKDEBIAN_FORCE_CLEAN_ROOTFS` description (line 229):** Remove "gaming/retro" example; replace with generic "for example switching between different image profiles".

---

## 3. Untracked File Cleanup

### Delete (never committed, no history impact)

| Path | Reason |
|------|--------|
| `genimage-gaming.cfg` | Failed gaming image layout experiment |
| `darkos-updates2/` | Unrelated ArkOS update project |
| `"'rkisp-isp-subdev'":0` | Debug artifact with malformed name |
| `",i+1, round(mad,3))\nPY\n"` | Debug artifact with malformed name |
| `.codex` | Empty scratch file |
| `docs/camera-bringup-handoff-2026-04-03.md` | Stale session notes (cameras now work) |
| `docs/superpowers/plans/2026-04-04-front-camera-bringup.md` | Stale implementation plan |

### Commit

| Path | Reason |
|------|--------|
| `tools/capture_rear.c` | Legitimate rear camera capture tool; mirrors tracked `tools/capture_front.c` |

---

## 4. `.gitignore` Changes

### Remove

- `mali/` — the `.so` IS tracked; this rule is contradictory. Remove to avoid confusion.

### Add

```
# Gaming experiment artifacts
genimage-gaming.cfg

# Compiled camera tool binaries
tools/capture_rear

# Stale session/handoff docs
docs/camera-bringup-handoff-*.md
docs/superpowers/plans/

# Local IDE and tool config
.vscode/
.codex

# Debug artifacts with malformed names
"'rkisp-isp-subdev'":*
",i+1*"

# Unrelated sibling projects
darkos-updates2/
```

---

## What Does NOT Change

- All binary blobs stay in git (`debs/`, `mali/`, `overlay/firmware/`, `wifi/`) — vendor-provided or sourced from public GitHub repos; attribution covers the licensing angle.
- `build_rootfs.sh` gaming cleanup guards (purging retro packages, removing emulationstation services) — these are defensive cleanup code, not gaming features. No change needed.
- `wifi/new/*.pdf` — no confidentiality markings found; standard vendor integration guides. Keep.

---

## Out of Scope

- `build_rootfs.sh` internals beyond the minor README description fix
- Any kernel, DTS, or overlay changes
- Git history rewriting (no secrets were in history)
