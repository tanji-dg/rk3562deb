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
    python3 python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 \
    iproute2 iputils-ping dnsutils locales tzdata xfce4-power-manager upower brightnessctl rfkill \
    vainfo vdpauinfo \
    onboard wireless-regdb firmware-brcm80211 \
    gnome-themes-extra gnome-themes-extra-data adwaita-icon-theme

# Remove any Trixie apt source that may be left over from a previous failed
# build attempt.  Trixie packages require libc6 >= 2.38 which Bookworm does
# not have, so mixing the two repos breaks apt.
rm -f "${ROOTFS_MNT}/etc/apt/sources.list.d/trixie.list"
rm -f "${ROOTFS_MNT}/etc/apt/preferences.d/99-trixie-pin"
apt-get update -qq

# Wayland compositor stack — all from Debian Bookworm (no external repos).
# sway:     wlroots compositor, Wayland alternative to XFCE.
# swaybg:   wallpaper setter.
# wofi:     Wayland-native app launcher (replaces rofi/dmenu for touch).
# jq:       JSON parsing used by the rotation tray app (swaymsg output).
# Note: xwayland disabled — Mali glamor crashes under Xwayland same as X11.
# foot: Wayland-native terminal — required because xwayland is disabled so
# xfce4-terminal and other X11 terminals won't launch in this session.
apt-get install -y sway swaybg wofi jq foot mako-notifier

# wvkbd: Wayland-native on-screen keyboard (wlroots virtual-keyboard protocol).
# Replaces onboard (X11-only) in the Sway session.
# squeekboard: OSK that uses the input-method-v1 protocol — auto-shows when a
# text field gains focus in GTK/Qt apps.  Not in Bookworm stable; skip if absent.
for optional_pkg in wvkbd squeekboard; do
    if apt-get install -y "${optional_pkg}" 2>/dev/null; then
        echo "[+] Installed ${optional_pkg}"
    else
        echo "[!] ${optional_pkg} not in Bookworm — skipping"
    fi
done

# Optional Wayland tools — install if available in Bookworm, skip otherwise.
for optional_pkg in waybar grim slurp wlr-randr; do
    # Check exact Bookworm version to avoid accidentally pulling Trixie builds
    # that sneak in via a dirty apt cache.
    pkg_ver=$(apt-cache policy "${optional_pkg}" 2>/dev/null \
              | awk '/Candidate:/{print $2}')
    if [ -n "${pkg_ver}" ] && [ "${pkg_ver}" != "(none)" ]; then
        apt-get install -y "${optional_pkg}" || \
            echo "[!] Warning: ${optional_pkg} install failed, skipping"
    else
        echo "[!] Warning: ${optional_pkg} not available, skipping"
    fi
done

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

# Chromium is often smoother than Firefox on this board for YouTube playback.
if apt-cache show chromium >/dev/null 2>&1; then
    apt-get install -y chromium
else
    echo "[!] Warning: chromium package not available on current mirror."
fi

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
usermod -aG sudo,video,audio,netdev,render,input chaos

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
for helper in /usr/sbin/xfpm-power-backlight-helper \
              /usr/libexec/xfpm-power-backlight-helper \
              /usr/lib/xfce4/xfpm-power-backlight-helper; do
    if [ -e "${ROOTFS_MNT}${helper}" ]; then
        chroot "${ROOTFS_MNT}" chown root:root "${helper}" || true
        chroot "${ROOTFS_MNT}" chmod 4755 "${helper}" || true
    fi
done
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
mkdir -p "${ROOTFS_MNT}/usr/local/sbin"
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-backlight-setup.sh" << 'RK_BACKLIGHT_SETUP'
#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin

