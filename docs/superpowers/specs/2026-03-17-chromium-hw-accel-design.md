# Chromium Hardware Acceleration for RK3562

**Date:** 2026-03-17
**Status:** Approved

## Problem

Chromium on the RK3562 tablet (Debian Bookworm, Sway/Wayland, kernel 5.1) runs entirely in software mode. YouTube 1080p playback stutters badly because:

1. **GPU compositing uses SwiftShader (CPU)** — the build script chose SwiftShader because Mali G52's EGL blob lacks `EGL_KHR_platform_wayland`. All rendering, compositing, and rasterization goes through the CPU.
2. **VAAPI hardware video decode is non-functional** — the community `rockchip_drv_video.so` driver failed to build, so the build script fell back to SW-only Chromium flags.
3. **No V4L2 decode path configured** — Chromium 146 supports V4L2 stateless video decode (talks directly to kernel rkvdec/hantro drivers), but this feature was never enabled.

## Solution: Native Mali EGL + V4L2 Stateless Decode

### Key Insight

Mali G52's EGL blob (`libmali-bifrost-g52-g13p0-gbm.so`) exposes `EGL_KHR_platform_gbm`. Chromium's Ozone Wayland backend can use native EGL via GBM — it does NOT require `EGL_KHR_platform_wayland`. The SwiftShader workaround was unnecessary.

For video decode, V4L2 stateless decode uses the kernel's rkvdec/hantro drivers directly via `/dev/video*` M2M interfaces. No userspace VAAPI driver needed.

### Change 1: Chromium Flags Rewrite

Replace `/etc/chromium.d/rk3562-hw-accel` contents.

**Remove:**
- `--use-gl=angle` / `--use-angle=swiftshader` (SwiftShader compositing)
- `LIBVA_DRIVER_NAME` / `LIBVA_DRIVERS_PATH` env vars
- `--enable-accelerated-video-decode`
- `--enable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,VaapiIgnoreDriverChecks`

**New flags:**
```bash
# GPU compositing — native Mali EGL via GBM platform
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ozone-platform=wayland"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-gl=egl"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ignore-gpu-blocklist"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-gpu-rasterization"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-gpu-sandbox"

# Video decode — V4L2 stateless (kernel rkvdec/hantro, no VAAPI driver needed)
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-features=V4L2StatelessVideoDecoder,Vulkan"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-features=UseChromeOSDirectVideoDecoder"
```

**Rationale for each flag:**
- `--use-gl=egl`: Use native EGL (Mali G52 via GBM) instead of ANGLE/SwiftShader
- `--ignore-gpu-blocklist`: Mali G52 is not on Chromium's allowlist
- `--enable-gpu-rasterization`: Tile rasterization via Mali GLES
- `--disable-gpu-sandbox`: V4L2 decode needs access to `/dev/video*` and `/dev/mpp_service`
- `V4L2StatelessVideoDecoder`: Kernel-native H.264/HEVC decode via rkvdec/hantro
- `Vulkan`: Mali G52 supports Vulkan 1.1; enables Vulkan compositing path
- `--disable-features=UseChromeOSDirectVideoDecoder`: Use standard Linux V4L2, not ChromeOS path

### Change 2: Build Script Logic Simplification

Currently `build_rootfs.sh` lines 688-717 branch on whether the VAAPI driver built:
- VAAPI present → VAAPI flags + SwiftShader
- VAAPI absent → SwiftShader only

**New logic:** Single unconditional block. V4L2 stateless decode depends on kernel interfaces (`/dev/video*`, `/dev/mpp_service`) that are always present — no build-time conditional needed.

The VAAPI driver build section (lines 426-482) remains unchanged — Firefox still uses it.

### Change 3: Udev Rules for V4L2 Codec Devices

Add rules so Chromium's unprivileged GPU process can access V4L2 M2M codec devices:

```bash
KERNEL=="video[0-9]*", SUBSYSTEM=="video4linux", ATTR{name}=="rkvdec*", GROUP="video", MODE="0666"
KERNEL=="video[0-9]*", SUBSYSTEM=="video4linux", ATTR{name}=="hantro*", GROUP="video", MODE="0666"
```

Rules match by driver name to avoid opening camera devices.

Added to the existing udev rules section alongside the `99-mali.rules` block.

### Change 4: Manual SW Fallback (No Auto-Fallback)

The generated config file includes a commented-out SwiftShader fallback block with instructions for manual activation. No automatic fallback — if Mali EGL fails, we want to know and fix it rather than silently degrade.

## Files Modified

- `build_rootfs.sh`: Lines 688-717 (Chromium flags section), udev rules section (~line 336)

## Testing

1. Rebuild rootfs and flash to tablet
2. Launch Chromium, check `chrome://gpu`:
   - "Graphics Feature Status" should show "Hardware accelerated" for Rasterization, Compositing, Video Decode
   - GL renderer should show Mali G52, not SwiftShader
3. Play YouTube 1080p video — should be smooth
4. Check `chrome://media-internals` during playback to confirm V4L2 decoder is active
5. Monitor CPU usage during 1080p playback (should be significantly lower than before)

## Risks

- **Mali GBM EGL + Chromium Ozone:** If Chromium's GPU process crashes on init, the browser won't start. Mitigation: commented-out SW fallback in config.
- **V4L2 stateless decode codec coverage:** rkvdec handles H.264/HEVC but not VP9/AV1. YouTube may serve VP9 by default. Mitigation: YouTube falls back to H.264 when VP9 HW decode is unavailable; can also force H.264 via `--disable-features=Vp9Decoder` if needed.
- **Vulkan on Mali G52:** If the blob's Vulkan ICD is missing or broken, the `Vulkan` feature flag is harmless (Chromium falls back to GLES).
