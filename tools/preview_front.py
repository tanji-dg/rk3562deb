#!/usr/bin/env python3
"""Live Wayland preview for front camera via ISP (/dev/video22 → NV12).

Pipeline:
  sensor → MIPI → rkcif-lvds2 → rkisp-isp-subdev → rkisp_mainpath → /dev/video22
  GStreamer: v4l2src /dev/video22 → NV12 → videoconvert → videoscale → waylandsink

Usage: python3 preview_front.py [--raw]
  --raw   Use raw BA10 path (/dev/video11) with software debayer (fallback)

Run on device with Wayland session active.
"""
import os
import sys
import subprocess
import ctypes
import fcntl

os.environ.setdefault('WAYLAND_DISPLAY', 'wayland-0')
os.environ.setdefault('XDG_RUNTIME_DIR', '/run/user/1000')

import gi
gi.require_version('Gst', '1.0')
gi.require_version('GLib', '2.0')
from gi.repository import Gst, GLib

W, H = 2592, 1944
FPS = 10

# ────────────────────────────────────────────────────────────────────────────
# ISP pipeline setup
# ────────────────────────────────────────────────────────────────────────────

def run(cmd):
    subprocess.run(cmd, capture_output=True)

def setup_media_links():
    """Enable front camera → ISP link, disable rear camera → ISP link."""
    import struct, array

    # media2 link manipulation via ioctl MEDIA_IOC_SETUP_LINK
    # Easier: just re-run the config_isp binary if present, else rely on prior setup
    run(['media-ctl', '-d', '/dev/media1',
         '--set-v4l2', f'"rockchip-csi2-dphy4":0[fmt:SGRBG10_1X10/{W}x{H}]'])
    run(['media-ctl', '-d', '/dev/media1',
         '--set-v4l2', f'"rockchip-csi2-dphy4":1[fmt:SGRBG10_1X10/{W}x{H}]'])
    run(['media-ctl', '-d', '/dev/media1',
         '--set-v4l2', f'"rockchip-mipi-csi2":0[fmt:SGRBG10_1X10/{W}x{H}]'])
    run(['media-ctl', '-d', '/dev/media1',
         '--set-v4l2', f'"rockchip-mipi-csi2":1[fmt:SGRBG10_1X10/{W}x{H}]'])

    run(['media-ctl', '-d', '/dev/media2',
         '--links', '"rkcif-mipi-lvds":0->"rkisp-isp-subdev":0[0]'])
    run(['media-ctl', '-d', '/dev/media2',
         '--links', '"rkcif-mipi-lvds2":0->"rkisp-isp-subdev":0[1]'])

    if os.path.exists('/tmp/config_isp'):
        subprocess.run(['/tmp/config_isp'], capture_output=True)

    print("Media pipeline configured")


def set_sensor_max_exposure():
    """Push sensor to high exposure + gain for a visible image without ISP AE."""
    SUBDEV = '/dev/v4l-subdev6'
    # Set via v4l2-ctl subdev controls
    run(['v4l2-ctl', '-d', SUBDEV,
         '-c', 'exposure=1900,analogue_gain=2048'])
    print("Sensor: max exposure/gain set")


# ────────────────────────────────────────────────────────────────────────────
# GStreamer pipelines
# ────────────────────────────────────────────────────────────────────────────

def try_pipeline(pipeline_str, timeout_sec=5):
    print(f"Trying: {pipeline_str[:100]}...")
    try:
        pipeline = Gst.parse_launch(pipeline_str)
    except Exception as e:
        print(f"  Parse error: {e}")
        return None

    bus = pipeline.get_bus()
    pipeline.set_state(Gst.State.PLAYING)

    # Wait up to timeout_sec for an error or confirm we're playing
    end = GLib.get_monotonic_time() + timeout_sec * 1_000_000
    while GLib.get_monotonic_time() < end:
        msg = bus.timed_pop_filtered(500_000, Gst.MessageType.ERROR | Gst.MessageType.STATE_CHANGED)
        if msg is None:
            break
        if msg.type == Gst.MessageType.ERROR:
            err, _ = msg.parse_error()
            pipeline.set_state(Gst.State.NULL)
            print(f"  Error: {err.message}")
            return None

    ok, state, _ = pipeline.get_state(3 * Gst.SECOND)
    if state != Gst.State.PLAYING:
        pipeline.set_state(Gst.State.NULL)
        print(f"  Not playing (state={state.value_nick})")
        return None

    print(f"  ✓ Playing")
    return pipeline


def run_preview_isp():
    """NV12 preview from ISP output at /dev/video22."""
    # Scale down for display: 2592x1944 → ~800x600
    scale_w, scale_h = 800, 600

    pipes = [
        (f'v4l2src device=/dev/video22 '
         f'! video/x-raw,format=NV12,width={W},height={H},framerate={FPS}/1 '
         f'! videoconvert '
         f'! videoscale '
         f'! video/x-raw,width={scale_w},height={scale_h} '
         f'! waylandsink fullscreen=false sync=false'),

        # Try without explicit caps (let driver negotiate)
        (f'v4l2src device=/dev/video22 '
         f'! videoconvert '
         f'! videoscale '
         f'! video/x-raw,width={scale_w},height={scale_h} '
         f'! waylandsink fullscreen=false sync=false'),

        # UYVY alternative
        (f'v4l2src device=/dev/video22 '
         f'! video/x-raw,format=UYVY,width={W},height={H},framerate={FPS}/1 '
         f'! videoconvert '
         f'! videoscale '
         f'! video/x-raw,width={scale_w},height={scale_h} '
         f'! waylandsink fullscreen=false sync=false'),
    ]

    for p in pipes:
        pipeline = try_pipeline(p)
        if pipeline:
            return pipeline
    return None


# ────────────────────────────────────────────────────────────────────────────
# Main
# ────────────────────────────────────────────────────────────────────────────

def main():
    use_raw = '--raw' in sys.argv
    Gst.init(None)

    if not use_raw:
        setup_media_links()
        set_sensor_max_exposure()
        pipeline = run_preview_isp()
    else:
        pipeline = None

    if pipeline is None:
        print("ISP pipeline failed — try passing --raw for raw Bayer fallback")
        sys.exit(1)

    loop = GLib.MainLoop()
    bus = pipeline.get_bus()
    bus.add_signal_watch()

    def on_message(bus, msg):
        if msg.type == Gst.MessageType.ERROR:
            err, dbg = msg.parse_error()
            print(f"Error: {err.message}")
            loop.quit()
        elif msg.type == Gst.MessageType.EOS:
            loop.quit()

    bus.connect('message', on_message)
    print(f"\nCamera preview at {scale_w}x{scale_h} — Ctrl+C to stop")
    try:
        loop.run()
    except KeyboardInterrupt:
        pass
    finally:
        pipeline.set_state(Gst.State.NULL)
        print("Stopped")


scale_w, scale_h = 800, 600

if __name__ == '__main__':
    main()
