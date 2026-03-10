#!/bin/bash
set -e

export PATH="/usr/sbin:/sbin:$PATH"

# RK3562 Debian 12 Bookworm Rootfs Builder

if [ "$EUID" -ne 0 ]; then
  echo "[-] This script must be run as root."
  exit 1
fi

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT_DIR="${ROOT_DIR}/out"
ROOTFS_MNT="${OUT_DIR}/rootfs"
MODULES_DIR="${OUT_DIR}/modules_staging/lib/modules"

echo "[*] Building Debian 12 Bookworm arm64 rootfs..."

# 1. Run debootstrap
if [ ! -f "${ROOTFS_MNT}/etc/debian_version" ]; then
    echo "[*] Cleaning old rootfs..."
    rm -rf "${ROOTFS_MNT}"
    mkdir -p "${ROOTFS_MNT}"

    echo "[*] Running debootstrap first stage..."
    debootstrap --arch=arm64 --foreign bookworm "${ROOTFS_MNT}" http://deb.debian.org/debian/

    echo "[*] Copying qemu-aarch64-static..."
    cp /usr/bin/qemu-aarch64-static "${ROOTFS_MNT}/usr/bin/"

    echo "[*] Running debootstrap second stage..."
    chmod +x "${ROOTFS_MNT}/debootstrap/debootstrap"
    chroot "${ROOTFS_MNT}" /debootstrap/debootstrap --second-stage
else
    echo "[*] Existing Debian 12 rootfs found. Skipping debootstrap..."
fi

# 2. Setup chroot mounts
echo "[*] Setting up chroot mounts..."
mount --bind /proc    "${ROOTFS_MNT}/proc"
mount --bind /sys     "${ROOTFS_MNT}/sys"
mount --bind /dev     "${ROOTFS_MNT}/dev"
mount --bind /dev/pts "${ROOTFS_MNT}/dev/pts"
rm -f "${ROOTFS_MNT}/etc/resolv.conf"
cp /etc/resolv.conf "${ROOTFS_MNT}/etc/resolv.conf"

chroot_cleanup() {
    umount -lf "${ROOTFS_MNT}/dev/pts" 2>/dev/null || true
    umount -lf "${ROOTFS_MNT}/dev"     2>/dev/null || true
    umount -lf "${ROOTFS_MNT}/sys"     2>/dev/null || true
    umount -lf "${ROOTFS_MNT}/proc"    2>/dev/null || true
}
trap chroot_cleanup EXIT

# 3. Configure Debian base
echo "[*] Configuring Debian base inside chroot..."

cat << 'CHROOT_EOF' > "${ROOTFS_MNT}/tmp/setup_debian.sh"
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# Ensure firmware repositories are available on Bookworm.
cat > /etc/apt/sources.list << 'APT_SOURCES'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
APT_SOURCES

# Update apt and install basic utilities
apt-get update
apt-get install -y sudo curl wget nano vim openssh-server network-manager wpasupplicant iw wireless-tools \
    network-manager-gnome bluez blueman policykit-1-gnome \
    xorg xserver-xorg xserver-xorg-input-libinput xfce4 xfce4-terminal firefox-esr mesa-utils libgl1-mesa-dri dbus \
    udev evtest lightdm pciutils usbutils \
    xinput libinput-tools \
    python3 \
    iproute2 iputils-ping dnsutils locales tzdata xfce4-power-manager upower brightnessctl rfkill \
    onboard wireless-regdb firmware-brcm80211

# Install one tray-indicator plugin if available on this Debian mirror.
for optional_pkg in xfce4-statusnotifier-plugin xfce4-indicator-plugin; do
    if apt-cache show "${optional_pkg}" >/dev/null 2>&1; then
        apt-get install -y "${optional_pkg}"
        break
    fi
done

# NetworkManager rejects plugin modules unless owned by root.
find /usr/lib -type f -path '*/NetworkManager/*/libnm-*.so' \
    -exec chown root:root {} + 2>/dev/null || true
    
# Generate locales
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# Add firefly user
if ! id "firefly" &>/dev/null; then
    useradd -m -s /bin/bash firefly
    echo "firefly:firefly" | chpasswd
    usermod -aG sudo,video,audio,netdev firefly
fi

# Set root password
echo "root:root" | chpasswd

