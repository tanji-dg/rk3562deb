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
    xorg xserver-xorg xserver-xorg-input-libinput xfce4 xfce4-terminal firefox-esr mesa-utils libgl1-mesa-dri mesa-vulkan-drivers \
    pulseaudio pulseaudio-utils pulseaudio-module-bluetooth pavucontrol alsa-utils libasound2-plugins \
    zram-tools \
    plymouth plymouth-themes \
    libegl1 libgles2 libgbm1 ffmpeg dbus \
    udev evtest lightdm pciutils usbutils \
    xinput libinput-tools \
    python3 \
    iproute2 iputils-ping dnsutils locales tzdata xfce4-power-manager upower brightnessctl rfkill \
    vainfo vdpauinfo \
    onboard wireless-regdb firmware-brcm80211

# Install one tray-indicator plugin if available on this Debian mirror.
for optional_pkg in xfce4-statusnotifier-plugin xfce4-indicator-plugin; do
    if apt-cache show "${optional_pkg}" >/dev/null 2>&1; then
        apt-get install -y "${optional_pkg}"
        break
    fi
done

# Install optional desktop helpers when available.
for optional_pkg in xfce4-pulseaudio-plugin iio-sensor-proxy; do
    if apt-cache show "${optional_pkg}" >/dev/null 2>&1; then
        apt-get install -y "${optional_pkg}"
    fi
done

# NetworkManager rejects plugin modules unless owned by root.
find /usr/lib -type f -path '*/NetworkManager/*/libnm-*.so' \
    -exec chown root:root {} + 2>/dev/null || true
    
# Generate locales
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# Add default user
groupadd -f render
if ! id "chaos" &>/dev/null; then
    useradd -m -s /bin/bash chaos
    echo "chaos:chaos" | chpasswd
fi
usermod -aG sudo,video,audio,netdev,render chaos

# Set root password
echo "root:root" | chpasswd

# Setup NetworkManager
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable upower || true
systemctl enable lightdm

# Enable compressed RAM swap to improve responsiveness on 4GB systems.
cat > /etc/default/zramswap << 'ZRAMCFG'
ALGO=lz4
PERCENT=50
PRIORITY=100
ZRAMCFG
systemctl enable zramswap.service || true

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

# Force Firefox to use EGL on X11 so compositing can use GPU.
if [ -f /usr/share/applications/firefox-esr.desktop ]; then
    sed -i -E 's|^Exec=.*firefox-esr.*$|Exec=env MOZ_DISABLE_RDD_SANDBOX=1 /usr/lib/firefox-esr/firefox-esr %u|' \
        /usr/share/applications/firefox-esr.desktop || true
fi

# Configure a simple boot splash theme.
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    plymouth-set-default-theme spinner || true
fi
systemctl enable plymouth-start.service plymouth-quit.service plymouth-quit-wait.service 2>/dev/null || true

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
    chroot "${ROOTFS_MNT}" chown -R root:root /etc/sudoers.d || true
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

# Allow desktop users in video group to access Rockchip media devices.
tee "${ROOTFS_MNT}/etc/udev/rules.d/98-rockchip-mpp.rules" > /dev/null << 'UDEV_MPP'
KERNEL=="mpp_service", GROUP="video", MODE="0660"
KERNEL=="rkvdec*", GROUP="video", MODE="0660"
KERNEL=="rkvenc*", GROUP="video", MODE="0660"
KERNEL=="vepu*", GROUP="video", MODE="0660"
KERNEL=="vdpu*", GROUP="video", MODE="0660"
UDEV_MPP

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

cat > "${ROOTFS_MNT}/etc/X11/xorg.conf.d/20-modesetting-rockchip.conf" << 'XORG_GPU'
Section "Device"
    Identifier "Rockchip Graphics"
    Driver "modesetting"
    Option "AccelMethod" "glamor"
    Option "DRI" "3"
EndSection
XORG_GPU

echo "[*] Adding Firefox acceleration defaults..."
mkdir -p "${ROOTFS_MNT}/usr/lib/firefox-esr/defaults/pref"
FF_VAAPI_ENABLED="false"
if [ -f "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/dri/rockchip_drv_video.so" ]; then
    FF_VAAPI_ENABLED="true"
    cat > "${ROOTFS_MNT}/usr/lib/firefox-esr/defaults/pref/rk3562-gfx.js" << 'FIREFOX_PREFS_HW'
