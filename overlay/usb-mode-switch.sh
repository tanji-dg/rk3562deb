#!/bin/bash
set -euo pipefail

PHY_MODE="/sys/devices/platform/ff740000.usb2-phy/otg_mode"
DWC3_MODE="/sys/kernel/debug/usb/fe500000.usb/mode"
POLL_INTERVAL=${POLL_INTERVAL:-5}
CHARGER_CHECK_DELAY=${CHARGER_CHECK_DELAY:-3}

ensure_debugfs() {
    if ! mountpoint -q /sys/kernel/debug; then
        mount -t debugfs debugfs /sys/kernel/debug >/dev/null 2>&1 || true
    fi
}

set_mode() {
    local mode="$1"
    case "$mode" in
        host)
            [ -w "$PHY_MODE" ] && echo host > "$PHY_MODE" 2>/dev/null || true
            ensure_debugfs
            [ -w "$DWC3_MODE" ] && echo host > "$DWC3_MODE" 2>/dev/null || true
            ;;
        charger|charge|peripheral|device)
            [ -w "$PHY_MODE" ] && echo peripheral > "$PHY_MODE" 2>/dev/null || true
            ensure_debugfs
            [ -w "$DWC3_MODE" ] && echo device > "$DWC3_MODE" 2>/dev/null || true
            ;;
        otg)
            [ -w "$PHY_MODE" ] && echo otg > "$PHY_MODE" 2>/dev/null || true
            ensure_debugfs
            [ -w "$DWC3_MODE" ] && echo otg > "$DWC3_MODE" 2>/dev/null || true
            ;;
    esac
}

get_phy_mode() {
    cat "$PHY_MODE" 2>/dev/null || echo unknown
}

get_dwc3_mode() {
    ensure_debugfs
    if [ -r "$DWC3_MODE" ]; then
        cat "$DWC3_MODE" 2>/dev/null || echo unknown
    else
        echo unknown
    fi
}

battery_status() {
    cat /sys/class/power_supply/battery/status 2>/dev/null || echo Unknown
}

battery_pct() {
    cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo "?"
}

usb_devices_connected() {
    local count
    count=$(lsusb 2>/dev/null | grep -cv "root hub" || true)
    [ "${count:-0}" -gt 0 ]
}

print_status() {
    echo "PHY mode: $(get_phy_mode)"
    echo "DWC3 mode: $(get_dwc3_mode)"
    echo "Battery: $(battery_status) ($(battery_pct)%)"
    if usb_devices_connected; then
        echo "USB devices:"
        lsusb 2>/dev/null | grep -v "root hub" || true
    else
        echo "USB devices: none"
    fi
}

case "${1:-status}" in
    host)
        set_mode host
        print_status
        ;;
    charger|charge|peripheral|device)
        set_mode peripheral
        sleep "$CHARGER_CHECK_DELAY"
        print_status
        ;;
    status)
        print_status
        ;;
    auto)
        logger -t usb-role "starting auto mode (poll=${POLL_INTERVAL}s)"
        set_mode host

        while true; do
            sleep "$POLL_INTERVAL"

            # OTG accessory connected: stay in host mode.
            if usb_devices_connected; then
                if [ "$(get_dwc3_mode)" != "host" ]; then
                    logger -t usb-role "usb accessory detected, switching to host"
                    set_mode host
                fi
                continue
            fi

            # Already charging: keep peripheral/device mode.
            if [ "$(battery_status)" = "Charging" ]; then
                if [ "$(get_dwc3_mode)" != "device" ]; then
                    logger -t usb-role "charging detected, switching to peripheral"
                    set_mode peripheral
                fi
                continue
            fi

            # No accessory and not charging: probe for charger.
            set_mode peripheral
            sleep "$CHARGER_CHECK_DELAY"

            if [ "$(battery_status)" = "Charging" ]; then
                logger -t usb-role "charger detected, staying peripheral"
                while [ "$(battery_status)" = "Charging" ]; do
                    sleep "$POLL_INTERVAL"
                    if usb_devices_connected; then
                        logger -t usb-role "usb accessory appeared during charging, switching host"
                        break
                    fi
                done
            fi

            if [ "$(battery_status)" != "Charging" ]; then
                set_mode host
            fi
        done
        ;;
    *)
        echo "Usage: $0 [host|charger|status|auto]"
        exit 1
        ;;
esac