# Setup NetworkManager
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable upower || true
systemctl enable lightdm

# Force NetworkManager to manage wlan interfaces on Debian.
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-rkdebian-managed.conf << 'NMCONF'
[main]
plugins=ifupdown,keyfile

[ifupdown]
managed=true

[keyfile]
unmanaged-devices=
NMCONF

# Keep interfaces minimal so NM can own Wi-Fi setup.
cat > /etc/network/interfaces << 'IFACES'
auto lo
iface lo inet loopback
IFACES

# Automatically power adapters when bluetoothd starts.
if grep -q '^[#[:space:]]*AutoEnable=' /etc/bluetooth/main.conf 2>/dev/null; then
    sed -i 's/^[#[:space:]]*AutoEnable=.*/AutoEnable=true/' /etc/bluetooth/main.conf
else
    printf '\n[Policy]\nAutoEnable=true\n' >> /etc/bluetooth/main.conf
fi

CHROOT_EOF

chmod +x "${ROOTFS_MNT}/tmp/setup_debian.sh"
chroot "${ROOTFS_MNT}" /tmp/setup_debian.sh
rm "${ROOTFS_MNT}/tmp/setup_debian.sh"

# Ensure privilege-escalation binaries/configs keep root ownership and setuid/setperm bits.
chroot "${ROOTFS_MNT}" chown root:root /etc/sudo.conf /usr/bin/sudo || true
chroot "${ROOTFS_MNT}" chmod 4755 /usr/bin/sudo || true
chroot "${ROOTFS_MNT}" chown root:root /etc/sudoers /etc/sudoers.d || true
chroot "${ROOTFS_MNT}" chmod 0440 /etc/sudoers || true
chroot "${ROOTFS_MNT}" chmod 0755 /etc/sudoers.d || true
if [ -d "${ROOTFS_MNT}/etc/sudoers.d" ]; then
    find "${ROOTFS_MNT}/etc/sudoers.d" -type f -exec chmod 0440 {} +
fi
if [ -e "${ROOTFS_MNT}/bin/su" ]; then
    chroot "${ROOTFS_MNT}" chown root:root /bin/su || true
    chroot "${ROOTFS_MNT}" chmod 4755 /bin/su || true
fi
if [ -e "${ROOTFS_MNT}/usr/bin/su" ]; then
    chroot "${ROOTFS_MNT}" chown root:root /usr/bin/su || true
    chroot "${ROOTFS_MNT}" chmod 4755 /usr/bin/su || true