for backlight in /sys/class/backlight/*; do
    [ -d "${backlight}" ] || continue
    for attr in brightness bl_power; do
        file="${backlight}/${attr}"
        [ -e "${file}" ] || continue
        chgrp video "${file}" 2>/dev/null || true
        chmod g+w "${file}" 2>/dev/null || true
    done
done

exit 0
RK_BACKLIGHT_SETUP
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-backlight-setup.sh"

tee "${ROOTFS_MNT}/etc/udev/rules.d/90-backlight-permissions.rules" > /dev/null << 'UDEV_BACKLIGHT'
ACTION=="add|change", SUBSYSTEM=="backlight", RUN+="/usr/local/sbin/rk-backlight-setup.sh"
UDEV_BACKLIGHT

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-backlight-setup.service" << 'RK_BACKLIGHT_UNIT'
[Unit]
Description=Fix backlight permissions for desktop control
After=systemd-udev-settle.service local-fs.target
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rk-backlight-setup.sh

[Install]
WantedBy=multi-user.target
RK_BACKLIGHT_UNIT

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/rk-backlight-setup.service \
    "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/rk-backlight-setup.service"

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
    # glamor is enabled for 2D acceleration.
    # NOTE: xrandr --rotate crashes the X server with the Mali BSP blob because
    # glamor's shadow-framebuffer rotation path is incompatible with this driver.
    # Screen rotation on X11 is intentionally disabled in the tray app; use the
    # sway (Wayland) session for smooth, crash-free rotation instead.
    Option "AccelMethod" "glamor"
    Option "DRI" "3"
EndSection
XORG_GPU

# Build rockchip_drv_video.so (Rockchip VAAPI driver) inside the chroot.
# Sources: sujit-168/rk_hw_base (MPP+RGA middleware) and sujit-168/rk_vaapi_driver.
# librga prebuilt (aarch64) is pulled from airockchip/librga.
echo "[*] Building Rockchip VAAPI driver inside chroot..."
cat > "${ROOTFS_MNT}/tmp/build_vaapi.sh" << 'BUILD_VAAPI_EOF'
#!/bin/bash
set -e
cd /tmp

# Install librga prebuilt + headers from airockchip/librga
if [ ! -f /usr/lib/aarch64-linux-gnu/librga.so ]; then
    echo "[*] Fetching librga..."
    git clone --depth=1 https://github.com/airockchip/librga /tmp/librga_src
    cp /tmp/librga_src/libs/Linux/gcc-aarch64/librga.so /usr/lib/aarch64-linux-gnu/
    mkdir -p /usr/include/rga
    cp /tmp/librga_src/include/rga.h \
       /tmp/librga_src/include/RgaApi.h \
       /tmp/librga_src/include/RgaUtils.h \
       /tmp/librga_src/include/drmrga.h \
       /tmp/librga_src/include/GrallocOps.h \
       /tmp/librga_src/include/im2d_type.h \
       /usr/include/rga/
    ldconfig
    rm -rf /tmp/librga_src
fi

# Build rk_hw_base middleware
if [ ! -f /usr/lib/aarch64-linux-gnu/librk_hw_base.so ]; then
    echo "[*] Building rk_hw_base..."
    git clone --depth=1 https://github.com/sujit-168/rk_hw_base /tmp/rk_hw_base
    cd /tmp/rk_hw_base
    make
    cp lib/librk_hw_base.so /usr/lib/aarch64-linux-gnu/
    ldconfig
    cd /tmp
    rm -rf /tmp/rk_hw_base
fi

# Build rockchip VAAPI driver
if [ ! -f /usr/lib/aarch64-linux-gnu/dri/rockchip_drv_video.so ]; then
    echo "[*] Building rockchip_drv_video.so..."
    git clone --depth=1 https://github.com/sujit-168/rk_vaapi_driver /tmp/rk_vaapi_driver
    git clone --depth=1 https://github.com/sujit-168/rk_hw_base /tmp/rk_hw_base
    cd /tmp/rk_vaapi_driver
    make
    mkdir -p /usr/lib/aarch64-linux-gnu/dri
    cp lib/rockchip_drv_video.so /usr/lib/aarch64-linux-gnu/dri/
    ldconfig
    cd /tmp
    rm -rf /tmp/rk_vaapi_driver /tmp/rk_hw_base
fi

echo "[+] Rockchip VAAPI driver ready."
BUILD_VAAPI_EOF
chmod +x "${ROOTFS_MNT}/tmp/build_vaapi.sh"
chroot "${ROOTFS_MNT}" /tmp/build_vaapi.sh || echo "[!] Warning: VAAPI driver build failed; hardware video decode will not be available."
rm -f "${ROOTFS_MNT}/tmp/build_vaapi.sh"

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

# ── Custom Plymouth boot splash ────────────────────────────────────────────
# Replaces the plain black screen with a navy gradient, "RK3562 / Debian
# GNU/Linux" text, a faded divider line, and 5 pulsing dots.
# PNG assets are generated with pure Python (no PIL dependency).
echo "[*] Installing custom Plymouth boot splash..."
THEME_DIR="${ROOTFS_MNT}/usr/share/plymouth/themes/rkdebian"
mkdir -p "${THEME_DIR}"

# dot.png — 14×14 soft-edged white circle for the loading dots
python3 - "${THEME_DIR}/dot.png" << 'PYGEN'
import sys, zlib, struct

def write_png(path, w, h, rows_rgba):
    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xffffffff
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)
    raw = b''.join(b'\x00' + bytes(r) for r in rows_rgba)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 9)))
        f.write(chunk(b'IEND', b''))

W = H = 14
cx = cy = W / 2.0
r  = W / 2.0 - 1.0
rows = []
for y in range(H):
    row = []
    for x in range(W):
        d     = ((x + 0.5 - cx)**2 + (y + 0.5 - cy)**2)**0.5
        alpha = min(255, max(0, int((r - d) * 90)))
        row  += [255, 255, 255, alpha]
    rows.append(row)
write_png(sys.argv[1], W, H, rows)
PYGEN

# line.png — 280×2 white bar that fades at both edges (decorative divider)
python3 - "${THEME_DIR}/line.png" << 'PYGEN'
import sys, zlib, struct

def write_png(path, w, h, rows_rgba):
    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xffffffff
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)
    raw = b''.join(b'\x00' + bytes(r) for r in rows_rgba)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 9)))
        f.write(chunk(b'IEND', b''))

W, H = 280, 2
rows = []
for y in range(H):
    row = []
    for x in range(W):
        fade  = min(x, W - x) / 28.0
        alpha = min(255, int(55 * min(1.0, fade)))
        row  += [255, 255, 255, alpha]
    rows.append(row)
write_png(sys.argv[1], W, H, rows)
PYGEN

# Theme descriptor
cat > "${THEME_DIR}/rkdebian.plymouth" << 'PLYMOUTH_DESC'
[Plymouth Theme]
Name=rkdebian
Description=RK3562 Debian boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/rkdebian
ScriptFile=/usr/share/plymouth/themes/rkdebian/rkdebian.script
PLYMOUTH_DESC

# Animation script — runs inside Plymouth on the framebuffer
cat > "${THEME_DIR}/rkdebian.script" << 'PLYMOUTH_SCRIPT'
W = Window.GetWidth();
H = Window.GetHeight();

# Deep navy → near-black vertical gradient
Window.SetBackgroundTopColor(0.04, 0.07, 0.17);
Window.SetBackgroundBottomColor(0.01, 0.02, 0.07);

# ── Title ──────────────────────────────────────────────────────────────────
title = Image.Text("RK3562", 0.88, 0.93, 1.00, 1.0, "DejaVu Sans Bold 36");
title_spr = Sprite();
title_spr.SetImage(title);
title_spr.SetX(Math.Int(W / 2 - title.GetWidth()  / 2));
title_spr.SetY(Math.Int(H * 0.37));

# ── Subtitle ───────────────────────────────────────────────────────────────
sub = Image.Text("Debian GNU/Linux", 0.38, 0.55, 0.82, 1.0, "DejaVu Sans 15");
sub_spr = Sprite();
sub_spr.SetImage(sub);
sub_spr.SetX(Math.Int(W / 2 - sub.GetWidth() / 2));
sub_spr.SetY(title_spr.GetY() + title.GetHeight() + 10);

# ── Divider line ───────────────────────────────────────────────────────────
line_img = Image("line.png");
line_spr = Sprite();
line_spr.SetImage(line_img);
line_spr.SetX(Math.Int(W / 2 - line_img.GetWidth() / 2));
line_spr.SetY(sub_spr.GetY() + sub.GetHeight() + 22);
line_spr.SetOpacity(0.45);

# ── Pulsing dot loader (5 dots, wave ripple) ───────────────────────────────
N      = 5;
STEP   = 22;
DOT_Y  = Math.Int(H * 0.67);
ORIGIN = Math.Int(W / 2 - (N - 1) * STEP / 2);

dot_img = Image("dot.png");
for (i = 0; i < N; i++) {
    dot[i] = Sprite();
    dot[i].SetImage(dot_img);
    dot[i].SetX(ORIGIN + i * STEP - Math.Int(dot_img.GetWidth() / 2));
    dot[i].SetY(DOT_Y);
    dot[i].SetOpacity(0.15);
}

tick = 0;
fun animate() {
    tick++;
    peak = Math.Int(tick / 7) % N;
    for (i = 0; i < N; i++) {
        diff = i - peak;
        if (diff < 0) diff = -diff;
        opacity = 1.0 - diff * 0.25;
        if (opacity < 0.10) opacity = 0.10;
        dot[i].SetOpacity(opacity);
    }
}
Plymouth.SetRefreshFunction(animate);
PLYMOUTH_SCRIPT

# Activate the theme (overrides the 'spinner' set earlier in the chroot)
chroot "${ROOTFS_MNT}" plymouth-set-default-theme rkdebian 2>/dev/null || \
    echo "[!] Warning: could not set Plymouth theme; 'spinner' will be used"

# Add Chromium hardware acceleration flags.
# Mali G52 is on Chromium's GPU blocklist; --ignore-gpu-blocklist overrides.
# --use-gl=egl        : use EGL instead of GLX (required for Mali userspace)
# --enable-gpu-rasterization: GPU-accelerated 2D compositing
# --enable-zero-copy  : share DMA-BUF textures directly, avoids CPU readback
# VaapiVideoDecoder   : VAAPI path for H.264/VP9 hardware decode via MPP
# UseChromeOSDirectVideoDecoder is the CrOS-only decode path; disable it so
# the standard Linux VAAPI path is used instead.
echo "[*] Adding Chromium acceleration flags..."
mkdir -p "${ROOTFS_MNT}/etc/chromium.d"
if [ "${FF_VAAPI_ENABLED}" = "true" ]; then
    cat > "${ROOTFS_MNT}/etc/chromium.d/rk3562-hw-accel" << 'CHROMIUM_HW_FLAGS'
# RK3562 hardware acceleration — sourced by /usr/bin/chromium wrapper
export LIBVA_DRIVER_NAME=rockchip
export LIBVA_DRIVERS_PATH=/usr/lib/aarch64-linux-gnu/dri
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ozone-platform=wayland"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-angle=opengles"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ignore-gpu-blocklist"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-gpu-rasterization"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-zero-copy"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-features=UseChromeOSDirectVideoDecoder"
CHROMIUM_HW_FLAGS
else
    # No rockchip VAAPI driver — still force EGL and unblock GPU rasterization
    # so compositing uses Mali rather than llvmpipe.
    cat > "${ROOTFS_MNT}/etc/chromium.d/rk3562-hw-accel" << 'CHROMIUM_EGL_FLAGS'
# RK3562 EGL/GPU-raster only (no VAAPI driver found at build time)
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ozone-platform=wayland"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-angle=opengles"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ignore-gpu-blocklist"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-gpu-rasterization"
CHROMIUM_EGL_FLAGS
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
mkdir -p "${ROOTFS_MNT}/etc/lightdm"
# Write a complete, authoritative lightdm.conf so there is no ambiguity.
# - autologin starts Sway (Wayland) by default.
# - sessions-directory includes both xsessions (X11) and wayland-sessions.
cat > "${LIGHTDM_CONF}" << 'LIGHTDM_EOF'
[LightDM]
sessions-directory=/usr/share/lightdm/sessions:/usr/share/xsessions:/usr/share/wayland-sessions

[Seat:*]
autologin-user=chaos
autologin-user-timeout=0
autologin-session=sway
LIGHTDM_EOF

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
    <property name="power-button-action" type="uint" value="0"/>
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

# GTK/icon theme — Adwaita-dark GTK theme + Adwaita icon theme.
# Both ship in Debian Bookworm (gnome-themes-extra-data / adwaita-icon-theme).
# Adwaita v43 has clean SVG tray icons: battery levels, wifi bars, bluetooth,
# volume, brightness — all consistent and sharp.
mkdir -p "${ROOTFS_MNT}/home/chaos/.config/xfce4/xfconf/xfce-perchannel-xml"
cat > "${ROOTFS_MNT}/home/chaos/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml" << 'XSETTINGS_XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName"     type="string" value="Adwaita-dark"/>
    <property name="IconThemeName" type="string" value="Adwaita"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="CursorThemeName" type="string" value="Adwaita"/>
    <property name="CursorThemeSize" type="int"    value="24"/>
    <property name="FontName"        type="string" value="Sans 11"/>
    <property name="MonospaceFontName" type="string" value="Monospace 11"/>
  </property>
</channel>
XSETTINGS_XML
chroot "${ROOTFS_MNT}" chown chaos:chaos \
    /home/chaos/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml || true

# GTK3 settings file as fallback for apps that bypass xsettings.
mkdir -p "${ROOTFS_MNT}/home/chaos/.config/gtk-3.0"
cat > "${ROOTFS_MNT}/home/chaos/.config/gtk-3.0/settings.ini" << 'GTK3CFG'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
gtk-font-name=Sans 11
gtk-application-prefer-dark-theme=1
GTK3CFG
chroot "${ROOTFS_MNT}" chown -R chaos:chaos /home/chaos/.config/gtk-3.0 || true

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

# Wait for session DBus/panel startup to avoid autostart races.
for _ in $(seq 1 20); do
    dbus-send --session --dest=org.freedesktop.DBus --type=method_call \
      /org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1 && break
    sleep 1
done

panel_has_tray() {
    xfconf-query -c xfce4-panel -lv 2>/dev/null | awk '
    $1 ~ /^\/plugins\/plugin-[0-9]+$/ && ($2 == "systray" || $2 == "statusnotifier" || $2 == "indicator") { found=1 }
    END { exit(found ? 0 : 1) }'
}

ensure_panel() {
    if ! pgrep -x xfce4-panel >/dev/null 2>&1; then
        xfce4-panel >/dev/null 2>&1 &
        sleep 2
    fi
}

repair_panel_if_needed() {
    if ! command -v xfconf-query >/dev/null 2>&1; then
        return 0
    fi
    if panel_has_tray; then
        return 0
    fi
    # Reset panel config if tray plugins are missing; this restores defaults.
    pkill -x xfce4-panel >/dev/null 2>&1 || true
    rm -f "${HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
    rm -rf "${HOME}/.config/xfce4/panel"
    xfce4-panel >/dev/null 2>&1 &
    sleep 3
}

wait_for_system_bluez() {
    for _ in $(seq 1 30); do
        if dbus-send --system --dest=org.freedesktop.DBus --type=method_call \
          /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner string:org.bluez \
          2>/dev/null | grep -q "boolean true"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

controller_ready() {
    bluetoothctl list 2>/dev/null | grep -q '^Controller '
}

prepare_bluetooth() {
    if command -v rfkill >/dev/null 2>&1; then
        rfkill unblock all >/dev/null 2>&1 || true
    fi
    if command -v bluetoothctl >/dev/null 2>&1; then
        wait_for_system_bluez || true
        for _ in $(seq 1 15); do
            controller_ready && break
            sleep 1
        done
        printf 'power on\nquit\n' | bluetoothctl >/dev/null 2>&1 || true
    fi
}

ensure_panel
repair_panel_if_needed
prepare_bluetooth

# Kill duplicates from package autostart entries, then keep retrying in case
# the applet exits before the controller is ready.
pkill -x blueman-applet >/dev/null 2>&1 || true
sleep 1
while :; do
    if blueman-applet >/dev/null 2>&1; then
        :
    fi
    sleep 3
    prepare_bluetooth
done
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

# Power key: short press = suspend, long press = poweroff
mkdir -p "${ROOTFS_MNT}/etc/systemd/logind.conf.d"
cat > "${ROOTFS_MNT}/etc/systemd/logind.conf.d/power-button.conf" << 'LOGIND'
[Login]
HandlePowerKey=suspend
HandlePowerKeyLongPress=poweroff
LOGIND

echo "[*] Adding polkit rule for backlight control..."
mkdir -p "${ROOTFS_MNT}/etc/polkit-1/rules.d"
cat > "${ROOTFS_MNT}/etc/polkit-1/rules.d/49-backlight.rules" << 'BACKLIGHT_POLKIT'
polkit.addRule(function(action, subject) {
    var backlightAction =
        action.id == "org.freedesktop.login1.set-backlight" ||
        action.id == "org.xfce.power.backlight-helper";

    if (!backlightAction) {
        return;
    }

    if (subject.isInGroup("video")) {
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

# If a previous pass marked ready but controller is gone, retry recovery.
if [ -e "${READY_FILE}" ] && controller_ready; then
    exit 0
fi
rm -f "${READY_FILE}" 2>/dev/null || true

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

# Keep boot behavior stable: avoid force-unloading/restarting BT from a
# background helper because that can make the controller disappear mid-boot.
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

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-bluetooth-recover.timer" << 'RK_BT_RECOVER_TIMER'
[Unit]
Description=Retry Seekwave Bluetooth recovery until controller appears

[Timer]
OnBootSec=90s
OnUnitActiveSec=5min
AccuracySec=1s
Unit=rk-bluetooth-recover.service

[Install]
WantedBy=timers.target
RK_BT_RECOVER_TIMER

# Do not auto-enable recovery service/timer by default. They can still be
# started manually for debugging:
#   systemctl start rk-bluetooth-recover.service
mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
mkdir -p "${ROOTFS_MNT}/etc/systemd/system/timers.target.wants"
rm -f "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/rk-bluetooth-recover.service"
rm -f "${ROOTFS_MNT}/etc/systemd/system/timers.target.wants/rk-bluetooth-recover.timer"

# Harden bluetooth.service startup ordering for Seekwave BT.
echo "[*] Installing Bluetooth service override..."
mkdir -p "${ROOTFS_MNT}/etc/systemd/system/bluetooth.service.d"
cat > "${ROOTFS_MNT}/etc/systemd/system/bluetooth.service.d/rk-skwbt.conf" << 'RK_BT_OVERRIDE'
[Unit]
# Drop Debian's default ConditionPathIsDirectory=/sys/class/bluetooth so
# bluetoothd can start and request module bring-up on first boot.
ConditionPathIsDirectory=
After=systemd-modules-load.service rk-unblock-rfkill.service
Wants=rk-unblock-rfkill.service

[Service]
ExecStartPre=/bin/sh -c '/usr/sbin/modprobe skwbt >/dev/null 2>&1 || true; for i in $(seq 1 20); do [ -d /sys/class/bluetooth ] && exit 0; sleep 1; done; exit 0'
ExecStartPre=/bin/sh -c '/usr/sbin/rfkill unblock all >/dev/null 2>&1 || true'
ExecStartPost=/bin/sh -c 'printf "power on\nquit\n" | /usr/bin/bluetoothctl >/dev/null 2>&1 || true'
Restart=on-failure
RestartSec=2
RK_BT_OVERRIDE

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/bluetooth.service \
    "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/bluetooth.service"

# Screen rotation tray icon — manual rotation selector with optional
# accelerometer auto-rotate.  Replaces the old rk-autorotate.service daemon.
echo "[*] Installing screen-rotation tray applet..."

# udev rule: let the "video" group read/write the accelerometer device so the
# tray app (running as the desktop user) can poll it without root.
cat > "${ROOTFS_MNT}/etc/udev/rules.d/91-accelerometer.rules" << 'ACCEL_UDEV'
KERNEL=="mma8452_daemon", MODE="0660", GROUP="video"
ACCEL_UDEV

mkdir -p "${ROOTFS_MNT}/usr/local/bin"
cat > "${ROOTFS_MNT}/usr/local/bin/rk-screen-rotate.py" << 'RK_SCREEN_ROTATE'
#!/usr/bin/env python3
"""System-tray applet for screen rotation on RK3562 tablet.

Works in both X11 (XFCE) and Wayland (labwc) sessions.

Under X11:  uses xrandr for display rotation and xinput for touch mapping.
Under Wayland: uses wlr-randr for display rotation; the compositor
               (wlroots/labwc) automatically remaps touch coordinates, so
               no xinput step is needed.
"""

import array
import fcntl
import os
import re
import subprocess
import threading
import time

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3 as AppIndicator3  # noqa: E402
from gi.repository import GLib, Gtk  # noqa: E402

# ---------------------------------------------------------------------------
# Session detection
# ---------------------------------------------------------------------------
IS_WAYLAND = os.environ.get("XDG_SESSION_TYPE", "") == "wayland"

# ---------------------------------------------------------------------------
# Accelerometer constants
# ---------------------------------------------------------------------------
SENSOR_DEV = "/dev/mma8452_daemon"
GSENSOR_IOCTL_START = 0x6103
GSENSOR_IOCTL_APP_SET_RATE = 0x40026110
GSENSOR_IOCTL_GETDATA = 0x800D6108
POLL_SECONDS = 0.5
THRESHOLD = 6000
STABLE_SAMPLES = 3

# ---------------------------------------------------------------------------
# Rotation helpers
# ---------------------------------------------------------------------------
ORIENTATIONS = ["normal", "left", "right", "inverted"]

LABELS = {
    "normal":   "Normal (Portrait)",
    "left":     "Left (Landscape)",
    "right":    "Right (Landscape)",
    "inverted": "Inverted (Portrait)",
}

# xinput Coordinate Transformation Matrix — X11 only (9 elements)
MATRICES = {
    "normal":   [1,  0, 0,  0,  1, 0, 0, 0, 1],
    "left":     [0, -1, 1,  1,  0, 0, 0, 0, 1],
    "right":    [0,  1, 0, -1,  0, 1, 0, 0, 1],
    "inverted": [-1, 0, 1,  0, -1, 1, 0, 0, 1],
}

# wlr transform names — Wayland only
WL_TRANSFORMS = {
    "normal":   "normal",
    "left":     "270",
    "right":    "90",
    "inverted": "180",
}

# libinput calibration matrices for Wayland (6 elements: a b c d e f)
# map_to_output doesn't update touch coords on this platform so we set manually.
# Each matrix is the inverse of the output transform applied to [0,1] touch coords.
WL_TOUCH_MATRICES = {
    "normal":   [1,  0, 0,  0,  1, 0],   # identity
    "right":    [0,  1, 0, -1,  0, 1],   # output transform 90  (CCW)
    "left":     [0, -1, 1,  1,  0, 0],   # output transform 270 (CW)
    "inverted": [-1, 0, 1,  0, -1, 1],   # output transform 180
}

ICON_DEFAULT = "video-display"


def _sway_output():
    """Return the name of the first active sway output via swaymsg JSON."""
    res = subprocess.run(
        ["swaymsg", "-t", "get_outputs"], text=True, capture_output=True
    )
    if res.returncode != 0:
        return None
    try:
        import json
        outputs = json.loads(res.stdout)
        for o in outputs:
            if o.get("active"):
                return o["name"]
        if outputs:
            return outputs[0]["name"]
    except Exception:
        pass
    return None


def _x11_connected_output():
    """Return the name of the first connected xrandr output."""
    res = subprocess.run(["xrandr", "--query"], text=True, capture_output=True)
    if res.returncode != 0:
        return None
    outputs = []
    for line in res.stdout.splitlines():
        if " connected" in line and "disconnected" not in line:
            outputs.append(line.split()[0])
    if not outputs:
        return None
    for prefix in ("DSI", "eDP", "LVDS"):
        for out in outputs:
            if out.startswith(prefix):
                return out
    return outputs[0]


def _x11_touchscreen_devices():
    """Return list of xinput device names matching the touchscreen."""
    res = subprocess.run(
        ["xinput", "list", "--name-only"], text=True, capture_output=True
    )
    if res.returncode != 0:
        return []
    devs = []
    for line in res.stdout.splitlines():
        name = line.strip()
        if re.search(r"(gsl3673|touchscreen|touch)", name, re.IGNORECASE):
            devs.append(name)
    return devs


def _sway_touch_identifier():
    """Return the sway input identifier for the first touch device."""
    res = subprocess.run(
        ["swaymsg", "-t", "get_inputs"], text=True, capture_output=True
    )
    if res.returncode != 0:
        return None
    try:
        import json
        for dev in json.loads(res.stdout):
            if dev.get("type") == "touch":
                return dev["identifier"]
    except Exception:
        pass
    return None


def apply_orientation(orientation):
    """Rotate display and update touch mapping for the current session type."""
    if IS_WAYLAND:
        output = _sway_output()
        if not output:
            return False
        # Rotate the output
        res = subprocess.run(
            ["swaymsg", "output", output, "transform",
             WL_TRANSFORMS[orientation]],
            capture_output=True,
        )
        if res.returncode != 0:
            return False
        # map_to_output doesn't update touch coords on this platform;
        # set the libinput calibration matrix manually.
        touch_id = _sway_touch_identifier()
        if touch_id:
            mat = WL_TOUCH_MATRICES[orientation]
            subprocess.run(
                ["swaymsg", "--", "input", touch_id, "calibration_matrix",
                 " ".join(str(v) for v in mat)],
                capture_output=True,
            )
        return True
    else:
        # xrandr --rotate (including --rotate normal) crashes the X server with
        # the Mali BSP glamor driver.  Do not call xrandr at all under X11.
        # Only update the xinput touch matrix for "normal" to keep calibration.
        if orientation != "normal":
            return False
        matrix = MATRICES["normal"]
        for dev in _x11_touchscreen_devices():
            subprocess.run(
                ["xinput", "set-prop", dev,
                 "Coordinate Transformation Matrix",
                 *(str(v) for v in matrix)],
                capture_output=True,
            )
        return True


# ---------------------------------------------------------------------------
# Accelerometer reader (runs in a background thread)
# ---------------------------------------------------------------------------
class AccelReader:
    """Polls the MMA8452 accelerometer and calls *callback(orientation)*
    on the GLib main-loop when a stable orientation change is detected."""

    def __init__(self, callback):
        self._callback = callback
        self._stop = threading.Event()
        self._thread = None

    def start(self):
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)
            self._thread = None

    @property
    def running(self):
        return self._thread is not None and self._thread.is_alive()

    @staticmethod
    def _open_sensor():
        fd = os.open(SENSOR_DEV, os.O_RDWR | os.O_CLOEXEC)
        fcntl.ioctl(fd, GSENSOR_IOCTL_START, 0)
        rate = array.array("h", [20])
        fcntl.ioctl(fd, GSENSOR_IOCTL_APP_SET_RATE, rate, True)
        return fd

    @staticmethod
    def _read_axis(fd):
        vals = array.array("i", [0, 0, 0])
        fcntl.ioctl(fd, GSENSOR_IOCTL_GETDATA, vals, True)
        return vals[0], vals[1], vals[2]

    @staticmethod
    def _detect(x, y):
        ax, ay = abs(x), abs(y)
        if ax < THRESHOLD and ay < THRESHOLD:
            return None
        if ax >= ay:
            return "left" if x > 0 else "right"
        return "inverted" if y > 0 else "normal"

    def _run(self):
        fd = None
        pending = None
        pending_count = 0
        while not self._stop.is_set():
            try:
                if fd is None:
                    if not os.path.exists(SENSOR_DEV):
                        time.sleep(1.0)
                        continue
                    fd = self._open_sensor()
                x, y, _ = self._read_axis(fd)
                orient = self._detect(x, y)
                if orient is not None:
                    if orient == pending:
                        pending_count += 1
                    else:
                        pending = orient
                        pending_count = 1
                    if pending_count >= STABLE_SAMPLES:
                        GLib.idle_add(self._callback, orient)
                        pending_count = 0
                time.sleep(POLL_SECONDS)
            except Exception:
                if fd is not None:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    fd = None
                time.sleep(1.0)
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Tray applet
# ---------------------------------------------------------------------------
class RotateTray:
    def __init__(self):
        self._current = "normal"
        self._auto = False
        self._accel = AccelReader(self._on_accel_orient)

        self._indicator = AppIndicator3.Indicator.new(
            "rk-screen-rotate",
            ICON_DEFAULT,
            AppIndicator3.IndicatorCategory.HARDWARE,
        )
        self._indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        self._indicator.set_title("Screen Rotation")
        self._build_menu()

    def _build_menu(self):
        menu = Gtk.Menu()

        self._auto_item = Gtk.CheckMenuItem(label="Auto-rotate")
        self._auto_item.set_active(self._auto)
        if not IS_WAYLAND:
            self._auto_item.set_sensitive(False)
        self._auto_item.connect("toggled", self._on_auto_toggled)
        menu.append(self._auto_item)

        menu.append(Gtk.SeparatorMenuItem())

        if not IS_WAYLAND:
            note = Gtk.MenuItem(
                label="⚠ Rotation only works in sway (Wayland)"
            )
            note.set_sensitive(False)
            menu.append(note)

        self._orient_items = {}
        group = None
        for orient in ORIENTATIONS:
            if group is None:
                item = Gtk.RadioMenuItem(label=LABELS[orient])
                group = item
            else:
                item = Gtk.RadioMenuItem.new_with_label_from_widget(
                    group, LABELS[orient]
                )
            if orient == self._current:
                item.set_active(True)
            # Disable non-normal options on X11 — xrandr --rotate crashes Xorg
            if not IS_WAYLAND and orient != "normal":
                item.set_sensitive(False)
            item.connect("toggled", self._on_orient_toggled, orient)
            self._orient_items[orient] = item
            menu.append(item)

        menu.append(Gtk.SeparatorMenuItem())

        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", self._on_quit)
        menu.append(quit_item)

        menu.show_all()
        self._indicator.set_menu(menu)

    def _on_orient_toggled(self, item, orient):
        if not item.get_active():
            return
        if orient == self._current:
            return
        if self._auto:
            self._auto = False
            self._accel.stop()
            self._auto_item.set_active(False)
        self._apply(orient)

    def _on_auto_toggled(self, item):
        self._auto = item.get_active()
        if self._auto:
            self._accel.start()
        else:
            self._accel.stop()

    def _on_accel_orient(self, orient):
        if not self._auto:
            return
        if orient == self._current:
            return
        self._apply(orient)
        item = self._orient_items.get(orient)
        if item and not item.get_active():
            item.set_active(True)

    def _on_quit(self, _item):
        self._accel.stop()
        Gtk.main_quit()

    def _apply(self, orient):
        if apply_orientation(orient):
            self._current = orient

    def run(self):
        Gtk.main()


def main():
    auto_start = os.path.exists(SENSOR_DEV) and os.access(
        SENSOR_DEV, os.R_OK | os.W_OK
    )
    app = RotateTray()
    if auto_start:
        app._auto = True
        app._auto_item.set_active(True)
        app._accel.start()
    app.run()


if __name__ == "__main__":
    main()
RK_SCREEN_ROTATE
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-screen-rotate.py"

# Autostart the tray applet inside the XFCE session.
mkdir -p "${ROOTFS_MNT}/etc/xdg/autostart"
cat > "${ROOTFS_MNT}/etc/xdg/autostart/rk-screen-rotate.desktop" << 'RK_ROTATE_DESKTOP'
[Desktop Entry]
Type=Application
Name=Screen Rotation
Comment=Tray applet for screen rotation control
Exec=/usr/local/bin/rk-screen-rotate.py
Icon=video-display
X-GNOME-Autostart-enabled=true
OnlyShowIn=XFCE;
RK_ROTATE_DESKTOP

# ── Wayland / sway alternate session ─────────────────────────────────────────
# Everything below is isolated to the sway session.  The XFCE/X11 session is
# completely unaffected: LightDM autologins to xfce by default; sway config
# lives in its own directory; all autostart entries use OnlyShowIn=sway.
# sway is in Debian Bookworm (v1.7.2) — no external repos needed.
echo "[*] Installing sway Wayland session..."

# Session wrapper — sets env vars sway needs on a BSP Rockchip kernel.
mkdir -p "${ROOTFS_MNT}/usr/local/bin"
cat > "${ROOTFS_MNT}/usr/local/bin/rk-sway-session.sh" << 'RK_SWAY_SESSION'
#!/bin/sh
# No hardware cursor plane on RK3562 Esmart-only VOP2
export WLR_NO_HARDWARE_CURSORS=1
# Use DRM/KMS backend (explicit, in case DISPLAY is set from su/ssh)
export WLR_BACKENDS=drm,libinput
# Force libseat to use logind for device access (input group not required)
export LIBSEAT_BACKEND=logind
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=sway
export GDK_BACKEND=wayland,x11
export QT_QPA_PLATFORM="wayland;xcb"
export SDL_VIDEODRIVER=wayland
export MOZ_ENABLE_WAYLAND=1
export MOZ_DISABLE_RDD_SANDBOX=1
export _JAVA_AWT_WM_NONREPARENTING=1
exec sway
RK_SWAY_SESSION
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-sway-session.sh"

# LightDM Wayland session entry — overrides the one shipped by the sway
# package so our wrapper script is used (for the env vars above).
mkdir -p "${ROOTFS_MNT}/usr/share/wayland-sessions"
cat > "${ROOTFS_MNT}/usr/share/wayland-sessions/sway.desktop" << 'SWAY_SESSION'
[Desktop Entry]
Name=sway (Wayland)
Comment=sway wlroots Wayland compositor
Exec=/usr/local/bin/rk-sway-session.sh
Type=Application
DesktopNames=sway
SWAY_SESSION

# sway configuration
mkdir -p "${ROOTFS_MNT}/home/chaos/.config/sway"
cat > "${ROOTFS_MNT}/home/chaos/.config/sway/config" << 'SWAY_CFG'
### Variables
set $mod Mod4
set $term foot
set $menu /usr/local/bin/rk-launcher.sh
set $kbd  /usr/local/bin/rk-keyboard-toggle.sh

### Disable Xwayland — Mali glamor crashes under Xwayland (same as X11)
xwayland disable

### Output — 800×1280 portrait panel; default landscape = 270° CW
# rk-screen-rotate.py will update this at runtime; setting it here avoids
# the portrait flash while the tray applet starts.
output DSI-1 transform 270
output * bg #1a1b26 solid_color

### Input
input type:touchscreen {
    tap enabled
    natural_scroll disabled
    map_to_output DSI-1
}

### Font and borders
font pango:DejaVu Sans 13
default_border pixel 2
default_floating_border pixel 2
smart_borders on
gaps inner 6
gaps outer 0

### Focus highlight colors (Tokyo Night palette)
client.focused          #7aa2f7 #24283b #c0caf5 #7aa2f7 #7aa2f7
client.unfocused        #292e42 #1a1b26 #545c7e #292e42 #292e42
client.focused_inactive #292e42 #1a1b26 #c0caf5 #292e42 #292e42
client.urgent           #f7768e #1a1b26 #f7768e #f7768e #f7768e

### Default layout: tabbed — apps fill the screen, switch via tab bar at top
workspace_layout tabbed

### Window rules — dialogs float centered, most apps tile
for_window [window_role="dialog"]           floating enable, border pixel 2, move position center
for_window [window_role="pop-up"]           floating enable, border pixel 2, move position center
for_window [app_id="pavucontrol"]           floating enable, resize set 640 420, move position center
for_window [app_id="nm-connection-editor"]  floating enable, resize set 640 520, move position center
for_window [app_id=".*[Ss]ettings.*"]       floating enable, move position center
for_window [title=".*[Pp]references.*"]     floating enable, move position center

### Key bindings
bindsym $mod+Return exec $term
bindsym $mod+d      exec $menu
bindsym $mod+k      exec $kbd
bindsym $mod+q      kill
bindsym $mod+f      fullscreen toggle
bindsym $mod+Tab    focus next sibling
bindsym $mod+Shift+Tab focus prev sibling
bindsym $mod+Shift+e exec swaymsg exit
bindsym XF86PowerOff exec /usr/local/bin/rk-power-menu.sh

### Panel
bar {
    swaybar_command waybar
}

### Autostart
exec /usr/local/bin/rk-screen-rotate.py
exec nm-applet --indicator
exec mako
# squeekboard: auto-shows when a text field gains focus (input-method protocol).
# No-op if not installed.
exec sh -c 'command -v squeekboard >/dev/null 2>&1 && exec squeekboard'
SWAY_CFG

# Touch-friendly power dialog — GTK3, icon buttons, no search bar, no scroll.
# Replaces the wofi dmenu approach which couldn't reliably hide its search bar.
cat > "${ROOTFS_MNT}/usr/local/bin/rk-power-dialog.py" << 'RK_POWER_DIALOG'
#!/usr/bin/env python3
"""Touch-friendly Wayland power dialog — icon buttons, no search."""
import gi, subprocess
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk

CSS = b"""
window.power-dialog {
    background-color: #1c1c1e;
    border-radius: 14px;
    border: 1px solid #3a3a3c;
}
.btn-action {
    background: rgba(255,255,255,0.07);
    color: #f2f2f7;
    border-radius: 10px;
    border: 1px solid rgba(255,255,255,0.12);
    padding: 16px 10px;
    font-size: 13px;
    min-width: 120px;
    min-height: 110px;
}
.btn-action:hover  { background: rgba(255,255,255,0.15); }
.btn-action:active { background: rgba(255,255,255,0.25); }
.btn-cancel {
    background: rgba(255,59,48,0.15);
    color: #ff453a;
    border-radius: 10px;
    border: 1px solid rgba(255,59,48,0.28);
    padding: 12px;
    font-size: 13px;
}
.btn-cancel:hover { background: rgba(255,59,48,0.25); }
.title-label { color: #ebebf5; font-size: 15px; font-weight: bold; }
"""

ACTIONS = [
    ("system-shutdown", "Shut Down", ["systemctl", "poweroff"]),
    ("system-reboot",   "Restart",   ["systemctl", "reboot"]),
    ("system-log-out",  "Log Out",   ["swaymsg",   "exit"]),
]

class PowerDialog(Gtk.Window):
    def __init__(self):
        super().__init__()
        self.get_style_context().add_class("power-dialog")
        self.set_title("Power")
        self.set_default_size(480, 300)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_resizable(False)
        self.set_type_hint(Gdk.WindowTypeHint.DIALOG)

        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(
            self.get_screen(), provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        outer.set_margin_top(24)
        outer.set_margin_bottom(20)
        outer.set_margin_start(20)
        outer.set_margin_end(20)
        self.add(outer)

        title = Gtk.Label(label="Power Options")
        title.get_style_context().add_class("title-label")
        outer.pack_start(title, False, False, 0)

        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        row.set_homogeneous(True)
        outer.pack_start(row, True, True, 0)

        for icon_name, label_text, cmd in ACTIONS:
            btn = Gtk.Button()
            btn.get_style_context().add_class("btn-action")
            content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            content.set_halign(Gtk.Align.CENTER)
            icon = Gtk.Image.new_from_icon_name(icon_name, Gtk.IconSize.DIALOG)
            lbl = Gtk.Label(label=label_text)
            content.pack_start(icon, False, False, 0)
            content.pack_start(lbl, False, False, 0)
            btn.add(content)
            btn.connect("clicked", self.run_cmd, cmd)
            row.pack_start(btn, True, True, 0)

        cancel = Gtk.Button(label="Cancel")
        cancel.get_style_context().add_class("btn-cancel")
        cancel.connect("clicked", lambda *_: Gtk.main_quit())
        outer.pack_start(cancel, False, False, 0)

        self.connect("delete-event", lambda *_: Gtk.main_quit())
        self.connect("key-press-event", self.on_key)

    def on_key(self, w, event):
        if event.keyval == Gdk.KEY_Escape:
            Gtk.main_quit()

    def run_cmd(self, btn, cmd):
        subprocess.Popen(cmd)
        Gtk.main_quit()

win = PowerDialog()
win.show_all()
Gtk.main()
RK_POWER_DIALOG
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-power-dialog.py"

# rk-power-menu.sh now just launches the GTK dialog (kills any leftover first).
cat > "${ROOTFS_MNT}/usr/local/bin/rk-power-menu.sh" << 'RK_POWER_MENU'
#!/bin/sh
pkill -f rk-power-dialog.py 2>/dev/null || true
sleep 0.05
exec /usr/local/bin/rk-power-dialog.py
RK_POWER_MENU
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-power-menu.sh"

# Single-instance app launcher — kills any existing wofi before opening a new one
# so multiple rapid taps don't stack a dozen launcher windows.
cat > "${ROOTFS_MNT}/usr/local/bin/rk-launcher.sh" << 'RK_LAUNCHER'
#!/bin/sh
if pgrep -x wofi > /dev/null 2>&1; then
    pkill -x wofi
    exit 0
fi
exec wofi --show drun \
          --width 800 --height 1280 \
          --cache-file=/dev/null \
          --no-actions \
          --allow-images \
          --columns 4 \
          2>/dev/null
RK_LAUNCHER
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-launcher.sh"

# wvkbd toggle — shows/hides the on-screen keyboard at the bottom of the screen.
# wvkbd-mobintl is the standard mobile-international layout binary.
cat > "${ROOTFS_MNT}/usr/local/bin/rk-keyboard-toggle.sh" << 'RK_KBD_TOGGLE'
#!/bin/sh
KBD_BIN=""
for b in wvkbd-mobintl wvkbd; do
    command -v "$b" > /dev/null 2>&1 && KBD_BIN="$b" && break
done
[ -z "$KBD_BIN" ] && exit 0

if pgrep -x "$KBD_BIN" > /dev/null 2>&1; then
    pkill -x "$KBD_BIN"
else
    exec "$KBD_BIN" --landscape-layers full,special -H 260 -L 300 &
fi
RK_KBD_TOGGLE
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-keyboard-toggle.sh"

# Panel launcher: prefers waybar, falls back to swaybar (already in sway config)
cat > "${ROOTFS_MNT}/usr/local/bin/rk-sway-panel.sh" << 'RK_SWAY_PANEL'
#!/bin/sh
# Kill any existing panel instances before (re)starting
pkill -x waybar 2>/dev/null || true
if command -v waybar >/dev/null 2>&1; then
    exec waybar
fi
# waybar not available — swaybar is handled by the bar{} block in sway config
RK_SWAY_PANEL
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-sway-panel.sh"

# Simple swaybar status script (clock + battery)
cat > "${ROOTFS_MNT}/usr/local/bin/rk-swaybar-status.sh" << 'RK_SWAY_STATUS'
#!/bin/sh
while true; do
    BAT_CAP=""
    BAT_FILE="/sys/class/power_supply/rk817-battery/capacity"
    STATUS_FILE="/sys/class/power_supply/rk817-battery/status"
    if [ -r "${BAT_FILE}" ]; then
        CAP=$(cat "${BAT_FILE}")
        STS=$(cat "${STATUS_FILE}" 2>/dev/null || echo "")
        case "${STS}" in
            Charging)    BAT_CAP=" ${CAP}%+" ;;
            Discharging) BAT_CAP=" ${CAP}%" ;;
            Full)        BAT_CAP=" Full" ;;
            *)           BAT_CAP=" ${CAP}%" ;;
        esac
    fi
    echo "$(date +'%a %d %b  %H:%M')${BAT_CAP}"
    sleep 30
done
RK_SWAY_STATUS
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-swaybar-status.sh"

# waybar configuration (used when waybar is installed)
mkdir -p "${ROOTFS_MNT}/home/chaos/.config/waybar"
cat > "${ROOTFS_MNT}/home/chaos/.config/waybar/config" << 'WAYBAR_CFG'
{
    "layer": "top",
    "position": "top",
    "height": 52,
    "spacing": 0,
    "modules-left": ["custom/apps", "custom/kbd", "custom/close"],
    "modules-center": ["clock"],
    "modules-right": ["tray", "backlight", "pulseaudio", "battery", "network", "custom/power"],

    "custom/apps": {
        "format": "Apps",
        "on-click": "/usr/local/bin/rk-launcher.sh",
        "on-click-touch": "/usr/local/bin/rk-launcher.sh",
        "tooltip": false,
        "min-width": 70
    },
    "custom/kbd": {
        "format": "kbd",
        "on-click": "/usr/local/bin/rk-keyboard-toggle.sh",
        "on-click-touch": "/usr/local/bin/rk-keyboard-toggle.sh",
        "tooltip": false,
        "min-width": 60
    },
    "custom/close": {
        "format": "Close",
        "on-click": "swaymsg kill",
        "on-click-touch": "swaymsg kill",
        "tooltip": false,
        "min-width": 70
    },
    "clock": {
        "format": "{:%H:%M}",
        "format-alt": "{:%a %d %b  %H:%M}",
        "tooltip-format": "{:%A, %d %B %Y}"
    },
    "tray": {
        "spacing": 10,
        "icon-size": 22
    },
    "backlight": {
        "format": "{percent}%☀",
        "on-scroll-up": "brightnessctl set +5%",
        "on-scroll-down": "brightnessctl set 5%-",
        "on-click": "brightnessctl set +10%",
        "tooltip": false
    },
    "battery": {
        "bat": "rk817-battery",
        "interval": 30,
        "format": "{capacity}%{icon}",
        "format-charging": "{capacity}%+",
        "format-icons": ["▁", "▃", "▅", "▇", "█"],
        "states": { "warning": 20, "critical": 10 },
        "tooltip": false
    },
    "network": {
        "interval": 15,
        "format-wifi": "{essid}",
        "format-disconnected": "no wifi",
        "tooltip": false
    },
    "pulseaudio": {
        "format": "{volume}%♪",
        "format-muted": "mute",
        "on-click": "pavucontrol",
        "on-click-touch": "pavucontrol",
        "tooltip": false
    },
    "custom/power": {
        "format": "pwr",
        "on-click": "/usr/local/bin/rk-power-menu.sh",
        "on-click-touch": "/usr/local/bin/rk-power-menu.sh",
        "tooltip": false
    }
}
WAYBAR_CFG

cat > "${ROOTFS_MNT}/home/chaos/.config/waybar/style.css" << 'WAYBAR_CSS'
* {
    font-family: "DejaVu Sans", sans-serif;
    font-size: 13px;
    min-height: 0;
    border: none;
    border-radius: 0;
    padding: 0;
    margin: 0;
}

window#waybar {
    background-color: #1a1b26;
    color: #c0caf5;
    border-bottom: 2px solid #3b4261;
}

/* Right side modules */
#clock, #tray, #backlight, #pulseaudio, #battery, #network, #custom-power {
    padding: 0 10px;
    color: #c0caf5;
}

