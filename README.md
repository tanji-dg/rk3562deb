# rkdebian — Debian 12 for Doogee U10 (RK3562)

> **Run full Debian 12 Bookworm on your Doogee U10 tablet — no bootloader unlock required.**
> Boot from SD card, remove it to return to stock Android. No changes to internal storage.

> **Reverse engineered from scratch** — no BSP, no vendor documentation, no official support.
> Built with the help of **Claude**, **Codex**, and **Antigravity** (Google Gemini), using **[Firefly RK3562](https://github.com/Firefly-rk-linux)** open-source repositories as a starting point.

---

## Overview

**rkdebian** is a build system that produces a complete, bootable Debian 12 Bookworm image for the **Doogee U10** Android tablet, powered by the **Rockchip RK3562** SoC.

The resulting image is written to an SD card. Insert it and power on — the tablet boots Debian. Remove the SD card and it boots Android from internal eMMC as normal.

---

## Hardware: Doogee U10

| Component | Details |
|-----------|---------|
| SoC | Rockchip RK3562 (4× Cortex-A53 @ 2.0 GHz) |
| RAM | 4 GB LPDDR4 |
| Storage | 128 GB eMMC (Android) + SD card (Debian) |
| Display | 10.1" DSI panel, 1280×800 |
| PMIC | RK817 |

---

## What Works

| Feature | Status |
|---------|--------|
| **Display / Panel** | ✅ Full |
| **Touchscreen** | ✅ Full (gsl3673, 10-point multitouch) |
| **Wi-Fi** | ✅ Full (Seekwave EA6621Q) |
| **Bluetooth** | ✅ Full |
| **Speaker / Audio output** | ✅ Full |
| **Microphone** | ✅ Full |
| **3D Acceleration** | ⚠️ Partial (Panfrost, OpenGL ES works) |
| **Accelerometer** | ✅ Full (SC7A20 / DA223) |
| **Battery / Charging** | ✅ Full (RK817 PMIC) |
| **SD card boot** | ✅ Full |
| **USB OTG** | ✅ Full |

## What Does Not Work

| Feature | Status |
|---------|--------|
| **Cameras** | ❌ Not supported |

---

## Known Issues

- Battery may report `0%` after the tablet has been powered off for a couple of hours.
- `rk-battery-gauge-fix.service` fixes this on boot.
- If the tablet did not fully power off, reboot once; on the next boot the battery level should be corrected.

---

## Requirements

**Host machine:** x86-64 Linux (Debian/Ubuntu recommended)

Install all build dependencies with:

```bash
sudo apt-get install \
  git make gcc-aarch64-linux-gnu \
  bc bison flex device-tree-compiler \
  genimage wget tar mtools \
  debootstrap qemu-user-static \
  e2fsprogs
```

---

## Building

### Full build (recommended)

Builds U-Boot, kernel, Debian rootfs, and produces a ready-to-flash SD card image:

```bash
./build.sh all
```

The final image is written to:
- `out/rk3562-debian.img` — write directly to SD card
- `output/update/update.img` — Firefly-compatible path

---

### Individual build targets

| Command | What it does |
|---------|-------------|
| `./build.sh check` | Verify all build dependencies are installed |
| `./build.sh lunch` | Select a build configuration (defconfig) |
| `./build.sh uboot` | Build U-Boot only |
| `./build.sh extboot` | Build the Linux kernel only |
| `./build.sh rootfs` | Build the Debian 12 rootfs only |
| `./build.sh compile` | Build U-Boot + kernel (skip rootfs and image) |
| `./build.sh image` | Assemble the final SD card image from existing artifacts |
| `./build.sh updateimg` | Alias for `image` |
| `./build.sh updatepkg` | Create an offline update tarball (`output/update/update.tar.gz`) |
| `./build.sh all` | Full end-to-end build (default) |

---

## Environment Variables

These variables can be set before running `build.sh` to control build behaviour:

### Rootfs

| Variable | Default | Description |
|----------|---------|-------------|
| `RKDEBIAN_FORCE_CLEAN_ROOTFS` | `0` | Set to `1` to wipe and fully rebuild the Debian rootfs from scratch. Useful when switching between different image profiles (for example gaming/retro vs desktop) so stale packages do not carry over. |
| `ROOTFS_IMAGE_SIZE` | `auto` | Override the rootfs partition size (e.g. `4G`, `3584M`). By default the size is calculated automatically from actual rootfs usage plus headroom. |
| `ROOTFS_HEADROOM_MB` | `512` | Free space headroom added on top of actual rootfs usage when using `auto` sizing. |
| `ROOTFS_MIN_MB` | `2560` | Minimum rootfs image size in MiB when using `auto` sizing. |
| `RKDEBIAN_DISPLAY_SERVER` | `x11` | Desktop session backend used for Plasma auto-login selection (`x11`, `wayland`, or `auto`). |
| `RKDEBIAN_UI_SESSION` | `plasma` | UI session to auto-login in SDDM: `plasma` or `lomiri`. |
| `RKDEBIAN_GPU_STACK` | `mali` | GPU stack to build for: `mali` (vendor userspace) or `panfrost` (Mesa/Panfrost, no `libmali`). |

### Kernel

| Variable | Default | Description |
|----------|---------|-------------|
| `RKDEBIAN_MAKE_THREADS` | `auto` | Override kernel build parallelism. By default it uses a memory-safe value (`min(nproc, RAM_GiB/2)`) to reduce random `cc1`/`drivers` build failures on low-RAM hosts. |
| `RKDEBIAN_KEEP_OVERLAY_PMIC_PATCHES` | `0` | Set to `1` to use the overlay PMIC drivers (`rk808.c`, `rk817_battery.c`, `rk817_charger.c`) instead of the upstream kernel versions. |

### Examples

```bash
# Force a clean rootfs rebuild
RKDEBIAN_FORCE_CLEAN_ROOTFS=1 ./build.sh all

# Force clean rootfs rebuild with a fixed 4 GB rootfs partition
RKDEBIAN_FORCE_CLEAN_ROOTFS=1 ROOTFS_IMAGE_SIZE=4G ./build.sh all

# Build only the rootfs, force clean
RKDEBIAN_FORCE_CLEAN_ROOTFS=1 ./build.sh rootfs

# Rebuild image only (U-Boot and kernel already built)
./build.sh image

# Build kernel only
./build.sh extboot

# Keep overlay PMIC patches during kernel build
RKDEBIAN_KEEP_OVERLAY_PMIC_PATCHES=1 ./build.sh extboot

# Force a Wayland desktop image for testing
./build.sh all --display-server=wayland

# Build a Lomiri image on Mesa/Panfrost (recommended with clean rootfs)
./build.sh all --ui-session=lomiri --gpu-stack=panfrost --force-clean-rootfs
```

When changing `RKDEBIAN_UI_SESSION` or `RKDEBIAN_GPU_STACK`, use `--force-clean-rootfs` to avoid stale package carry-over.

### Safe Lomiri Session Testing (on-device)

Images include `rk-session-failsafe.timer`, which checks 5 minutes after boot if a risky session test is still armed.

```bash
# Arm rollback before rebooting into a risky session test
sudo install -d /var/lib/rk-session-failsafe
sudo touch /var/lib/rk-session-failsafe/armed
sudo reboot
```

Behavior:
- If Lomiri is healthy, watchdog auto-disarms and does nothing.
- If session bring-up fails, watchdog switches SDDM autologin back to Plasma and reboots.

---

## OTA Updates (on-device)

Once the tablet is running Debian, you can apply updates without reflashing the SD card.

**Build an update package on your host:**

```bash
./build.sh all        # or just ./build.sh image && ./build.sh updatepkg
```

This produces `output/update/update.tar.gz`.

**Copy it to the tablet** (via USB, SSH, or any file manager) and drop it in one of these inbox directories:

| Path | Notes |
|------|-------|
| `/home/chaos/update/` | Primary drop location |
| `/update/pending/` | Alternative drop location |

On the **next reboot**, the `rk-apply-update` service automatically detects the package, applies the rootfs and kernel/DTB payloads, then reboots to finalize. The applied package is moved to `/update/applied/` so the same package is never applied twice.

Update progress and errors are logged to `/var/log/rk-update.log`.

> If a package fails to apply (corrupt archive, wrong layout) it is moved to `/update/failed/` and the system boots normally.

---

## Flashing to SD Card

After a successful build, flash the image to your SD card:

```bash
# Replace /dev/sdX with your SD card device (check with lsblk)
sudo dd if=out/rk3562-debian.img of=/dev/sdX bs=4M status=progress conv=fsync
```

> **Warning:** Double-check the device path. Writing to the wrong device will overwrite your data.

Insert the SD card into the Doogee U10 and power it on. Debian will boot automatically.
Remove the SD card to return to Android.

---

## Image Layout

The SD card image uses a GPT partition table:

| Partition | Offset | Size | Contents |
|-----------|--------|------|----------|
| `idbloader` | 32 KiB | — | SPL / first-stage bootloader |
| `uboot` | 8 MiB | — | U-Boot FIT image |
| `boot` | 16 MiB | 256 MiB | FAT: kernel Image, DTB, extlinux.conf |
| `rootfs` | 272 MiB | auto | ext4: Debian 12 Bookworm root filesystem |

The rootfs partition is automatically expanded to fill the SD card on first boot.

---

## Source Tree

```
rkdebian/
├── build.sh              # Main build entry point
├── build_rootfs.sh       # Debian rootfs builder (debootstrap + chroot)
├── genimage.cfg          # SD card image partition layout
├── extlinux.conf         # Bootloader config (kernel + DTB)
├── overlay/              # Custom kernel drivers, DTS, firmware
│   └── drivers/net/wireless/ea6621q/   # Seekwave Wi-Fi/BT driver
├── src/                  # Cloned sources (kernel, u-boot, rkbin)
├── out/                  # Build artifacts (kernel, rootfs, images)
└── output/update/        # Final flashable image + update package
```

---

## Kernel & Bootloader Versions

| Component | Version / Branch |
|-----------|-----------------|
| Linux kernel | 6.1.x (`develop-6.1`, rockchip-linux) |
| U-Boot | Firefly `rk356x/firefly-5.10` |
| rkbin | Rockchip upstream `master` |
| Debian | 12 Bookworm (arm64) |

---

## License

**© tech4bot — [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)**

This project is licensed under the **Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International** license.

**You are free to:**
- Share — copy and redistribute the material in any medium or format
- Adapt — remix, transform, and build upon the material

**Under the following terms:**
- **Attribution** — You must give appropriate credit to the original author, provide a link to this repository, and indicate if changes were made
- **NonCommercial** — You may not use the material for commercial purposes
- **ShareAlike** — If you remix, transform, or build upon the material, you must distribute your contributions under the same license

The Linux kernel, U-Boot, Debian packages, and third-party drivers included in or produced by this build system retain their respective upstream licenses.