fi
# 4. Install Kernel Modules
if [ -d "${MODULES_DIR}" ]; then
    echo "[*] Installing kernel modules..."
    mkdir -p "${ROOTFS_MNT}/lib/modules"
    cp -a --no-preserve=ownership "${MODULES_DIR}"/* "${ROOTFS_MNT}/lib/modules/"
else
    echo "[!] Warning: kernel modules not found at ${MODULES_DIR}"
fi

# 5. Install GPU/MPP packages
echo "[*] Installing GPU and MPP packages..."
if [ -d "${ROOT_DIR}/debs" ]; then
    if compgen -G "${ROOT_DIR}/debs/*.deb" > /dev/null; then
        mkdir -p "${ROOTFS_MNT}/tmp/debs"
        cp "${ROOT_DIR}/debs"/*.deb "${ROOTFS_MNT}/tmp/debs/"
        chroot "${ROOTFS_MNT}" bash -c 'dpkg -i /tmp/debs/*.deb || apt-get -f install -y' 2>/dev/null || true
        rm -rf "${ROOTFS_MNT}/tmp/debs"
    else
        echo "[!] Warning: No .deb files found in ${ROOT_DIR}/debs"
    fi
fi

# 5b. Install Mali userspace library from mali/ directory
if [ -d "${ROOT_DIR}/mali" ]; then
    echo "[*] Installing Mali userspace library..."
    mkdir -p "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu"
    if compgen -G "${ROOT_DIR}/mali/*.so" > /dev/null; then
        cp -f "${ROOT_DIR}/mali/"*.so "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/"
    fi
    # Create standard symlinks for libmali
    cd "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu"
    for so in libmali*.so; do
        [ -f "$so" ] || continue
        ln -sf "$so" libEGL.so.1 2>/dev/null || true
        ln -sf "$so" libGLESv2.so.2 2>/dev/null || true
        ln -sf "$so" libgbm.so.1 2>/dev/null || true
        ln -sf "$so" libOpenCL.so.1 2>/dev/null || true
    done
    cd "${ROOT_DIR}"
    chroot "${ROOTFS_MNT}" ldconfig
fi

# 6. Install WiFi/BT firmware
echo "[*] Installing WiFi and Bluetooth firmware..."
mkdir -p "${ROOTFS_MNT}/lib/firmware"
mkdir -p "${ROOTFS_MNT}/vendor/etc/firmware"
if [ -d "${ROOT_DIR}/wifi" ]; then
    find "${ROOT_DIR}/wifi" -maxdepth 3 -type f \( \
        -name "*.bin" -o -name "*.txt" -o -name "*.clm_blob" -o -name "*.hcd" -o -name "*.ini" \) \
        -exec cp -f {} "${ROOTFS_MNT}/lib/firmware/" \; 2>/dev/null || true
fi
if [ -d "${ROOT_DIR}/overlay/firmware" ]; then
    cp -a --no-preserve=ownership "${ROOT_DIR}/overlay/firmware/." "${ROOTFS_MNT}/lib/firmware/" 2>/dev/null || true
fi
# Bluetooth NV configuration files
if [ -d "${ROOT_DIR}/overlay/drivers/net/wireless/ea6621q/swtbt4l/" ]; then
    cp -f "${ROOT_DIR}/overlay/drivers/net/wireless/ea6621q/swtbt4l/"*.nvbin "${ROOTFS_MNT}/lib/firmware/" 2>/dev/null || true
fi

# BCMDHD default firmware paths (kernel config points to /vendor/etc/firmware)
BCM_FW=$(find "${ROOTFS_MNT}/lib/firmware" -type f \( -name "*43455*bin" -o -name "*ap6255*bin" \) | head -n1 || true)
BCM_NVRAM=$(find "${ROOTFS_MNT}/lib/firmware" -type f \( -name "*43455*txt" -o -name "*ap6255*txt" -o -name "*nvram*.txt" \) | head -n1 || true)
BCM_CLM=$(find "${ROOTFS_MNT}/lib/firmware" -type f -name "*.clm_blob" | head -n1 || true)

if [ -n "${BCM_FW}" ]; then
    cp -f "${BCM_FW}" "${ROOTFS_MNT}/vendor/etc/firmware/fw_bcmdhd.bin"
fi
if [ -n "${BCM_NVRAM}" ]; then
    cp -f "${BCM_NVRAM}" "${ROOTFS_MNT}/vendor/etc/firmware/nvram.txt"
fi
if [ -n "${BCM_CLM}" ]; then
    cp -f "${BCM_CLM}" "${ROOTFS_MNT}/vendor/etc/firmware/bcmdhd_clm.blob"
fi

# Auto-load bluetooth driver module
mkdir -p "${ROOTFS_MNT}/etc/modules-load.d/"
echo "skwbt" > "${ROOTFS_MNT}/etc/modules-load.d/skwbt.conf"

# 7. Add Mali GPU udev rules
echo "[*] Adding Mali GPU udev rules..."
mkdir -p "${ROOTFS_MNT}/etc/udev/rules.d"
tee "${ROOTFS_MNT}/etc/udev/rules.d/99-mali.rules" > /dev/null << 'UDEV_MALI'
KERNEL=="mali0", GROUP="video", MODE="0666"
KERNEL=="rga", GROUP="video", MODE="0666"
SUBSYSTEM=="dma_heap", MODE="0666"
UDEV_MALI

echo "[*] Adding backlight permission rule..."
tee "${ROOTFS_MNT}/etc/udev/rules.d/90-backlight-permissions.rules" > /dev/null << 'UDEV_BACKLIGHT'
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness"
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chmod g+w /sys/class/backlight/%k/brightness"
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video /sys/class/backlight/%k/bl_power"
ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chmod g+w /sys/class/backlight/%k/bl_power"
UDEV_BACKLIGHT

echo "[*] Adding touchscreen input rule..."
tee "${ROOTFS_MNT}/etc/udev/rules.d/99-touchscreen-gsl3673.rules" > /dev/null << 'UDEV_TS'
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="gsl3673", ENV{ID_INPUT}="1", ENV{ID_INPUT_TOUCHSCREEN}="1"
UDEV_TS

mkdir -p "${ROOTFS_MNT}/etc/X11/xorg.conf.d"
cat > "${ROOTFS_MNT}/etc/X11/xorg.conf.d/40-gsl3673-touchscreen.conf" << 'XORG_TS'
Section "InputClass"
    Identifier "gsl3673 touchscreen"
    MatchProduct "gsl3673"
    MatchIsTouchscreen "on"
    Driver "libinput"
EndSection
XORG_TS

# 8. Setting hostname and fstab
echo "[*] Setting hostname and fstab..."
echo "rk3562-debian" > "${ROOTFS_MNT}/etc/hostname"

cat > "${ROOTFS_MNT}/etc/fstab" << 'FSTAB'
# <file system>  <mount point>  <type>  <options>        <dump>  <pass>
PARTUUID=c0ffee11-2233-4455-6677-8899aabbccdd  /  ext4  defaults,noatime  0  1
FSTAB

# 9. Autologin LightDM and disable XFCE auto-suspend
echo "[*] Configuring LightDM autologin..."
LIGHTDM_CONF="${ROOTFS_MNT}/etc/lightdm/lightdm.conf"
if [ -f "${LIGHTDM_CONF}" ]; then
    sed -i 's/^#\?autologin-user=.*/autologin-user=firefly/' "${LIGHTDM_CONF}" || true
    sed -i 's/^#\?autologin-user-timeout=.*/autologin-user-timeout=0/' "${LIGHTDM_CONF}" || true
    if ! grep -q '^autologin-user=firefly' "${LIGHTDM_CONF}"; then
        cat >> "${LIGHTDM_CONF}" << 'LIGHTDM_EOF'