/* Left action buttons — pill style, clearly separated */
#custom-apps, #custom-kbd, #custom-close {
    padding: 6px 16px;
    margin: 6px 4px;
    border-radius: 8px;
    font-weight: bold;
    font-size: 14px;
}

#custom-apps  { background-color: #3d59a1; color: #c0caf5; }
#custom-kbd   { background-color: #33635c; color: #c0caf5; }
#custom-close { background-color: #8c3a4a; color: #c0caf5; }

#custom-apps:hover  { background-color: #4e6ab5; }
#custom-kbd:hover   { background-color: #3d7a72; }
#custom-close:hover { background-color: #a34555; }

/* Center clock */
#clock {
    font-size: 15px;
    font-weight: bold;
    color: #e0af68;
}

#battery         { color: #9ece6a; }
#battery.warning { color: #e0af68; }
#battery.critical{ color: #f7768e; }
#battery.charging{ color: #73daca; }
#network         { color: #7dcfff; }
#pulseaudio      { color: #bb9af7; }
#backlight       { color: #b4f9f8; }
#custom-power    { color: #f7768e; font-weight: bold; }
WAYBAR_CSS

# wofi app launcher config — touch-friendly sizing
mkdir -p "${ROOTFS_MNT}/home/chaos/.config/wofi"
cat > "${ROOTFS_MNT}/home/chaos/.config/wofi/style.css" << 'WOFI_CSS'
window {
    background-color: #1a1b26;
    font-family: "DejaVu Sans", sans-serif;
}
#input {
    background-color: #24283b;
    color: #c0caf5;
    border: 1px solid #3b4261;
    border-radius: 8px;
    padding: 14px 16px;
    font-size: 18px;
    margin: 12px;
    caret-color: #7aa2f7;
}
#scroll {
    margin: 0 6px 6px 6px;
}
#inner-box {
    background-color: transparent;
}
#outer-box {
    background-color: #1a1b26;
}
#entry {
    padding: 12px 6px;
    color: #c0caf5;
    font-size: 13px;
    border-radius: 10px;
    margin: 4px;
}
#entry:selected {
    background-color: #2a2d3e;
    color: #7aa2f7;
}
#img {
    margin-bottom: 6px;
}
#text {
    color: inherit;
    font-size: 13px;
    margin-top: 4px;
}
WOFI_CSS

