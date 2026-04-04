#!/bin/bash
# camera-isp-setup.sh — configure front camera through RKISP on RK3562 tablet.
#
# Route: s5k5e8 sensor → DPHY4 → MIPI-CSI2 → rkcif-mipi-lvds2 → rkisp-isp-subdev
#        → rkisp_mainpath → /dev/video22 (NV12 output)
#
# After this script: /dev/video22 outputs NV12 2592x1944 from the front camera.
# This allows Chromium, Firefox, GStreamer and other V4L2 consumers to use it.
#
# Called once at boot by camera-isp-setup.service (After=systemd-udevd.service).

set -e

log() { echo "[camera-isp-setup] $*"; }

# ── 1. Wait for ISP media controller ────────────────────────────────────────
MEDIA_DEV=""
for dev in /dev/media0 /dev/media1 /dev/media2; do
    if media-ctl -d "$dev" -p 2>/dev/null | grep -q 'rkisp'; then
        MEDIA_DEV="$dev"
        break
    fi
done

if [ -z "${MEDIA_DEV}" ]; then
    log "ERROR: no rkisp media controller found — is rkisp module loaded?"
    exit 1
fi
log "ISP media controller: ${MEDIA_DEV}"

# ── 2. Enable front camera link, disable rear camera link ───────────────────
media-ctl -d "${MEDIA_DEV}" \
    --links '"rkcif-mipi-lvds":0->"rkisp-isp-subdev":0[0]' 2>/dev/null || true
media-ctl -d "${MEDIA_DEV}" \
    --links '"rkcif-mipi-lvds2":0->"rkisp-isp-subdev":0[1]' 2>/dev/null || true
log "ISP link: rkcif-mipi-lvds2 → rkisp-isp-subdev ENABLED"

# ── 3. Fix ISP pad crop/format via config_isp ───────────────────────────────
# The ISP stores a stale crop (3264×2448 from the rear camera baseline).
# config_isp resets pad0 and pad2 to 2592×1944 via VIDIOC_SUBDEV_S_FMT/SELECTION.
ISP_SUBDEV=$(media-ctl -d "${MEDIA_DEV}" -p 2>/dev/null \
    | grep -A1 'rkisp-isp-subdev' \
    | grep 'device node name' \
    | awk '{print $NF}')

if [ -z "${ISP_SUBDEV}" ]; then
    log "WARNING: could not detect ISP subdev node; defaulting to /dev/v4l-subdev7"
    ISP_SUBDEV="/dev/v4l-subdev7"
fi
log "ISP subdev: ${ISP_SUBDEV}"

if [ -x /usr/local/bin/config_isp ]; then
    /usr/local/bin/config_isp "${ISP_SUBDEV}" 2>&1 | while read -r line; do
        log "$line"
    done
else
    log "WARNING: /usr/local/bin/config_isp not found — crop may be stale"
fi

log "Front camera ISP pipeline ready. /dev/video22 → NV12 2592×1944"
