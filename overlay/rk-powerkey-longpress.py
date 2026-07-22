#!/usr/bin/env python3
"""Hardware power-key handler for Phosh on RK3562.

Single handler for the rk805 power key (replaces the separate
rk-power-backlight.service, which is disabled):

  short press  -> toggle the LCD backlight (screen off / on)
  long press   -> on-screen power menu (Suspend / Power Off / Restart)

The DSI panel's compositor-level DPMS is non-functional on this Rockchip
BSP, so the screen is driven directly via the backlight:
  bl_power 0 = FB_BLANK_UNBLANK   (on)
  bl_power 4 = FB_BLANK_POWERDOWN (off)

Suspend/poweroff/reboot are performed by this root daemon via systemctl,
so they are not blocked by polkit (logind CanSuspend == "challenge").
"""

import os
import pwd
import subprocess
import sys
import time

from evdev import InputDevice, ecodes, list_devices


LONG_PRESS_SECONDS = float(os.environ.get("RK_POWERKEY_LONGPRESS_SECONDS", "3.0"))
TARGET_USER = os.environ.get("RK_POWERKEY_USER", "chaos")
SCAN_INTERVAL_SECONDS = 2.0
TRIGGER_COOLDOWN_SECONDS = 2.0
MIN_PRESS_SECONDS = float(os.environ.get("RK_POWERKEY_MIN_PRESS_SECONDS", "0.12"))
POST_RESUME_IGNORE_SECONDS = float(
    os.environ.get("RK_POWERKEY_POST_RESUME_IGNORE_SECONDS", "4.0")
)
RESUME_DETECT_GAP_SECONDS = float(
    os.environ.get("RK_POWERKEY_RESUME_DETECT_GAP_SECONDS", "1.0")
)
RELEASE_SETTLE_SECONDS = float(
    os.environ.get("RK_POWERKEY_RELEASE_SETTLE_SECONDS", "0.20")
)
BACKLIGHT = os.environ.get("RK_POWERKEY_BACKLIGHT", "/sys/class/backlight/backlight")
WAYLAND_DISPLAY = os.environ.get("RK_POWERKEY_WAYLAND_DISPLAY", "wayland-0")

last_device_summary = None


def log(msg):
    print(f"rk-powerkey: {msg}", flush=True)


def monotonic_now():
    return time.monotonic()


def boottime_now():
    clock_boottime = getattr(time, "CLOCK_BOOTTIME", None)
    if clock_boottime is None:
        return monotonic_now()
    try:
        return time.clock_gettime(clock_boottime)
    except OSError:
        return monotonic_now()


def detect_resume(last_monotonic, last_boottime):
    now_monotonic = monotonic_now()
    now_boottime = boottime_now()
    suspend_gap = (now_boottime - last_boottime) - (now_monotonic - last_monotonic)
    resumed = suspend_gap >= RESUME_DETECT_GAP_SECONDS
    return now_monotonic, now_boottime, resumed, suspend_gap


# --- backlight (screen off/on) ---------------------------------------------

def backlight_read():
    try:
        with open(f"{BACKLIGHT}/bl_power") as fh:
            return fh.read().strip()
    except OSError:
        return None


def backlight_write(value):
    try:
        with open(f"{BACKLIGHT}/bl_power", "w") as fh:
            fh.write(str(value))
        return True
    except OSError as exc:
        log(f"backlight write failed: {exc}")
        return False


def backlight_on():
    if backlight_read() != "0":
        backlight_write(0)


def backlight_toggle():
    cur = backlight_read()
    if cur is None:
        log("backlight node missing; ignoring short press")
        return
    if cur == "0":
        if backlight_write(4):
            log("backlight -> off")
    else:
        if backlight_write(0):
            log("backlight -> on")


# --- power menu (long press) -----------------------------------------------

def load_target_user():
    entry = pwd.getpwnam(TARGET_USER)
    uid = entry.pw_uid
    runtime_dir = f"/run/user/{uid}"
    bus = f"unix:path={runtime_dir}/bus"
    return uid, runtime_dir, bus


def has_phosh_session(uid):
    result = subprocess.run(
        ["/usr/bin/pgrep", "-u", str(uid), "-f", "/usr/libexec/phosh"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=2,
        check=False,
    )
    return result.returncode == 0


def run_action(action):
    cmds = {
        "suspend": ["/usr/bin/systemctl", "suspend"],
        "poweroff": ["/usr/bin/systemctl", "poweroff"],
        "reboot": ["/usr/bin/systemctl", "reboot"],
    }
    cmd = cmds.get(action)
    if not cmd:
        return
    log(f"power menu action: {action}")
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   timeout=15, check=False)


def show_power_menu(uid, runtime_dir, bus):
    # The screen must be on for the menu to be visible.
    backlight_on()

    if not os.path.exists(f"{runtime_dir}/bus") or not has_phosh_session(uid):
        log("no phosh session; suspending directly")
        run_action("suspend")
        return

    cmd = [
        "/usr/sbin/runuser", "-u", TARGET_USER, "--",
        "/usr/bin/env",
        f"XDG_RUNTIME_DIR={runtime_dir}",
        f"DBUS_SESSION_BUS_ADDRESS={bus}",
        f"WAYLAND_DISPLAY={WAYLAND_DISPLAY}",
        "GDK_BACKEND=wayland,x11",
        "/usr/bin/zenity", "--list",
        "--title=電源", "--text=操作を選択",
        "--hide-header", "--column=action",
        "Suspend", "Power Off", "Restart",
    ]
    try:
        result = subprocess.run(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=30, check=False,
        )
    except subprocess.TimeoutExpired:
        log("power menu timed out")
        return

    choice = (result.stdout or b"").decode(errors="replace").strip()
    log(f"power menu choice: {choice!r}")
    if choice == "Suspend":
        run_action("suspend")
    elif choice == "Power Off":
        run_action("poweroff")
    elif choice == "Restart":
        run_action("reboot")