# mako notification daemon config
mkdir -p "${ROOTFS_MNT}/home/chaos/.config/mako"
cat > "${ROOTFS_MNT}/home/chaos/.config/mako/config" << 'MAKO_CFG'
font=DejaVu Sans 13
background-color=#1a1b26
text-color=#c0caf5
border-color=#7aa2f7
border-radius=8
border-size=2
width=340
height=120
padding=14
margin=10
anchor=top-right
default-timeout=5000
MAKO_CFG

# Fix ownership of all newly created config dirs to the chaos user.
chroot "${ROOTFS_MNT}" chown -R chaos:chaos /home/chaos/.config/sway
chroot "${ROOTFS_MNT}" chown -R chaos:chaos /home/chaos/.config/waybar
chroot "${ROOTFS_MNT}" chown -R chaos:chaos /home/chaos/.config/wofi
chroot "${ROOTFS_MNT}" chown -R chaos:chaos /home/chaos/.config/mako

# Wayland env-vars profile — only activates inside a Wayland session.
# Keeps X11 sessions completely unaffected.
cat > "${ROOTFS_MNT}/etc/profile.d/rk-wayland.sh" << 'RK_WAYLAND_PROFILE'
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    export GDK_BACKEND=wayland,x11
    export QT_QPA_PLATFORM="wayland;xcb"
    export SDL_VIDEODRIVER=wayland
    export MOZ_ENABLE_WAYLAND=1
    export MOZ_DISABLE_RDD_SANDBOX=1
    export ELECTRON_OZONE_PLATFORM_HINT=auto