pref("gfx.webrender.all", true);
pref("gfx.x11-egl.force-enabled", true);
pref("layers.acceleration.force-enabled", true);
pref("media.hardware-video-decoding.enabled", true);
pref("media.hardware-video-decoding.force-enabled", true);
pref("media.ffmpeg.vaapi.enabled", true);
pref("media.ffmpeg.dmabuf-textures.enabled", true);
pref("media.rdd-ffmpeg.enabled", true);
pref("media.av1.enabled", false);
pref("media.mediasource.av1.enabled", false);
pref("media.mediasource.vp9.enabled", false);
FIREFOX_PREFS_HW
else
    echo "[!] Warning: rockchip_drv_video.so missing; using Firefox software-video fallback profile."
    cat > "${ROOTFS_MNT}/usr/lib/firefox-esr/defaults/pref/rk3562-gfx.js" << 'FIREFOX_PREFS_SW'
pref("gfx.webrender.all", false);
pref("gfx.x11-egl.force-enabled", false);
pref("layers.acceleration.force-enabled", false);
pref("media.hardware-video-decoding.enabled", false);
pref("media.hardware-video-decoding.force-enabled", false);
pref("media.ffmpeg.vaapi.enabled", false);
pref("media.ffmpeg.dmabuf-textures.enabled", false);
pref("media.rdd-ffmpeg.enabled", true);
pref("media.mediasource.enabled", false);
pref("media.webm.enabled", false);
pref("media.mediasource.webm.enabled", false);
pref("media.av1.enabled", false);
pref("media.mediasource.av1.enabled", false);
pref("media.mediasource.vp9.enabled", false);
FIREFOX_PREFS_SW
fi

# Keep Firefox environment deterministic across rebuilds.
touch "${ROOTFS_MNT}/etc/environment"
sed -i '/^MOZ_X11_EGL=/d;/^MOZ_WEBRENDER=/d;/^MOZ_DISABLE_RDD_SANDBOX=/d' \
    "${ROOTFS_MNT}/etc/environment" || true
echo "MOZ_DISABLE_RDD_SANDBOX=1" >> "${ROOTFS_MNT}/etc/environment"
if [ "${FF_VAAPI_ENABLED}" = "true" ]; then
    echo "MOZ_X11_EGL=1" >> "${ROOTFS_MNT}/etc/environment"
    echo "MOZ_WEBRENDER=1" >> "${ROOTFS_MNT}/etc/environment"
fi

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
    sed -i 's/^#\?autologin-user=.*/autologin-user=chaos/' "${LIGHTDM_CONF}" || true
    sed -i 's/^#\?autologin-user-timeout=.*/autologin-user-timeout=0/' "${LIGHTDM_CONF}" || true
    if ! grep -q '^autologin-user=chaos' "${LIGHTDM_CONF}"; then
        cat >> "${LIGHTDM_CONF}" << 'LIGHTDM_EOF'
[Seat:*]
autologin-user=chaos
autologin-user-timeout=0
LIGHTDM_EOF
    fi
else
    mkdir -p "${ROOTFS_MNT}/etc/lightdm"
    cat > "${LIGHTDM_CONF}" << 'LIGHTDM_EOF'
[Seat:*]
autologin-user=chaos
autologin-user-timeout=0
LIGHTDM_EOF
fi

echo "[*] Disabling xfce4-power-manager auto-suspend..."
# Power manager config
mkdir -p "${ROOTFS_MNT}/home/chaos/.config/xfce4/xfconf/xfce-perchannel-xml"
cat > "${ROOTFS_MNT}/home/chaos/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml" << 'XFCEPM'
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
chroot "${ROOTFS_MNT}" chown -R chaos:chaos /home/chaos/.config

# Disable XFWM compositor by default on this low-power tablet; helps browser fps.
cat > "${ROOTFS_MNT}/home/chaos/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" << 'XFWM4CFG'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
XFWM4CFG
chroot "${ROOTFS_MNT}" chown chaos:chaos /home/chaos/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml || true

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

# Keep panel startup deterministic. If a broken saved XFCE session omits the
# panel, this helper brings it back automatically.
mkdir -p "${ROOTFS_MNT}/usr/local/bin"
cat > "${ROOTFS_MNT}/usr/local/bin/rk-xfce4-panel-start.sh" << 'RK_PANEL_START'
#!/bin/sh
set -eu

