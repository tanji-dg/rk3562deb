# Chromium Hardware Acceleration Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable native Mali GPU compositing and VAAPI hardware video decode in Chromium on the RK3562 tablet.

**Architecture:** Two independent changes to `build_rootfs.sh`: (1) fix the VAAPI driver build by installing missing dependencies (`libva-dev`, `librga.so`), and (2) switch Chromium from SwiftShader to native Mali EGL via `--use-gl=egl`. Both changes live in the same file but touch separate sections.

**Tech Stack:** Bash (build script), Rockchip MPP, librga, libva/VAAPI, Mali G52 EGL (GBM)

**Spec:** `docs/superpowers/specs/2026-03-17-chromium-hw-accel-design.md`

---

### Task 1: Fix the VAAPI Driver Build Script

The current `build_vaapi.sh` heredoc (lines 426-482) fails silently because:
- `libva-dev` is not installed in the chroot (no `va/va.h` header)
- `librga.so` never makes it to the rootfs (the install may succeed but the lib is needed for `rk_hw_base` to link)

The `rk_vaapi_driver` Makefile expects `rk_hw_base` as a sibling directory (`-I../rk_hw_base/include -L../rk_hw_base/lib`), so the current `/tmp/` layout is correct. We just need to fix the missing dependencies.

**Files:**
- Modify: `build_rootfs.sh:426-482`

- [ ] **Step 1: Add build dependency installation to the `build_vaapi.sh` heredoc**

At the top of the heredoc (after `set -e` / `cd /tmp`), add:

```bash
# Install build dependencies for VAAPI driver
apt-get install -y --no-install-recommends libva-dev libdrm-dev pkg-config
```

This provides `va/va.h` and `va/va_drmcommon.h` headers needed by `rk_vaapi_driver`.

Edit `build_rootfs.sh` — replace lines 431-433:

```bash
#!/bin/bash
set -e
cd /tmp
```

with:

```bash
#!/bin/bash
set -e
cd /tmp

# Install build dependencies for VAAPI driver
apt-get install -y --no-install-recommends libva-dev libdrm-dev pkg-config
```

- [ ] **Step 2: Fix the librga install to include SONAME symlink**

The `airockchip/librga` prebuilt `librga.so` may have an embedded SONAME (e.g., `librga.so.2`). Without the matching symlink, `rk_hw_base` will compile but fail at runtime. Add a SONAME check after the copy.

Edit `build_rootfs.sh` — replace lines 438-448:

```bash
    echo "[*] Fetching librga..."
    git clone --depth=1 https://github.com/airockchip/librga /tmp/librga_src
    cp /tmp/librga_src/libs/Linux/gcc-aarch64/librga.so /usr/lib/aarch64-linux-gnu/
    mkdir -p /usr/include/rga
    cp /tmp/librga_src/include/rga.h \
       /tmp/librga_src/include/RgaApi.h \
       /tmp/librga_src/include/RgaUtils.h \
       /tmp/librga_src/include/drmrga.h \
       /tmp/librga_src/include/GrallocOps.h \
       /tmp/librga_src/include/im2d_type.h \
       /usr/include/rga/
    ldconfig
    rm -rf /tmp/librga_src
```

with:

```bash
    echo "[*] Fetching librga..."
    git clone --depth=1 https://github.com/airockchip/librga /tmp/librga_src
    cp /tmp/librga_src/libs/Linux/gcc-aarch64/librga.so /usr/lib/aarch64-linux-gnu/
    # Create SONAME symlink if the binary has one embedded
    SONAME=$(objdump -p /usr/lib/aarch64-linux-gnu/librga.so 2>/dev/null | awk '/SONAME/{print $2}')
    if [ -n "$SONAME" ] && [ "$SONAME" != "librga.so" ]; then
        ln -sf librga.so "/usr/lib/aarch64-linux-gnu/$SONAME"
    fi
    mkdir -p /usr/include/rga
    cp /tmp/librga_src/include/*.h /usr/include/rga/
    ldconfig
    rm -rf /tmp/librga_src
```