fi
RK_WAYLAND_PROFILE

# ── End Wayland / sway section ────────────────────────────────────────────────

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

# 10b. (removed) rk817-hard-poweroff userspace service was removed.
# The kernel's rk817_battery_shutdown() now saves dsoc/capacity before
# pm_power_off_prepare runs, and rk817_shutdown_prepare() writes DEV_OFF
# directly via i2c_smbus.  A userspace service running before systemd-poweroff
# would kill the PMIC before the kernel can save battery state.

# 10c. Power tuning service (WiFi power-save, CPU governor)
echo "[*] Installing power tuning service..."
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-power-tune.sh" << 'RK_POWER_TUNE'
#!/bin/sh
# RK3562 tablet power tuning — runs once at boot after network is up.

# Enable WiFi power save if interface exists
for iface in wlan0 wlan1; do
    if ip link show "$iface" > /dev/null 2>&1; then
        iw dev "$iface" set power_save on 2>/dev/null || true
    fi
done

# Switch all CPU policies to schedutil if currently set to performance
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -f "$policy/scaling_governor" ] || continue
    echo schedutil > "$policy/scaling_governor" 2>/dev/null || true
done
RK_POWER_TUNE
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-power-tune.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-power-tune.service" << 'RK_POWER_TUNE_UNIT'
[Unit]
Description=RK3562 power tuning (WiFi power-save, CPU governor)
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rk-power-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
RK_POWER_TUNE_UNIT
chroot "${ROOTFS_MNT}" systemctl enable rk-power-tune.service