PATH=/usr/bin:/bin

if pgrep -x xfce4-panel >/dev/null 2>&1; then
    exit 0
fi

for _ in $(seq 1 25); do
    dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
      /org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1 && break
    sleep 1
done

exec xfce4-panel
RK_PANEL_START
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-xfce4-panel-start.sh"

cat > "${ROOTFS_MNT}/etc/xdg/autostart/rk-xfce4-panel.desktop" << 'RK_PANEL_DESKTOP'
[Desktop Entry]
Type=Application
Name=RK XFCE Panel Start
Exec=/usr/local/bin/rk-xfce4-panel-start.sh
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
NoDisplay=true
RK_PANEL_DESKTOP

# Avoid persisting a "panel-less" saved session across reboots.
mkdir -p "${ROOTFS_MNT}/home/chaos/.config/xfce4/xfconf/xfce-perchannel-xml"
cat > "${ROOTFS_MNT}/home/chaos/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml" << 'XFCESESSION'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-session" version="1.0">
  <property name="general" type="empty">
    <property name="SaveOnExit" type="bool" value="false"/>
  </property>
</channel>
XFCESESSION
chroot "${ROOTFS_MNT}" chown chaos:chaos /home/chaos/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml || true

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

# Add an explicit XFCE autostart entry for blueman so login behavior stays
# deterministic across desktop-package variants.
mkdir -p "${ROOTFS_MNT}/usr/local/bin"
cat > "${ROOTFS_MNT}/usr/local/bin/rk-blueman-applet-start.sh" << 'RK_BLUEMAN_START'
#!/bin/sh
set -eu

PATH=/usr/bin:/bin

if pgrep -x blueman-applet >/dev/null 2>&1; then
    exit 0
fi

# Wait briefly for session DBus/panel startup to avoid autostart races.
for _ in $(seq 1 20); do
    dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
      /org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1 && break
    sleep 1
done

exec blueman-applet
RK_BLUEMAN_START
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-blueman-applet-start.sh"

cat > "${ROOTFS_MNT}/etc/xdg/autostart/rk-blueman-applet.desktop" << 'RK_BLUEMAN'
[Desktop Entry]
Type=Application
Name=RK Blueman Applet
Exec=/usr/local/bin/rk-blueman-applet-start.sh
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
NoDisplay=true
RK_BLUEMAN

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
mkdir -p "${ROOTFS_MNT}/home/chaos/Desktop"
cat > "${ROOTFS_MNT}/home/chaos/Desktop/on-screen-keyboard.desktop" << 'ONBOARD'
[Desktop Entry]
Type=Application
Name=On-Screen Keyboard
Comment=Launch on-screen keyboard
Exec=onboard
Icon=onboard
Terminal=false
Categories=Utility;
ONBOARD
chmod +x "${ROOTFS_MNT}/home/chaos/Desktop/on-screen-keyboard.desktop"
chroot "${ROOTFS_MNT}" chown chaos:chaos /home/chaos/Desktop/on-screen-keyboard.desktop || true

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

# Reduce Seekwave Wi-Fi UART spam so text tools (nmtui, shell) remain usable.
echo "[*] Installing skwifi log-level service..."
cat > "${ROOTFS_MNT}/etc/systemd/system/skwifi-loglevel.service" << 'SKWIFI_LOG_UNIT'
[Unit]
Description=Set Seekwave Wi-Fi log level to warn
After=systemd-modules-load.service
Before=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for i in $(seq 1 20); do [ -w /proc/skwifi/log_level ] && echo warn > /proc/skwifi/log_level && exit 0; sleep 1; done; exit 0'

[Install]
WantedBy=multi-user.target
SKWIFI_LOG_UNIT

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/skwifi-loglevel.service \
    "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/skwifi-loglevel.service"

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

# Recover Bluetooth controller if it fails to appear during boot races.
echo "[*] Installing Bluetooth recovery service..."
mkdir -p "${ROOTFS_MNT}/usr/local/sbin"
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-bluetooth-recover.sh" << 'RK_BT_RECOVER'
#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin
READY_FILE="/run/rk-bt-ready"

controller_ready() {
    bluetoothctl list 2>/dev/null | grep -q '^Controller '
}

[ -e "${READY_FILE}" ] && exit 0

if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock all || true
fi