[Seat:*]
autologin-user=firefly
autologin-user-timeout=0
LIGHTDM_EOF
    fi
else
    mkdir -p "${ROOTFS_MNT}/etc/lightdm"
    cat > "${LIGHTDM_CONF}" << 'LIGHTDM_EOF'
[Seat:*]
autologin-user=firefly
autologin-user-timeout=0
LIGHTDM_EOF
fi

echo "[*] Disabling xfce4-power-manager auto-suspend..."
# Power manager config
mkdir -p "${ROOTFS_MNT}/home/firefly/.config/xfce4/xfconf/xfce-perchannel-xml"
cat > "${ROOTFS_MNT}/home/firefly/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml" << 'XFCEPM'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="blank-on-ac" type="int" value="0"/>
    <property name="blank-on-battery" type="int" value="0"/>
    <property name="dpms-on-ac-sleep" type="uint" value="0"/>
    <property name="dpms-on-ac-off" type="uint" value="0"/>
    <property name="dpms-on-battery-sleep" type="uint" value="0"/>
    <property name="dpms-on-battery-off" type="uint" value="0"/>
    <property name="inactivity-on-ac" type="uint" value="0"/>
    <property name="inactivity-on-battery" type="uint" value="0"/>
    <property name="lid-action-on-ac" type="uint" value="0"/>
    <property name="lid-action-on-battery" type="uint" value="0"/>
    <property name="sleep-button-action" type="uint" value="0"/>
    <property name="critical-power-action" type="uint" value="0"/>
  </property>
</channel>
XFCEPM
chroot "${ROOTFS_MNT}" chown -R firefly:firefly /home/firefly/.config

# Setup Xfce power manager autostart
mkdir -p "${ROOTFS_MNT}/etc/xdg/autostart"
cat > "${ROOTFS_MNT}/etc/xdg/autostart/xfce4-power-manager.desktop" << 'PMDESKTOP'
[Desktop Entry]
Type=Application
Name=Xfce Power Manager
Exec=xfce4-power-manager
OnlyShowIn=XFCE;
X-XFCE-Autostart-Override=true
PMDESKTOP

# Ensure Wi-Fi/Bluetooth tray applets are launched in XFCE even if package
# autostart files are missing in this rootfs variant.
if [ ! -f "${ROOTFS_MNT}/etc/xdg/autostart/nm-applet.desktop" ]; then
cat > "${ROOTFS_MNT}/etc/xdg/autostart/nm-applet.desktop" << 'NMAP'
[Desktop Entry]
Type=Application
Name=Network Manager Applet
Exec=nm-applet
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
NMAP
fi