# 11. Offline update package auto-apply service
echo "[*] Installing offline update auto-apply service..."
mkdir -p "${ROOTFS_MNT}/usr/local/sbin"
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-apply-update.sh" << 'RK_APPLY_UPDATE'
#!/bin/bash
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
LOG_FILE="/var/log/rk-update.log"
INBOX_DIRS=(/update/pending /home/chaos/update)
COMPAT_FILE="/update/update.tar.gz"
ARCHIVE_DIR="/update/applied"
FAILED_DIR="/update/failed"
DUPLICATE_DIR="/update/duplicate"
STATE_DIR="/var/lib/rk-update"
STAMP_FILE="${STATE_DIR}/last_applied.sha256"
TMP_DIR=""
BOOT_WAS_MOUNTED=0
BOOT_PART_DEV=""
REBOOT_NEEDED=0
HEARTBEAT_PID=""
PKG_FILE=""

mkdir -p "${STATE_DIR}"
touch "${LOG_FILE}"
exec >> "${LOG_FILE}" 2>&1

say() {
    local msg="$*"
    local line="[$(date -Iseconds)] rk-apply-update: ${msg}"
    echo "${line}"
    printf '%s\n' "${line}" > /dev/console 2>/dev/null || true
    printf '%s\n' "${line}" > /dev/tty1 2>/dev/null || true
}