if command -v modprobe >/dev/null 2>&1; then
    modprobe skwbt >/dev/null 2>&1 || true
fi

for _ in $(seq 1 20); do
    if controller_ready; then
        printf 'power on\nquit\n' | bluetoothctl >/dev/null 2>&1 || true
        touch "${READY_FILE}"
        exit 0
    fi
    sleep 1
done

if command -v modprobe >/dev/null 2>&1; then
    modprobe -r skwbt >/dev/null 2>&1 || true
    sleep 1
    modprobe skwbt >/dev/null 2>&1 || true
fi

systemctl restart bluetooth.service >/dev/null 2>&1 || true

for _ in $(seq 1 20); do
    if controller_ready; then
        printf 'power on\nquit\n' | bluetoothctl >/dev/null 2>&1 || true
        touch "${READY_FILE}"
        exit 0
    fi
    sleep 1
done

exit 0
RK_BT_RECOVER
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-bluetooth-recover.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-bluetooth-recover.service" << 'RK_BT_RECOVER_UNIT'
[Unit]
Description=Recover Seekwave Bluetooth controller
After=systemd-modules-load.service dbus.service bluetooth.service NetworkManager.service
Wants=bluetooth.service NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rk-bluetooth-recover.sh

[Install]
WantedBy=multi-user.target
RK_BT_RECOVER_UNIT

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/rk-bluetooth-recover.service \
    "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/rk-bluetooth-recover.service"

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-bluetooth-recover.timer" << 'RK_BT_RECOVER_TIMER'
[Unit]
Description=Retry Seekwave Bluetooth recovery until controller appears

[Timer]
OnBootSec=15s
OnUnitActiveSec=25s
AccuracySec=1s
Unit=rk-bluetooth-recover.service

[Install]
WantedBy=timers.target
RK_BT_RECOVER_TIMER

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/timers.target.wants"
ln -sf /etc/systemd/system/rk-bluetooth-recover.timer \
    "${ROOTFS_MNT}/etc/systemd/system/timers.target.wants/rk-bluetooth-recover.timer"

# Initialize ALSA controls at boot so speaker/mic paths are sane on RK817.
echo "[*] Installing ALSA init service..."
mkdir -p "${ROOTFS_MNT}/usr/local/sbin"
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-audio-init.sh" << 'RK_AUDIO_INIT'
#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin

/usr/sbin/alsactl init || true