if [ ! -f "${ROOTFS_MNT}/etc/xdg/autostart/blueman.desktop" ] && \
   [ ! -f "${ROOTFS_MNT}/etc/xdg/autostart/blueman-applet.desktop" ]; then
cat > "${ROOTFS_MNT}/etc/xdg/autostart/blueman-applet.desktop" << 'BLUEMAN'
[Desktop Entry]
Type=Application
Name=Blueman Applet
Exec=blueman-applet
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
BLUEMAN
fi

if [ ! -f "${ROOTFS_MNT}/etc/xdg/autostart/polkit-gnome-authentication-agent-1.desktop" ]; then
cat > "${ROOTFS_MNT}/etc/xdg/autostart/polkit-gnome-authentication-agent-1.desktop" << 'POLKIT'
[Desktop Entry]
Type=Application
Name=PolicyKit Authentication Agent
Exec=/usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
POLKIT
fi

# Add a desktop shortcut for the on-screen keyboard.
mkdir -p "${ROOTFS_MNT}/home/firefly/Desktop"
cat > "${ROOTFS_MNT}/home/firefly/Desktop/on-screen-keyboard.desktop" << 'ONBOARD'
[Desktop Entry]
Type=Application
Name=On-Screen Keyboard
Comment=Launch on-screen keyboard
Exec=onboard
Icon=onboard
Terminal=false
Categories=Utility;
ONBOARD
chmod +x "${ROOTFS_MNT}/home/firefly/Desktop/on-screen-keyboard.desktop"
chroot "${ROOTFS_MNT}" chown firefly:firefly /home/firefly/Desktop/on-screen-keyboard.desktop || true

# logind.conf ignoring power key
mkdir -p "${ROOTFS_MNT}/etc/systemd/logind.conf.d"
cat > "${ROOTFS_MNT}/etc/systemd/logind.conf.d/power-button.conf" << 'LOGIND'
[Login]
HandlePowerKey=ignore
LOGIND

echo "[*] Adding polkit rule for backlight control..."
mkdir -p "${ROOTFS_MNT}/etc/polkit-1/rules.d"
cat > "${ROOTFS_MNT}/etc/polkit-1/rules.d/49-backlight.rules" << 'BACKLIGHT_POLKIT'
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.login1.set-backlight" &&
        subject.isInGroup("video")) {
        return polkit.Result.YES;
    }
});
BACKLIGHT_POLKIT

# Ensure rfkill soft-blocks are cleared each boot.
echo "[*] Installing rfkill unblock service..."
cat > "${ROOTFS_MNT}/etc/systemd/system/rk-unblock-rfkill.service" << 'RFKILL_UNIT'
[Unit]
Description=Unblock all rfkill devices
DefaultDependencies=no
After=systemd-rfkill.service
Before=NetworkManager.service bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill unblock all

[Install]
WantedBy=multi-user.target
RFKILL_UNIT

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/rk-unblock-rfkill.service \
    "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/rk-unblock-rfkill.service"

# 10. USB OTG service
if [ -f "${ROOT_DIR}/overlay/usb-mode-switch.sh" ] && [ -f "${ROOT_DIR}/overlay/usb-otg-host.service" ]; then
    echo "[*] Installing USB OTG service..."
    cp "${ROOT_DIR}/overlay/usb-mode-switch.sh" "${ROOTFS_MNT}/usr/local/bin/usb-mode-switch.sh"
    chmod +x "${ROOTFS_MNT}/usr/local/bin/usb-mode-switch.sh"
    cp "${ROOT_DIR}/overlay/usb-otg-host.service" "${ROOTFS_MNT}/etc/systemd/system/usb-otg-host.service"
    chroot "${ROOTFS_MNT}" systemctl enable usb-otg-host.service
fi

# 10b. RK817 hard poweroff hook
echo "[*] Installing RK817 hard poweroff hook..."
mkdir -p "${ROOTFS_MNT}/usr/local/sbin"
cat > "${ROOTFS_MNT}/usr/local/sbin/rk817-dev-off.py" << 'RK817_OFF'
#!/usr/bin/env python3
import fcntl
import os