# --- input handling --------------------------------------------------------

def list_power_devices():
    global last_device_summary
    preferred = {}
    fallback = {}
    all_devs = []
    for path in list_devices():
        try:
            dev = InputDevice(path)
            all_devs.append(dev)
            caps = dev.capabilities().get(ecodes.EV_KEY, [])
            if ecodes.KEY_POWER not in caps:
                dev.close()
                continue

            name = (dev.name or "").lower()
            if "bt-powerkey" in name:
                dev.close()
                continue

            if (
                "rk805 pwrkey" in name
                or "rk8" in name
                or "pwrkey" in name
                or "gpio-keys" in name
            ):
                preferred[path] = dev
            else:
                fallback[path] = dev
        except OSError:
            continue

    devices = preferred if preferred else fallback
    for dev in all_devs:
        path = dev.path
        if path not in devices:
            try:
                dev.close()
            except OSError:
                pass

    for dev in devices.values():
        try:
            dev.grab()
        except OSError:
            pass

    summary = ", ".join(f"{p}:{d.name}" for p, d in sorted(devices.items()))
    if summary != last_device_summary:
        log(f"watching devices: {summary or 'none'}")
        last_device_summary = summary
    return devices


def main():
    try:
        uid, runtime_dir, bus = load_target_user()
    except KeyError:
        return 0

    power_down_at = None
    power_down_dev = None
    long_fired = False
    pending_toggle_at = None
    last_trigger = 0.0
    ignore_short_until = 0.0
    last_monotonic = monotonic_now()
    last_boottime = boottime_now()

    def handle_resume(now, gap):
        nonlocal ignore_short_until, power_down_at, power_down_dev
        nonlocal long_fired, pending_toggle_at
        ignore_short_until = max(ignore_short_until, now + POST_RESUME_IGNORE_SECONDS)
        power_down_at = None
        power_down_dev = None
        long_fired = False
        pending_toggle_at = None
        backlight_on()
        log(
            f"resume detected (+{gap:.2f}s); screen on, short-press "
            f"paused for {POST_RESUME_IGNORE_SECONDS:.1f}s"
        )

    while True:
        now, now_boot, resumed, gap = detect_resume(last_monotonic, last_boottime)
        last_monotonic, last_boottime = now, now_boot
        if resumed:
            handle_resume(now, gap)

        devices = list_power_devices()
        if not devices:
            time.sleep(SCAN_INTERVAL_SECONDS)
            continue

        try:
            next_rescan = monotonic_now() + SCAN_INTERVAL_SECONDS
            while True:
                now, now_boot, resumed, gap = detect_resume(
                    last_monotonic, last_boottime
                )
                last_monotonic, last_boottime = now, now_boot
                if resumed:
                    handle_resume(now, gap)

                event_seen = False
                for path, dev in list(devices.items()):
                    try:
                        event = dev.read_one()
                    except OSError:
                        event = None
                    if event is None:
                        continue
                    event_seen = True
                    if event.type != ecodes.EV_KEY or event.code != ecodes.KEY_POWER:
                        continue

                    now = monotonic_now()
                    if event.value == 1:
                        if power_down_at is None:
                            power_down_at = now
                            power_down_dev = path
                            long_fired = False
                            pending_toggle_at = None
                            log(f"power down from {path}")
                    elif event.value == 0:
                        if power_down_at is not None and (
                            power_down_dev is None or path == power_down_dev
                        ):
                            held = now - power_down_at
                            if long_fired:
                                log(f"power up after long press ({held:.2f}s)")
                            elif held >= MIN_PRESS_SECONDS:
                                if now < ignore_short_until:
                                    remaining = ignore_short_until - now
                                    log(
                                        "short press ignored during resume guard "
                                        f"({remaining:.2f}s left)"
                                    )
                                else:
                                    pending_toggle_at = now + RELEASE_SETTLE_SECONDS
                                    log(
                                        f"power up after short press ({held:.2f}s), "
                                        "backlight toggle pending"
                                    )
                            else:
                                log(f"ignored bounce release ({held:.3f}s)")
                        power_down_at = None
                        power_down_dev = None
                        long_fired = False

                now = monotonic_now()
                if power_down_at is not None and not long_fired:
                    held = now - power_down_at
                    if held >= LONG_PRESS_SECONDS:
                        long_fired = True
                        pending_toggle_at = None
                        if (now - last_trigger) >= TRIGGER_COOLDOWN_SECONDS:
                            last_trigger = now
                            log(f"long press ({held:.2f}s) -> power menu")
                            show_power_menu(uid, runtime_dir, bus)

                if (
                    pending_toggle_at is not None
                    and power_down_at is None
                    and now >= pending_toggle_at
                ):
                    pending_toggle_at = None
                    backlight_toggle()

                if not event_seen:
                    time.sleep(0.05)

                if (
                    monotonic_now() >= next_rescan
                    and power_down_at is None
                    and pending_toggle_at is None
                ):
                    break
        finally:
            for dev in devices.values():
                try:
                    dev.ungrab()
                except OSError:
                    pass
                try:
                    dev.close()
                except OSError:
                    pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