for c in /proc/asound/card*; do
    [ -d "$c" ] || continue
    i=${c##*/card}
    /usr/bin/amixer -q -c "$i" sset Speaker unmute >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$i" sset Speaker 100% >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$i" sset Headphone unmute >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$i" sset Headphone 100% >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$i" sset Master unmute >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$i" sset Master 100% >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$i" sset PCM unmute >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$i" sset PCM 100% >/dev/null 2>&1 || true
done

rk_card=""
if [ -r /proc/asound/cards ]; then
    rk_card="$(awk '/rk817|rockchip-rk817/ {print $1; exit}' /proc/asound/cards | tr -d ' ' || true)"
fi

if [ -n "$rk_card" ]; then
    for path in SPK_HP SPK HP RCV; do
        /usr/bin/amixer -q -c "$rk_card" cset name='Playback Path' "$path" >/dev/null 2>&1 && break
    done
    /usr/bin/amixer -q -c "$rk_card" cset name='Capture MIC Path' 'Main Mic' >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$rk_card" cset name='Capture Volume' 192 >/dev/null 2>&1 || true
    /usr/bin/amixer -q -c "$rk_card" cset name='PCM' 192 >/dev/null 2>&1 || true
fi

/usr/sbin/alsactl store >/dev/null 2>&1 || true

exit 0
RK_AUDIO_INIT
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-audio-init.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-alsa-init.service" << 'ALSA_INIT_UNIT'
[Unit]
Description=Initialize ALSA controls
After=systemd-modules-load.service sound.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rk-audio-init.sh

[Install]
WantedBy=multi-user.target
ALSA_INIT_UNIT

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/rk-alsa-init.service \
    "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/rk-alsa-init.service"

# Restore PulseAudio sink/source routing at desktop login. Some boots expose
# HDMI/null outputs first and leave analog output muted.
echo "[*] Installing desktop audio recovery helper..."
mkdir -p "${ROOTFS_MNT}/usr/local/bin"
cat > "${ROOTFS_MNT}/usr/local/bin/rk-audio-session-fix.sh" << 'RK_AUDIO_SESSION'
#!/bin/sh
set -eu

PATH=/usr/bin:/bin

if ! command -v pactl >/dev/null 2>&1; then
    exit 0
fi

for _ in $(seq 1 20); do
    pactl info >/dev/null 2>&1 && break
    sleep 1
done

sink="$(pactl list short sinks 2>/dev/null | awk '/rockchip|rk817|analog-stereo/ {print $2; exit}' || true)"
if [ -n "${sink}" ]; then
    pactl set-default-sink "${sink}" >/dev/null 2>&1 || true
    pactl set-sink-mute "${sink}" 0 >/dev/null 2>&1 || true
    pactl set-sink-volume "${sink}" 100% >/dev/null 2>&1 || true
fi

source="$(pactl list short sources 2>/dev/null | awk '/rockchip|rk817|analog-stereo/ {print $2; exit}' || true)"
if [ -n "${source}" ]; then
    pactl set-default-source "${source}" >/dev/null 2>&1 || true
    pactl set-source-mute "${source}" 0 >/dev/null 2>&1 || true
fi

exit 0
RK_AUDIO_SESSION
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-audio-session-fix.sh"

cat > "${ROOTFS_MNT}/etc/xdg/autostart/rk-audio-session-fix.desktop" << 'RK_AUDIO_SESSION_DESKTOP'
[Desktop Entry]
Type=Application
Name=RK Audio Session Fix
Exec=/usr/local/bin/rk-audio-session-fix.sh
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
NoDisplay=true
RK_AUDIO_SESSION_DESKTOP

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

# 11. Offline update package auto-apply service
echo "[*] Installing offline update auto-apply service..."
mkdir -p "${ROOTFS_MNT}/usr/local/sbin"
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-apply-update.sh" << 'RK_APPLY_UPDATE'
#!/bin/bash
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
LOG_FILE="/var/log/rk-update.log"
PKG_FILE="/update/update.tar.gz"
STATE_DIR="/var/lib/rk-update"
STAMP_FILE="${STATE_DIR}/last_applied.sha256"
TMP_DIR=""
BOOT_WAS_MOUNTED=0
BOOT_PART_DEV=""
REBOOT_NEEDED=0

mkdir -p "${STATE_DIR}"
touch "${LOG_FILE}"
exec >> "${LOG_FILE}" 2>&1

echo "=== $(date -Iseconds) rk-apply-update: start ==="

cleanup() {
    if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
        rm -rf "${TMP_DIR}"
    fi
    if [ "${BOOT_WAS_MOUNTED}" -eq 1 ] && mountpoint -q /boot; then
        umount /boot || true
    fi
}
trap cleanup EXIT

if [ ! -f "${PKG_FILE}" ]; then
    echo "No package present at ${PKG_FILE}; nothing to do."
    exit 0
fi

PKG_SUM="$(sha256sum "${PKG_FILE}" | awk '{print $1}')"
if [ -f "${STAMP_FILE}" ] && grep -qx "${PKG_SUM}" "${STAMP_FILE}"; then
    DUP_FILE="/update/update-duplicate-$(date +%Y%m%d-%H%M%S).tar.gz"
    mv -f "${PKG_FILE}" "${DUP_FILE}" || true
    echo "Package ${PKG_SUM} already applied; archived duplicate as ${DUP_FILE}."
    exit 0
fi

TMP_DIR="$(mktemp -d /var/tmp/rk-update.XXXXXX)"
if ! tar -xzf "${PKG_FILE}" -C "${TMP_DIR}"; then
    echo "Failed to extract ${PKG_FILE}; leaving package untouched."
    exit 1
fi

if [ ! -d "${TMP_DIR}/rootfs" ] && [ ! -d "${TMP_DIR}/boot" ]; then
    echo "Package missing both rootfs/ and boot/ payloads."
    exit 1
fi

if [ -d "${TMP_DIR}/rootfs" ]; then
    echo "Applying rootfs payload..."
    tar -C "${TMP_DIR}/rootfs" -cpf - . | tar -C / -xpf -
fi

find_boot_partition() {
    local candidate root_part disk part_num boot_num

    for candidate in /dev/disk/by-partlabel/boot /dev/disk/by-label/BOOT /dev/disk/by-label/boot; do
        if [ -e "${candidate}" ]; then
            readlink -f "${candidate}"
            return 0
        fi
    done

    root_part="$(findmnt -n -o SOURCE / || true)"
    case "${root_part}" in
        /dev/mmcblk*p[0-9]*|/dev/nvme*n[0-9]p[0-9]*)
            disk="${root_part%p*}"
            part_num="${root_part##*p}"
            ;;
        /dev/sd[a-z][0-9]*|/dev/vd[a-z][0-9]*|/dev/xvd[a-z][0-9]*)
            disk="${root_part%[0-9]*}"
            part_num="${root_part##*[!0-9]}"
            ;;
        *)
            return 1
            ;;
    esac

    if [ -z "${disk}" ] || [ -z "${part_num}" ] || [ "${part_num}" -le 1 ]; then
        return 1
    fi
    boot_num=$((part_num - 1))

    case "${root_part}" in
        /dev/mmcblk*p[0-9]*|/dev/nvme*n[0-9]p[0-9]*)
            candidate="${disk}p${boot_num}"
            ;;
        *)
            candidate="${disk}${boot_num}"
            ;;
    esac

    [ -b "${candidate}" ] || return 1
    echo "${candidate}"
    return 0
}

