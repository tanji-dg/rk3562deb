#!/bin/bash
# Auto USB mode switch for RK3562 tablet (USB-C, no Type-C controller)
# Switches between host (OTG) and peripheral (charging) automatically.
#
# Usage:
#   usb-mode-switch.sh host        - force host mode
#   usb-mode-switch.sh charger     - force peripheral mode
#   usb-mode-switch.sh status      - show current state
#   usb-mode-switch.sh auto        - auto-detect daemon (used by systemd)

OTG_MODE="/sys/devices/platform/ff740000.usb2-phy/otg_mode"
POLL_INTERVAL=${POLL_INTERVAL:-5}
CHARGER_CHECK_DELAY=3

set_mode() {
    echo "$1" > "$OTG_MODE" 2>/dev/null
}

get_mode() {
    cat "$OTG_MODE" 2>/dev/null
}

battery_status() {
    cat /sys/class/power_supply/battery/status 2>/dev/null
}

usb_devices_connected() {
    # Returns 0 (true) if real USB devices are connected (not just root hubs)
    local count
    count=$(lsusb 2>/dev/null | grep -cv "root hub")
    [ "$count" -gt 0 ]
}

case "${1:-status}" in
    host)
        set_mode host
        echo "Switched to USB host mode (OTG)"
        ;;
    charger|charge|peripheral)
        set_mode peripheral
        sleep "$CHARGER_CHECK_DELAY"
        echo "Switched to charging mode"
        echo "Battery: $(battery_status) ($(cat /sys/class/power_supply/battery/capacity 2>/dev/null)%)"
        ;;
    status)
        echo "USB mode: $(get_mode)"
        echo "Battery: $(battery_status) ($(cat /sys/class/power_supply/battery/capacity 2>/dev/null)%)"
        if usb_devices_connected; then
            echo "USB devices: $(lsusb 2>/dev/null | grep -v 'root hub')"
        else
            echo "USB devices: none"
        fi
        ;;
    auto)
        set_mode host
        logger -t usb-mode "starting auto mode (poll every ${POLL_INTERVAL}s)"

        while true; do
            sleep "$POLL_INTERVAL"
            MODE=$(get_mode)

            if [ "$MODE" = "host" ]; then
                # In host mode: check if any real USB device is connected
                if usb_devices_connected; then
                    # Device connected, stay in host mode
                    continue
                fi

                # No USB device — probe for charger
                set_mode peripheral
                sleep "$CHARGER_CHECK_DELAY"

                BATT=$(battery_status)
                logger -t usb-mode "probe: battery=$BATT"

                if [ "$BATT" = "Charging" ]; then
                    logger -t usb-mode "charger detected, staying in peripheral mode"
                    # Wait until charger is removed
                    while [ "$(battery_status)" = "Charging" ]; do
                        sleep "$POLL_INTERVAL"
                    done
                    logger -t usb-mode "charger removed, switching to host mode"
                fi

                set_mode host

            elif [ "$MODE" = "peripheral" ]; then
                # In peripheral mode (manually set or leftover): check if still charging
                if [ "$(battery_status)" != "Charging" ]; then
                    logger -t usb-mode "not charging, switching to host mode"
                    set_mode host
                fi
            fi
        done
        ;;
    *)
        echo "Usage: $0 [host|charger|status|auto]"
        exit 1
        ;;
esac