Note: Changed the individual header copies to `cp include/*.h` — simpler and picks up any new headers the project adds.

- [ ] **Step 3: Add `rk_hw_base` header installation for system-wide use**

After building `rk_hw_base`, install its headers so they're available system-wide (useful for future rebuilds). This doesn't change the `rk_vaapi_driver` build since it uses the sibling directory, but makes the rootfs more complete.

Edit `build_rootfs.sh` — replace lines 452-462:

```bash
# Build rk_hw_base middleware
if [ ! -f /usr/lib/aarch64-linux-gnu/librk_hw_base.so ]; then
    echo "[*] Building rk_hw_base..."
    git clone --depth=1 https://github.com/sujit-168/rk_hw_base /tmp/rk_hw_base
    cd /tmp/rk_hw_base
    make
    cp lib/librk_hw_base.so /usr/lib/aarch64-linux-gnu/
    ldconfig
    cd /tmp
    rm -rf /tmp/rk_hw_base
fi
```

with:

```bash
# Build rk_hw_base middleware
if [ ! -f /usr/lib/aarch64-linux-gnu/librk_hw_base.so ]; then
    echo "[*] Building rk_hw_base..."
    git clone --depth=1 https://github.com/sujit-168/rk_hw_base /tmp/rk_hw_base
    cd /tmp/rk_hw_base
    make
    cp lib/librk_hw_base.so /usr/lib/aarch64-linux-gnu/
    mkdir -p /usr/include/rk_hw_base
    cp include/*.h /usr/include/rk_hw_base/
    ldconfig
    cd /tmp
fi
```

Note: Removed `rm -rf /tmp/rk_hw_base` — it's still needed as a sibling for the `rk_vaapi_driver` build in the next step.

- [ ] **Step 4: Remove the redundant second `rk_hw_base` clone**

The `rk_vaapi_driver` section clones `rk_hw_base` again because the previous step deleted it. Since we no longer delete it, remove the redundant clone.

Edit `build_rootfs.sh` — replace lines 464-475:

```bash
# Build rockchip VAAPI driver
if [ ! -f /usr/lib/aarch64-linux-gnu/dri/rockchip_drv_video.so ]; then
    echo "[*] Building rockchip_drv_video.so..."
    git clone --depth=1 https://github.com/sujit-168/rk_vaapi_driver /tmp/rk_vaapi_driver
    git clone --depth=1 https://github.com/sujit-168/rk_hw_base /tmp/rk_hw_base
    cd /tmp/rk_vaapi_driver
    make
    mkdir -p /usr/lib/aarch64-linux-gnu/dri
    cp lib/rockchip_drv_video.so /usr/lib/aarch64-linux-gnu/dri/
    ldconfig
    cd /tmp
    rm -rf /tmp/rk_vaapi_driver /tmp/rk_hw_base
fi
```

with:

```bash
# Build rockchip VAAPI driver
if [ ! -f /usr/lib/aarch64-linux-gnu/dri/rockchip_drv_video.so ]; then
    echo "[*] Building rockchip_drv_video.so..."
    git clone --depth=1 https://github.com/sujit-168/rk_vaapi_driver /tmp/rk_vaapi_driver
    cd /tmp/rk_vaapi_driver
    make
    mkdir -p /usr/lib/aarch64-linux-gnu/dri
    cp lib/rockchip_drv_video.so /usr/lib/aarch64-linux-gnu/dri/
    ldconfig
    cd /tmp
    rm -rf /tmp/rk_vaapi_driver /tmp/rk_hw_base
fi
```

- [ ] **Step 5: Add build dependency cleanup at the end of `build_vaapi.sh`**

Before the final echo, remove build-only packages to keep rootfs small. `libva-dev` is headers-only (runtime `libva2` stays); `pkg-config` is build tooling.

Edit `build_rootfs.sh` — replace line 478:

```bash
echo "[+] Rockchip VAAPI driver ready."
```

with:

```bash
# Clean up build-only dependencies
apt-get purge -y --auto-remove libva-dev libdrm-dev pkg-config 2>/dev/null || true

echo "[+] Rockchip VAAPI driver ready."
```