if [ -d "${TMP_DIR}/boot" ]; then
    if ! mountpoint -q /boot; then
        BOOT_PART_DEV="$(find_boot_partition || true)"
        if [ -n "${BOOT_PART_DEV}" ]; then
            mkdir -p /boot
            if mount "${BOOT_PART_DEV}" /boot; then
                BOOT_WAS_MOUNTED=1
            else
                echo "Failed to mount boot partition ${BOOT_PART_DEV}; skipping boot payload."
            fi
        else
            echo "Unable to resolve boot partition; skipping boot payload."
        fi
    fi

    if mountpoint -q /boot; then
        echo "Applying boot payload..."
        mkdir -p /boot/extlinux
        if [ -f "${TMP_DIR}/boot/Image" ]; then
            install -m 0644 "${TMP_DIR}/boot/Image" /boot/Image
            REBOOT_NEEDED=1
        fi
        if [ -f "${TMP_DIR}/boot/rk3562.dtb" ]; then
            install -m 0644 "${TMP_DIR}/boot/rk3562.dtb" /boot/rk3562.dtb
            REBOOT_NEEDED=1
        fi
        if [ -f "${TMP_DIR}/boot/extlinux/extlinux.conf" ]; then
            install -m 0644 "${TMP_DIR}/boot/extlinux/extlinux.conf" /boot/extlinux/extlinux.conf
            REBOOT_NEEDED=1
        fi
        sync
    fi
fi

echo "${PKG_SUM}" > "${STAMP_FILE}"
chmod 0600 "${STAMP_FILE}" || true

APPLIED_FILE="/update/update-applied-$(date +%Y%m%d-%H%M%S).tar.gz"
mv -f "${PKG_FILE}" "${APPLIED_FILE}"
sync

echo "Update applied successfully; archived package as ${APPLIED_FILE}"

# Rootfs payload may replace binaries/libraries used by current boot. Reboot
# once after apply to ensure a clean and consistent runtime state.
REBOOT_NEEDED=1
if [ "${REBOOT_NEEDED}" -eq 1 ]; then
    echo "Rebooting to finalize update..."
    systemctl --no-block reboot
fi

exit 0
RK_APPLY_UPDATE
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-apply-update.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-apply-update.service" << 'RK_APPLY_UPDATE_UNIT'
[Unit]
Description=Apply offline update package from /update/update.tar.gz
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target lightdm.service graphical.target
ConditionPathExists=/usr/local/sbin/rk-apply-update.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rk-apply-update.sh
TimeoutSec=0

[Install]
WantedBy=multi-user.target
RK_APPLY_UPDATE_UNIT

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/rk-apply-update.service \
    "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/rk-apply-update.service"

mkdir -p "${ROOTFS_MNT}/update"
cat > "${ROOTFS_MNT}/update/README.txt" << 'RK_UPDATE_README'
Drop update package here as: /update/update.tar.gz
On next boot, rk-apply-update.service will apply it automatically.
RK_UPDATE_README
chroot "${ROOTFS_MNT}" chown -R chaos:chaos /update || true
chroot "${ROOTFS_MNT}" chmod 0775 /update || true

# 12. Expand rootfs service
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
echo "[*] Enabling serial console ttyS0..."
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
