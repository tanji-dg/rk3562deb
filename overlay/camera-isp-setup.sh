#!/bin/bash
# camera-isp-setup.sh — configure front camera through RKISP on RK3562 tablet.
#
# Route: s5k5e8 sensor → DPHY4 → MIPI-CSI2 → rkcif-mipi-lvds2 → rkisp-isp-subdev
#        → rkisp_selfpath → /dev/video23
#
# After this script:
# - front link (lvds2) is selected on rkisp input
# - ISP sink/source pads are pinned to 2592x1944
# - optional manual sensor controls are applied (helps when no rkaiq/3A daemon)
#
# Called once at boot by camera-isp-setup.service.

set -euo pipefail

log() { echo "[camera-isp-setup] $*"; }

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR: missing required command: $cmd"
        exit 1
    fi
}

require_cmd media-ctl

find_isp_media() {
    local dev
    for dev in /dev/media0 /dev/media1 /dev/media2; do
        [ -e "$dev" ] || continue
        if media-ctl -d "$dev" -p 2>/dev/null | grep -q 'rkisp-isp-subdev'; then
            echo "$dev"
            return 0
        fi
    done
    return 1
}

MEDIA_DEV=""
for _ in $(seq 1 30); do
    MEDIA_DEV="$(find_isp_media || true)"
    [ -n "${MEDIA_DEV}" ] && break
    sleep 1
done

if [ -z "${MEDIA_DEV}" ]; then
    log "ERROR: no rkisp media controller found after waiting"
    exit 1
fi
log "ISP media controller: ${MEDIA_DEV}"

set_link() {
    local spec="$1"
    if ! media-ctl -d "${MEDIA_DEV}" --links "${spec}" >/dev/null 2>&1; then
        log "ERROR: failed to apply media link: ${spec}"
        return 1
    fi
    log "link ok: ${spec}"
}

set_pad() {
    local spec="$1"
    if ! media-ctl -d "${MEDIA_DEV}" --set-v4l2 "${spec}" >/dev/null 2>&1; then
        log "ERROR: failed to apply pad format/crop: ${spec}"
        return 1
    fi
    log "pad ok: ${spec}"
}

# 1) Select front camera link into ISP.
set_link '"rkcif-mipi-lvds":0->"rkisp-isp-subdev":0[0]'
set_link '"rkcif-mipi-lvds2":0->"rkisp-isp-subdev":0[1]'

# 2) Pin front-camera dimensions/formats on input and ISP output.
set_pad '"rkcif-mipi-lvds2":0[fmt:SGRBG10_1X10/2592x1944]'
set_pad '"rkisp-isp-subdev":0[fmt:SGRBG10_1X10/2592x1944 crop:(0,0)/2592x1944]'
set_pad '"rkisp-isp-subdev":2[fmt:YUYV8_2X8/2592x1944 crop:(0,0)/2592x1944]'

if ! media-ctl -d "${MEDIA_DEV}" -p 2>/dev/null | \
    grep -q '<- "rkcif-mipi-lvds2":0 \[ENABLED\]'; then
    log "ERROR: front link was not enabled after setup"
    exit 1
fi
log "front link verified: rkcif-mipi-lvds2 -> rkisp-isp-subdev"

# 3) Force ISP sink/source via ioctl helper (handles stale crop state on some boots).
ISP_SUBDEV="$(media-ctl -d "${MEDIA_DEV}" -p 2>/dev/null \
    | grep -A1 'rkisp-isp-subdev' \
    | grep 'device node name' \
    | awk '{print $NF}')"

if [ -z "${ISP_SUBDEV}" ]; then
    ISP_SUBDEV="/dev/v4l-subdev7"
    log "WARNING: fallback ISP subdev path: ${ISP_SUBDEV}"
else
    log "ISP subdev: ${ISP_SUBDEV}"
fi

if [ -x /usr/local/bin/config_isp ]; then
    /usr/local/bin/config_isp "${ISP_SUBDEV}" 2>&1 | while read -r line; do
        log "$line"
    done
else
    log "WARNING: /usr/local/bin/config_isp not found — skipping ioctl crop reset"
fi

# 4) Apply manual front-sensor controls unless disabled.
# This keeps the image visible on images where no rkaiq/3A daemon is running.
if command -v v4l2-ctl >/dev/null 2>&1; then
    SENSOR_SUBDEV="${FRONT_SENSOR_SUBDEV:-/dev/v4l-subdev6}"
    if [ "${FRONT_FORCE_MANUAL:-1}" = "1" ] && [ -e "${SENSOR_SUBDEV}" ]; then
        FRONT_EXPOSURE="${FRONT_EXPOSURE:-1964}"
        FRONT_ANALOG_GAIN="${FRONT_ANALOG_GAIN:-1024}"
        v4l2-ctl -d "${SENSOR_SUBDEV}" -c test_pattern=0 >/dev/null 2>&1 || true
        v4l2-ctl -d "${SENSOR_SUBDEV}" -c exposure="${FRONT_EXPOSURE}" >/dev/null 2>&1 || true
        v4l2-ctl -d "${SENSOR_SUBDEV}" -c analogue_gain="${FRONT_ANALOG_GAIN}" >/dev/null 2>&1 || true
        log "manual sensor controls applied (exposure=${FRONT_EXPOSURE}, gain=${FRONT_ANALOG_GAIN})"
    else
        log "manual sensor controls skipped (FRONT_FORCE_MANUAL=${FRONT_FORCE_MANUAL:-1})"
    fi
fi

log "Front camera ISP pipeline ready. Use /dev/video23 for preview/webcam"