hide_boot_splash() {
    if command -v plymouth >/dev/null 2>&1; then
        plymouth quit 2>/dev/null || true
    fi
    systemctl stop plymouth-start.service plymouth-quit.service plymouth-quit-wait.service 2>/dev/null || true
}

start_heartbeat() {
    (
        while true; do
            sleep 15
            say "Update in progress... do not power off."
        done
    ) &
    HEARTBEAT_PID=$!
}

stop_heartbeat() {
    if [ -n "${HEARTBEAT_PID}" ]; then
        kill "${HEARTBEAT_PID}" 2>/dev/null || true
        wait "${HEARTBEAT_PID}" 2>/dev/null || true
        HEARTBEAT_PID=""
    fi
}

archive_package() {
    local src="$1"
    local dst_dir="$2"
    local suffix="$3"
    local base
    local name
    local ts
    base="$(basename "${src}")"
    case "${base}" in
        *.tar.gz) name="${base%.tar.gz}" ;;
        *.tgz) name="${base%.tgz}" ;;
        *) name="${base}" ;;
    esac
    ts="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "${dst_dir}"
    mv -f "${src}" "${dst_dir}/${name}-${suffix}-${ts}.tar.gz"
}

find_update_package() {
    local dir
    local latest=""
    local candidate

    # Backward-compatible path used by older updater revisions.
    if [ -f "${COMPAT_FILE}" ]; then
        echo "${COMPAT_FILE}"
        return 0
    fi

    for dir in "${INBOX_DIRS[@]}"; do
        [ -d "${dir}" ] || continue
        candidate="$(find "${dir}" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.tgz' \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2- || true)"
        [ -n "${candidate}" ] || continue
        if [ -z "${latest}" ]; then
            latest="${candidate}"
            continue
        fi
        if [ "${candidate}" -nt "${latest}" ]; then
            latest="${candidate}"
        fi
    done

    [ -n "${latest}" ] || return 1
    echo "${latest}"
}