- [ ] **Step 6: Commit**

```bash
git add build_rootfs.sh
git commit -m "Fix VAAPI driver build: add missing libva-dev, fix librga install"
```

---

### Task 2: Update Chromium Flags — SwiftShader to Native Mali EGL

Replace `--use-gl=angle --use-angle=swiftshader` with `--use-gl=egl` in both branches of the Chromium flags section. Update the stale comment block above.

**Files:**
- Modify: `build_rootfs.sh:673-717`

- [ ] **Step 1: Update the comment block (lines 673-687)**

Replace lines 673-687:

```bash
# Add Chromium hardware acceleration flags.
# Mali G52 EGL does not expose EGL_KHR_platform_wayland, so it cannot provide
# an ANGLE context for Chromium's GPU process on Wayland. Instead we use
# Chromium's built-in SwiftShader (software GLES) for GPU compositing —
# Sway/Mali handles the final display so UI remains smooth.
# VAAPI video decode (rockchip_drv_video.so via MPP) runs in a separate
# process and does not depend on the GL backend, giving hardware H.264/HEVC.
# --use-gl=angle --use-angle=swiftshader : Chromium built-in software GLES
# --ignore-gpu-blocklist                 : allow GPU rasterization on Mali
# --enable-gpu-rasterization             : tile rasterization via GLES
# --disable-gpu-sandbox                  : VAAPI driver needs /dev/mpp_service
# --enable-accelerated-video-decode      : opt-in for HW video decode
# VaapiVideoDecoder                      : VAAPI H.264/HEVC decode path
# VaapiIgnoreDriverChecks               : bypass Chromium driver name allowlist
# UseChromeOSDirectVideoDecoder disabled : use standard Linux VAAPI, not CrOS
```

with:

```bash
# Add Chromium hardware acceleration flags.
# Mali G52 EGL exposes EGL_KHR_platform_gbm — Chromium Ozone can use native
# EGL via GBM for GPU compositing (no EGL_KHR_platform_wayland needed).
# --use-gl=egl                           : native Mali EGL (GBM platform)
# --ignore-gpu-blocklist                 : allow GPU rasterization on Mali
# --enable-gpu-rasterization             : tile rasterization via GLES
# --disable-gpu-sandbox                  : VAAPI driver needs /dev/mpp_service
# --enable-accelerated-video-decode      : opt-in for HW video decode
# VaapiVideoDecoder                      : VAAPI H.264/HEVC decode path
# VaapiIgnoreDriverChecks               : bypass Chromium driver name allowlist
# UseChromeOSDirectVideoDecoder disabled : use standard Linux VAAPI, not CrOS
```

- [ ] **Step 2: Update the VAAPI-present branch (lines 691-706)**

Replace lines 691-706:

```bash
    cat > "${ROOTFS_MNT}/etc/chromium.d/rk3562-hw-accel" << 'CHROMIUM_HW_FLAGS'
# RK3562 hardware acceleration — sourced by /usr/bin/chromium wrapper
# SwiftShader provides the GLES context (Mali EGL lacks Wayland platform support).
# VAAPI hardware video decode works independently via rockchip_drv_video.so + MPP.
export LIBVA_DRIVER_NAME=rockchip
export LIBVA_DRIVERS_PATH=/usr/lib/aarch64-linux-gnu/dri
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ozone-platform=wayland"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-gl=angle"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-angle=swiftshader"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ignore-gpu-blocklist"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-gpu-rasterization"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-gpu-sandbox"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-accelerated-video-decode"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,VaapiIgnoreDriverChecks"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-features=UseChromeOSDirectVideoDecoder"
CHROMIUM_HW_FLAGS
```

with:

```bash
    cat > "${ROOTFS_MNT}/etc/chromium.d/rk3562-hw-accel" << 'CHROMIUM_HW_FLAGS'
# RK3562 hardware acceleration — sourced by /usr/bin/chromium wrapper
# Native Mali EGL (GBM platform) for compositing.
# VAAPI hardware video decode via rockchip_drv_video.so + MPP.
export LIBVA_DRIVER_NAME=rockchip
export LIBVA_DRIVERS_PATH=/usr/lib/aarch64-linux-gnu/dri
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ozone-platform=wayland"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-gl=egl"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ignore-gpu-blocklist"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-gpu-rasterization"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-gpu-sandbox"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-accelerated-video-decode"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,VaapiIgnoreDriverChecks"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-features=UseChromeOSDirectVideoDecoder"
# ── FALLBACK: if Mali EGL crashes Chromium, replace --use-gl=egl above with: ──
# CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-gl=angle"
# CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-angle=swiftshader"
CHROMIUM_HW_FLAGS
```

- [ ] **Step 3: Update the VAAPI-absent fallback branch (lines 708-716)**

Replace lines 708-716:

```bash
    # No rockchip VAAPI driver — SwiftShader for compositing, software video decode.
    cat > "${ROOTFS_MNT}/etc/chromium.d/rk3562-hw-accel" << 'CHROMIUM_SW_FLAGS'
# RK3562 SwiftShader only (no VAAPI driver found at build time)
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ozone-platform=wayland"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-gl=angle"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-angle=swiftshader"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ignore-gpu-blocklist"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-gpu-rasterization"
CHROMIUM_SW_FLAGS
```

with:

```bash
    # No rockchip VAAPI driver — native Mali EGL compositing, software video decode.
    cat > "${ROOTFS_MNT}/etc/chromium.d/rk3562-hw-accel" << 'CHROMIUM_SW_FLAGS'
# RK3562 — native Mali EGL compositing, software video decode
# (VAAPI driver not found at build time)
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ozone-platform=wayland"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-gl=egl"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ignore-gpu-blocklist"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-gpu-rasterization"
# ── FALLBACK: if Mali EGL crashes Chromium, replace --use-gl=egl above with: ──
# CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-gl=angle"
# CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-angle=swiftshader"
CHROMIUM_SW_FLAGS
```

- [ ] **Step 4: Commit**

```bash
git add build_rootfs.sh
git commit -m "Switch Chromium from SwiftShader to native Mali EGL compositing"
```

---

### Task 3: Verify on Device

After rebuilding the rootfs and flashing to the tablet, verify everything works via SSH.

- [ ] **Step 1: Verify VAAPI driver exists**

```bash
ssh chaos@192.168.2.109 "ls -la /usr/lib/aarch64-linux-gnu/dri/rockchip_drv_video.so"
```

Expected: file exists with non-zero size.

- [ ] **Step 2: Verify VAAPI works**

```bash
ssh chaos@192.168.2.109 "DISPLAY= WAYLAND_DISPLAY= LIBVA_DRIVER_NAME=rockchip LIBVA_DRIVERS_PATH=/usr/lib/aarch64-linux-gnu/dri vainfo 2>&1"
```

Expected: shows rockchip driver with H.264/H.265 decode/encode profiles.

- [ ] **Step 3: Verify Chromium flags are correct**

```bash
ssh chaos@192.168.2.109 "cat /etc/chromium.d/rk3562-hw-accel"
```

Expected: shows `--use-gl=egl` (NOT `--use-angle=swiftshader`), VAAPI env vars, and VAAPI feature flags.

- [ ] **Step 4: Verify Chromium GPU status**

On the tablet, open Chromium and navigate to `chrome://gpu`. Check:
- GL renderer should show "Mali-G52" (not SwiftShader)
- "Rasterization" should show "Hardware accelerated"
- "Video Decode" should show "Hardware accelerated"

- [ ] **Step 5: Test YouTube 1080p playback**

On the tablet, open YouTube in Chromium, play a video at 1080p. Check:
- Playback should be smooth (no stuttering)
- In `chrome://media-internals`, look for `kVideoDecoderName: VaapiVideoDecoder`
- CPU usage via `top` should be significantly lower than before

- [ ] **Step 6: Test WebGL**

On the tablet, navigate to `chrome://gpu` and verify WebGL 2.0 is available.
