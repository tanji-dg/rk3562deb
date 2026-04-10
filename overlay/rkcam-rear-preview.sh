#!/bin/bash
set -euo pipefail

REAR_SETUP="${REAR_SETUP:-/usr/local/bin/setup_isp_rear.sh}"
FRONT_SETUP="${FRONT_SETUP:-/usr/local/bin/camera-isp-setup.sh}"
DEVICE="${REAR_PREVIEW_DEVICE:-/dev/video22}"
W="${REAR_PREVIEW_W:-1920}"
H="${REAR_PREVIEW_H:-1080}"
RESTORE_FRONT="${REAR_PREVIEW_RESTORE_FRONT:-1}"
LOG_FILE="${REAR_PREVIEW_LOG:-/tmp/rkcam-rear-preview.log}"
CHECK_ONLY=0

if [ "${1:-}" = "--check" ]; then
    CHECK_ONLY=1
fi

exec >>"${LOG_FILE}" 2>&1
echo "=== $(date -Iseconds) rear preview start (pid=$$) ==="
echo "env: XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-} DISPLAY=${DISPLAY:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"

if command -v flock >/dev/null 2>&1; then
    exec 9>/tmp/rkcam-rear-preview.lock
    if ! flock -n 9; then
        command -v notify-send >/dev/null 2>&1 && notify-send "Rear Camera Preview" "Another preview instance is already running" || true
        echo "another instance is already running"
        exit 1
    fi
fi

log() {
    echo "[rkcam-rear-preview] $*"
}

notify_user() {
    local title="$1"
    local body="$2"
    command -v notify-send >/dev/null 2>&1 && notify-send "$title" "$body" || true
}

restore_front_pipeline() {
    [ "${RESTORE_FRONT}" = "1" ] || return 0
    [ -x "${FRONT_SETUP}" ] || return 0

    log "Restoring front camera pipeline..."
    if ! bash "${FRONT_SETUP}" >/tmp/rkcam-front-restore.log 2>&1; then
        log "WARN: front restore failed (see /tmp/rkcam-front-restore.log)"
        notify_user "Rear Camera Preview" "Front restore failed. See /tmp/rkcam-front-restore.log"
        return 1
    fi
    notify_user "Rear Camera Preview" "Front camera restored"
    return 0
}

on_exit() {
    local rc=$?
    if [ "${CHECK_ONLY}" = "0" ]; then
        restore_front_pipeline || true
    fi
    echo "=== $(date -Iseconds) rear preview end rc=${rc} ==="
}
trap on_exit EXIT

if [ ! -x "${REAR_SETUP}" ]; then
    log "ERROR: missing rear setup script: ${REAR_SETUP}"
    notify_user "Rear Camera Preview" "Rear setup script missing: ${REAR_SETUP}"
    exit 1
fi

log "Switching ISP route to rear camera..."
if ! bash "${REAR_SETUP}" >/tmp/rkcam-rear-setup.log 2>&1; then
    log "ERROR: rear setup failed (see /tmp/rkcam-rear-setup.log)"
    notify_user "Rear Camera Preview" "Rear setup failed. See /tmp/rkcam-rear-setup.log"
    exit 1
fi

if [ "${CHECK_ONLY}" = "1" ]; then
    log "Rear camera route configured successfully."
    exit 0
fi

if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    log "ERROR: no GUI display detected. Run from desktop app launcher."
    notify_user "Rear Camera Preview" "No GUI display detected"
    exit 1
fi

if ! command -v gst-launch-1.0 >/dev/null 2>&1; then
    log "ERROR: gst-launch-1.0 is required"
    notify_user "Rear Camera Preview" "GStreamer missing"
    exit 1
fi

run_gst() {
    local sink="$1"
    log "backend=gstreamer sink=${sink}"
    gst-launch-1.0 --no-fault -q \
      v4l2src device="${DEVICE}" io-mode=0 do-timestamp=true ! \
      video/x-raw,format=NV12,width=${W},height=${H},framerate=30/1 ! \
      queue max-size-buffers=4 leaky=downstream ! \
      videoconvert ! "${sink}" sync=false
}

log "Opening rear camera preview from ${DEVICE} (${W}x${H})"
notify_user "Rear Camera Preview" "Rear preview started"

if [ -n "${WAYLAND_DISPLAY:-}" ] && gst-inspect-1.0 waylandsink >/dev/null 2>&1; then
    run_gst waylandsink
elif [ -n "${DISPLAY:-}" ] && gst-inspect-1.0 ximagesink >/dev/null 2>&1; then
    run_gst ximagesink
else
    run_gst autovideosink
fi

log "Preview closed."