echo "=== $(date -Iseconds) rk-apply-update: start ==="
say "Checking for offline update package..."

cleanup() {
    stop_heartbeat
    if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
        rm -rf "${TMP_DIR}"
    fi
    if [ "${BOOT_WAS_MOUNTED}" -eq 1 ] && mountpoint -q /boot; then
        umount /boot || true
    fi
}
trap cleanup EXIT

PKG_FILE="$(find_update_package || true)"
if [ -z "${PKG_FILE}" ]; then
    say "No update package found in: ${INBOX_DIRS[*]}"
    exit 0
fi

say "Found update package: ${PKG_FILE}"
hide_boot_splash
say "Applying update package now."
start_heartbeat

PKG_SUM="$(sha256sum "${PKG_FILE}" | awk '{print $1}')"
if [ -f "${STAMP_FILE}" ] && grep -qx "${PKG_SUM}" "${STAMP_FILE}"; then
    archive_package "${PKG_FILE}" "${DUPLICATE_DIR}" "duplicate" || true
    say "Package ${PKG_SUM} already applied; moved duplicate package."
    exit 0
fi

TMP_DIR="$(mktemp -d /var/tmp/rk-update.XXXXXX)"
if ! tar -xzf "${PKG_FILE}" -C "${TMP_DIR}"; then
    archive_package "${PKG_FILE}" "${FAILED_DIR}" "extract-failed" || true
    say "Failed to extract ${PKG_FILE}; moved package to ${FAILED_DIR}."
    exit 1
fi

if [ ! -d "${TMP_DIR}/rootfs" ] && [ ! -d "${TMP_DIR}/boot" ]; then
    archive_package "${PKG_FILE}" "${FAILED_DIR}" "invalid-layout" || true
    say "Package missing both rootfs/ and boot/ payloads; moved to ${FAILED_DIR}."
    exit 1
fi

if [ -d "${TMP_DIR}/rootfs" ]; then
    say "Applying rootfs payload..."
    tar -C "${TMP_DIR}/rootfs" -cpf - . | tar -C / -xpf -
    say "Rootfs payload applied."
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
                say "Failed to mount boot partition ${BOOT_PART_DEV}; skipping boot payload."
            fi
        else
            say "Unable to resolve boot partition; skipping boot payload."
        fi
    fi

    if mountpoint -q /boot; then
        say "Applying boot payload..."
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
        say "Boot payload applied."
    fi
fi

echo "${PKG_SUM}" > "${STAMP_FILE}"
chmod 0600 "${STAMP_FILE}" || true

mkdir -p "${ARCHIVE_DIR}"
PKG_BASE="$(basename "${PKG_FILE}")"
case "${PKG_BASE}" in
    *.tar.gz) PKG_BASE="${PKG_BASE%.tar.gz}" ;;
    *.tgz) PKG_BASE="${PKG_BASE%.tgz}" ;;
esac
APPLIED_FILE="${ARCHIVE_DIR}/${PKG_BASE}-applied-$(date +%Y%m%d-%H%M%S).tar.gz"
mv -f "${PKG_FILE}" "${APPLIED_FILE}"
sync

say "Update applied successfully; archived package as ${APPLIED_FILE}"

# Rootfs payload may replace binaries/libraries used by current boot. Reboot
# once after apply to ensure a clean and consistent runtime state.
REBOOT_NEEDED=1
if [ "${REBOOT_NEEDED}" -eq 1 ]; then
    stop_heartbeat
    say "Rebooting to finalize update..."
    systemctl --no-block reboot
fi

exit 0
RK_APPLY_UPDATE
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-apply-update.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-apply-update.service" << 'RK_APPLY_UPDATE_UNIT'
[Unit]
Description=Apply offline update package from /update/pending or /update
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target lightdm.service graphical.target
ConditionPathExists=/usr/local/sbin/rk-apply-update.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rk-apply-update.sh
TimeoutSec=0
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
RK_APPLY_UPDATE_UNIT

mkdir -p "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/rk-apply-update.service \
    "${ROOTFS_MNT}/etc/systemd/system/multi-user.target.wants/rk-apply-update.service"

mkdir -p "${ROOTFS_MNT}/update/pending" "${ROOTFS_MNT}/update/applied" "${ROOTFS_MNT}/update/failed" "${ROOTFS_MNT}/update/duplicate"
cat > "${ROOTFS_MNT}/update/README.txt" << 'RK_UPDATE_README'
Drop update package in one of these folders:
- /update/pending  (recommended)
- /home/chaos/update

No extra command is needed.
On next boot, rk-apply-update.service applies the newest .tar.gz/.tgz package automatically.
Compatibility: /update/update.tar.gz is also checked.
During apply, plymouth spinner is stopped and progress is printed on the console and in /var/log/rk-update.log.
RK_UPDATE_README
chroot "${ROOTFS_MNT}" chown -R chaos:chaos /update || true
chroot "${ROOTFS_MNT}" chmod 0775 /update || true
chroot "${ROOTFS_MNT}" install -d -m 0775 -o chaos -g chaos /home/chaos/update || true

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