I2C_SLAVE_FORCE = 0x0706
I2C_BUS = "/dev/i2c-0"
RK817_ADDR = 0x20
SYS_CFG3 = 0xF4


def main() -> int:
    try:
        fd = os.open(I2C_BUS, os.O_RDWR)
    except OSError:
        return 0

    try:
        fcntl.ioctl(fd, I2C_SLAVE_FORCE, RK817_ADDR)
        os.write(fd, bytes([SYS_CFG3]))
        raw = os.read(fd, 1)
        if not raw:
            return 1
        value = raw[0] | 0x01
        os.write(fd, bytes([SYS_CFG3, value]))
        return 0
    finally:
        os.close(fd)


if __name__ == "__main__":
    raise SystemExit(main())
RK817_OFF
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk817-dev-off.py"

mkdir -p "${ROOTFS_MNT}/etc/systemd/system"
cat > "${ROOTFS_MNT}/etc/systemd/system/rk817-hard-poweroff.service" << 'RK817_UNIT'
[Unit]
Description=Force RK817 DEV_OFF before poweroff
DefaultDependencies=no
Before=systemd-poweroff.service
Conflicts=reboot.target halt.target kexec.target
ConditionPathExists=/dev/i2c-0

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/sbin/rk817-dev-off.py
TimeoutSec=3

[Install]
WantedBy=poweroff.target
RK817_UNIT

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/poweroff.target.wants"
ln -sf /etc/systemd/system/rk817-hard-poweroff.service \
    "${ROOTFS_MNT}/etc/systemd/system/poweroff.target.wants/rk817-hard-poweroff.service"

# 11. Expand rootfs service
echo "[*] Adding first-boot rootfs expand..."
cat > "${ROOTFS_MNT}/usr/local/bin/expand-rootfs.sh" << 'EXPAND'
#!/bin/bash
exec > /var/log/expand-rootfs.log 2>&1
ROOT_PART=$(findmnt -n -o SOURCE /)
DISK=${ROOT_PART%p[0-9]*}
PARTNUM=${ROOT_PART##*p}
if [ -z "$DISK" ] || [ -z "$PARTNUM" ]; then exit 1; fi
if ! command -v growpart >/dev/null 2>&1 || ! command -v sgdisk >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y cloud-guest-utils gdisk e2fsprogs || true
fi
sgdisk -e "$DISK" || true
growpart "$DISK" "$PARTNUM" || true
partprobe "$DISK" 2>/dev/null || true
sleep 1
resize2fs "$ROOT_PART" || true
systemctl disable expand-rootfs.service
EXPAND
chmod +x "${ROOTFS_MNT}/usr/local/bin/expand-rootfs.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/expand-rootfs.service" << 'SVCUNIT'
[Unit]
Description=Expand rootfs to fill SD card
After=multi-user.target
ConditionPathExists=/usr/local/bin/expand-rootfs.sh

[Service]
Type=oneshot
ExecStart=/usr/local/bin/expand-rootfs.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCUNIT

chroot "${ROOTFS_MNT}" systemctl enable expand-rootfs.service
chroot "${ROOTFS_MNT}" bash -c 'apt-get install -y cloud-guest-utils gdisk 2>/dev/null || true'

# 12. Serial console
echo "[*] Enabling serial console (ttyS0)..."
mkdir -p "${ROOTFS_MNT}/etc/systemd/system/getty.target.wants"
ln -sf /lib/systemd/system/serial-getty@.service \
    "${ROOTFS_MNT}/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"

# 13. Cleanup package caches to reduce rootfs size before image packing
echo "[*] Cleaning apt caches and temporary files..."
chroot "${ROOTFS_MNT}" bash -c 'apt-get clean || true'
rm -rf "${ROOTFS_MNT}/var/cache/apt/archives/"* 2>/dev/null || true
rm -rf "${ROOTFS_MNT}/var/lib/apt/lists/"* 2>/dev/null || true
rm -rf "${ROOTFS_MNT}/tmp/"* 2>/dev/null || true
rm -rf "${ROOTFS_MNT}/var/tmp/"* 2>/dev/null || true

chroot_cleanup
trap - EXIT

echo "[*] Rootfs creation complete."
