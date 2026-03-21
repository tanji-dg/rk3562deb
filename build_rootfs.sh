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

# Optional: force a fresh debootstrap rootfs to avoid stale package/config
# carry-over across iterative builds.
if [ "${RKDEBIAN_FORCE_CLEAN_ROOTFS:-0}" = "1" ]; then
    echo "[*] RKDEBIAN_FORCE_CLEAN_ROOTFS=1 -> removing existing rootfs tree..."
    rm -rf "${ROOTFS_MNT}"
fi

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
    echo "[*] Tip: set RKDEBIAN_FORCE_CLEAN_ROOTFS=1 for a fully fresh rebuild."
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
    xorg xserver-xorg xserver-xorg-input-libinput firefox-esr mesa-utils libgl1-mesa-dri mesa-vulkan-drivers \
    pulseaudio pulseaudio-utils pulseaudio-module-bluetooth pavucontrol alsa-utils libasound2-plugins \
    zram-tools \
    plymouth plymouth-themes \
    libegl1 libgles2 libgbm1 libva2 libva-drm2 ffmpeg dbus \
    udev evtest sddm pciutils usbutils \
    xinput libinput-tools \
    python3 python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 \
    qt6-wayland \
    i2c-tools \
    iproute2 iputils-ping dnsutils locales tzdata upower brightnessctl rfkill \
    vainfo vdpauinfo \
    wireless-regdb firmware-brcm80211 \
    gnome-themes-extra gnome-themes-extra-data adwaita-icon-theme \
    packagekit flatpak appstream xdg-desktop-portal

# Remove any Trixie apt source that may be left over from a previous failed
# build attempt.  Trixie packages require libc6 >= 2.38 which Bookworm does
# not have, so mixing the two repos breaks apt.
rm -f "${ROOTFS_MNT}/etc/apt/sources.list.d/trixie.list"
rm -f "${ROOTFS_MNT}/etc/apt/preferences.d/99-trixie-pin"
apt-get update -qq

# Plasma Wayland stack.
# Prefer Plasma Mobile where available; fall back to Plasma Desktop.
apt-get install -y plasma-workspace-wayland kwin-wayland

plasma_shell_installed=0
for session_pkg in plasma-mobile plasma-phone-components plasma-desktop; do
    if apt-cache show "${session_pkg}" >/dev/null 2>&1; then
        apt-get install -y "${session_pkg}"
        plasma_shell_installed=1
        [ "${session_pkg}" != "plasma-mobile" ] && \
            echo "[!] Warning: ${session_pkg} installed (plasma-mobile unavailable on this mirror)."
        break
    fi
done
if [ "${plasma_shell_installed}" -ne 1 ]; then
    echo "[-] Error: no Plasma shell package available (tried plasma-mobile/plasma-phone-components/plasma-desktop)."
    exit 1
fi

# Optional Plasma/Mobile helpers.
# Include Qt virtual keyboard packages so SDDM can show an on-screen keyboard
# before login on touch-only devices.
for optional_pkg in plasma-nm plasma-pa plasma-discover plasma-discover-backend-flatpak \
                    xdg-desktop-portal-kde maliit-framework maliit-keyboard \
                    maliit-inputcontext-qt5 maliit-inputcontext-qt6 \
                    maliit-inputcontext-gtk3 maliit-inputcontext-gtk2 \
                    qtvirtualkeyboard-plugin \
                    qml-module-qtquick-virtualkeyboard \
                    qml6-module-qtquick-virtualkeyboard xwayland iio-sensor-proxy; do
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

# App store: Discover + Flatpak backend + Flathub remote.
if command -v flatpak >/dev/null 2>&1; then
    flatpak remote-add --if-not-exists flathub \
        https://flathub.org/repo/flathub.flatpakrepo || \
        echo "[!] Warning: failed to add Flathub remote."
fi
if apt-cache show plasma-discover-backend-flatpak >/dev/null 2>&1; then
    apt-get install -y plasma-discover-backend-flatpak
else
    echo "[!] Warning: plasma-discover-backend-flatpak not available; Flatpak apps won't show in Discover."
fi

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
# Reused rootfs trees may still point display-manager.service to LightDM.
# Drop the stale link so enabling SDDM can recreate it.
rm -f /etc/systemd/system/display-manager.service
systemctl enable sddm
systemctl enable packagekit || true

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
if [ ! -f "${ROOTFS_MNT}/tmp/setup_debian.sh" ]; then
    echo "[-] Missing chroot setup script: ${ROOTFS_MNT}/tmp/setup_debian.sh"
    exit 1
fi
# Run through /bin/bash explicitly to avoid direct-exec/shebang edge cases.
chroot "${ROOTFS_MNT}" /bin/bash /tmp/setup_debian.sh
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
        chroot "${ROOTFS_MNT}" bash -c '
set -e
dpkg -i /tmp/debs/*.deb || apt-get -f install -y

# Prefer a Wayland-capable Mali userspace package when one is provided locally.
wayland_mali_deb=""
for candidate in /tmp/debs/libmali*-x11-wayland-gbm*.deb /tmp/debs/libmali*-wayland-gbm*.deb; do
    [ -e "${candidate}" ] || continue
    wayland_mali_deb="${candidate}"
    break
done
if [ -n "${wayland_mali_deb}" ]; then
    dpkg -i "${wayland_mali_deb}" || apt-get -f install -y
fi

# If both variants exist, drop x11-only Mali to avoid selecting the wrong EGL stack.
mali_pkgs="$(dpkg -l | awk '"'"'/^ii/ && $2 ~ /^libmali-/ {print $2}'"'"')"
if echo "${mali_pkgs}" | grep -Eq "(x11-wayland-gbm|wayland-gbm)$"; then
    x11_only_pkgs="$(echo "${mali_pkgs}" | grep -E "x11-gbm$" | grep -v "x11-wayland-gbm" || true)"
    if [ -n "${x11_only_pkgs}" ]; then
        apt-get purge -y ${x11_only_pkgs} || true
        apt-get -f install -y || true
    fi
fi
' 2>/dev/null || true
        rm -rf "${ROOTFS_MNT}/tmp/debs"
    else
        echo "[!] Warning: No .deb files found in ${ROOT_DIR}/debs"
    fi
fi

# 5b. Keep Mesa EGL fallback, and make Mali GBM path use Debian libgbm.
# Some Mali blobs ship an old libgbm missing gbm_bo_create_with_modifiers2,
# which causes Plasma Wayland login loops.
if compgen -G "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/mali/libmali*.so" > /dev/null; then
    echo "[*] Preserving Mesa EGL fallback and fixing Mali libgbm path..."

    # Force the Mali libgbm path to resolve to Debian's libgbm implementation.
    if [ -e "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/libgbm.so.1" ]; then
        mali_gbm_backup="${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/mali/.libgbm.so.1.rkbak"
        if [ -e "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/mali/libgbm.so.1" ] && \
           [ ! -e "${mali_gbm_backup}" ]; then
            cp -a "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/mali/libgbm.so.1" \
                  "${mali_gbm_backup}"
        fi
        # Drop legacy backup names that match lib*.so*; ldconfig can relink
        # libgbm.so.1 back to them and undo the intended Debian libgbm pin.
        rm -f "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/mali/libgbm.so.1.rkbak"
        ln -sfn /usr/lib/aarch64-linux-gnu/libgbm.so.1 \
                "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/mali/libgbm.so.1"
        ln -sfn libgbm.so.1 \
                "${ROOTFS_MNT}/usr/lib/aarch64-linux-gnu/mali/libgbm.so"
    fi

    chroot "${ROOTFS_MNT}" ldconfig
else
    echo "[!] Warning: Mali userspace package not detected; skipping Mesa cleanup."
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
    # Keep touch aligned with default X11 landscape-right panel orientation.
    Option "CalibrationMatrix" "0 1 0 -1 0 1 0 0 1"
EndSection
XORG_TS

cat > "${ROOTFS_MNT}/etc/X11/xorg.conf.d/30-panel-landscape.conf" << 'XORG_LANDSCAPE'
Section "Monitor"
    Identifier "DSI-1"
    Option "Rotate" "right"
EndSection

Section "Monitor"
    Identifier "eDP-1"
    Option "Rotate" "right"
EndSection

Section "Monitor"
    Identifier "LVDS-1"
    Option "Rotate" "right"
EndSection
XORG_LANDSCAPE

cat > "${ROOTFS_MNT}/etc/X11/xorg.conf.d/20-modesetting-rockchip.conf" << 'XORG_GPU'
Section "Device"
    Identifier "Rockchip Graphics"
    Driver "modesetting"
    # Keep X11 on the non-glamor path for stability with this Mali userspace.
    # We observed intermittent SDDM black-screen boots where Xorg crashed in
    # libmali while modesetting+glamor initialized eglGetDisplay().
    Option "AccelMethod" "none"
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

# Install build dependencies for VAAPI driver
apt-get install -y --no-install-recommends git build-essential libva-dev libdrm-dev pkg-config

# Install librga prebuilt + headers from airockchip/librga
if [ ! -f /usr/lib/aarch64-linux-gnu/librga.so ]; then
    echo "[*] Fetching librga..."
    git clone --depth=1 https://github.com/airockchip/librga /tmp/librga_src
    cp /tmp/librga_src/libs/Linux/gcc-aarch64/librga.so /usr/lib/aarch64-linux-gnu/
    # Create SONAME symlink if the binary has one embedded
    SONAME=$(objdump -p /usr/lib/aarch64-linux-gnu/librga.so 2>/dev/null | awk '/SONAME/{print $2}')
    if [ -n "$SONAME" ] && [ "$SONAME" != "librga.so" ]; then
        ln -sf librga.so "/usr/lib/aarch64-linux-gnu/$SONAME"
    fi
    mkdir -p /usr/include/rga
    cp /tmp/librga_src/include/*.h /usr/include/rga/
    ldconfig
    rm -rf /tmp/librga_src
fi

# Build rk_hw_base middleware
if [ ! -f /usr/lib/aarch64-linux-gnu/librk_hw_base.so ]; then
    echo "[*] Building rk_hw_base..."
    git clone --depth=1 https://github.com/sujit-168/rk_hw_base /tmp/rk_hw_base
    cd /tmp/rk_hw_base
    make CFLAGS="-I./include -I/usr/include/rockchip -I/usr/include/rga -fPIC -Wall -O2" \
         LDFLAGS="-shared -L/usr/lib/aarch64-linux-gnu"
    cp lib/librk_hw_base.so /usr/lib/aarch64-linux-gnu/
    mkdir -p /usr/include/rk_hw_base
    cp include/*.h /usr/include/rk_hw_base/
    ldconfig
    cd /tmp
fi

# Build rockchip VAAPI driver
if [ ! -f /usr/lib/aarch64-linux-gnu/dri/rockchip_drv_video.so ]; then
    echo "[*] Building rockchip_drv_video.so..."
    git clone --depth=1 https://github.com/sujit-168/rk_vaapi_driver /tmp/rk_vaapi_driver
    # Ensure rk_hw_base sibling is present (may be missing on re-run if already installed)
    [ -d /tmp/rk_hw_base ] || git clone --depth=1 https://github.com/sujit-168/rk_hw_base /tmp/rk_hw_base
    cd /tmp/rk_vaapi_driver
    make
    mkdir -p /usr/lib/aarch64-linux-gnu/dri
    cp lib/rockchip_drv_video.so /usr/lib/aarch64-linux-gnu/dri/
    ldconfig
    cd /tmp
    rm -rf /tmp/rk_vaapi_driver /tmp/rk_hw_base
fi

# Clean up build-only dependencies
apt-get purge -y git build-essential libva-dev libdrm-dev pkg-config 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

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

# splash.png — custom boot logo from repository root
if [ ! -f "${ROOT_DIR}/splash.png" ]; then
    echo "[-] Error: missing ${ROOT_DIR}/splash.png (required for Plymouth logo)."
    exit 1
fi
install -m 0644 "${ROOT_DIR}/splash.png" "${THEME_DIR}/splash.png"
mkdir -p "${ROOTFS_MNT}/usr/share/backgrounds/rkdebian"
install -m 0644 "${ROOT_DIR}/splash.png" \
    "${ROOTFS_MNT}/usr/share/backgrounds/rkdebian/splash.png"

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

# Solid black background
Window.SetBackgroundTopColor(0.00, 0.00, 0.00);
Window.SetBackgroundBottomColor(0.00, 0.00, 0.00);

# ── Logo ───────────────────────────────────────────────────────────────────
logo_base = Image("splash.png");
logo_scale_w = (W * 0.78) / logo_base.GetWidth();
logo_scale_h = (H * 0.45) / logo_base.GetHeight();
logo_scale = Math.Min(logo_scale_w, logo_scale_h);
if (logo_scale > 1.0) logo_scale = 1.0;
logo = logo_base.Scale(logo_base.GetWidth() * logo_scale,
                       logo_base.GetHeight() * logo_scale);
logo_spr = Sprite();
logo_spr.SetImage(logo);
logo_spr.SetX(Math.Int(W / 2 - logo.GetWidth() / 2));
logo_spr.SetY(Math.Int(H * 0.18));

# ── Pulsing dot loader (5 dots, wave ripple) ───────────────────────────────
N      = 5;
STEP   = 22;
DOT_Y  = Math.Int(H * 0.73);
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
echo "[*] Adding Chromium acceleration flags..."
mkdir -p "${ROOTFS_MNT}/etc/chromium.d"
if [ "${FF_VAAPI_ENABLED}" = "true" ]; then
    cat > "${ROOTFS_MNT}/etc/chromium.d/rk3562-hw-accel" << 'CHROMIUM_HW_FLAGS'
# RK3562 hardware acceleration — sourced by /usr/bin/chromium wrapper
# Native Mali EGL (wayland-gbm platform) for GPU compositing.
# VAAPI hardware video decode via rockchip_drv_video.so + MPP.
export LIBVA_DRIVER_NAME=rockchip
export LIBVA_DRIVERS_PATH=/usr/lib/aarch64-linux-gnu/dri
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ozone-platform=wayland"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-gl=egl"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ignore-gpu-blocklist"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-gpu-rasterization"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-gpu-sandbox"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-accelerated-video-decode"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-features=VaapiVideoDecoder,VaapiVideoDecodeLinuxGL,VaapiIgnoreDriverChecks"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disable-features=UseChromeOSDirectVideoDecoder"
# ── FALLBACK: if --use-gl=egl crashes, try ANGLE instead: ──
# CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-gl=angle"
# CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-angle=opengles"
CHROMIUM_HW_FLAGS
else
    # No rockchip VAAPI driver — native Mali EGL compositing, software video decode.
    cat > "${ROOTFS_MNT}/etc/chromium.d/rk3562-hw-accel" << 'CHROMIUM_SW_FLAGS'
# RK3562 — Native Mali EGL compositing, software video decode
# (VAAPI driver not found at build time)
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ozone-platform=wayland"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-gl=egl"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --ignore-gpu-blocklist"
CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --enable-gpu-rasterization"
# ── FALLBACK: if --use-gl=egl crashes, try ANGLE instead: ──
# CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-gl=angle"
# CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --use-angle=opengles"
CHROMIUM_SW_FLAGS
fi

# 8. Setting hostname and fstab
echo "[*] Setting hostname and fstab..."
echo "rk3562-debian" > "${ROOTFS_MNT}/etc/hostname"

cat > "${ROOTFS_MNT}/etc/fstab" << 'FSTAB'
# <file system>  <mount point>  <type>  <options>        <dump>  <pass>
PARTUUID=c0ffee11-2233-4455-6677-8899aabbccdd  /  ext4  defaults,noatime  0  1
FSTAB

# 9. Configure SDDM autologin for Plasma
echo "[*] Configuring SDDM autologin..."
mkdir -p "${ROOTFS_MNT}/etc/sddm.conf.d"
rm -rf "${ROOTFS_MNT}/etc/lightdm"

# Drop stale per-user overrides from previous experiments that can force a
# mismatched session backend and cause black-screen/login-loop behavior.
rm -f "${ROOTFS_MNT}/home/chaos/.config/environment.d/90-plasma-x11.conf" \
      "${ROOTFS_MNT}/home/chaos/.config/environment.d/91-plasma-shell.conf" \
      "${ROOTFS_MNT}/home/chaos/.config/plasma-org.kde.plasma.phoneshell-appletsrc" \
      "${ROOTFS_MNT}/home/chaos/.config/plasma-org.kde.plasma.desktop-appletsrc" \
      "${ROOTFS_MNT}/home/chaos/.config/plasmashellrc"

# Prefer Plasma X11 by default.
PLASMA_SESSION="plasma.desktop"
PLASMA_DISPLAY_SERVER="x11"
if [ ! -f "${ROOTFS_MNT}/usr/share/xsessions/${PLASMA_SESSION}" ]; then
    echo "[!] Warning: ${PLASMA_SESSION} missing in /usr/share/xsessions; scanning fallback sessions."
    PLASMA_SESSION=""
    for candidate in plasma.desktop plasma-mobile.desktop plasmawayland.desktop; do
        if [ -f "${ROOTFS_MNT}/usr/share/xsessions/${candidate}" ] || \
           [ -f "${ROOTFS_MNT}/usr/share/wayland-sessions/${candidate}" ]; then
            PLASMA_SESSION="${candidate}"
            break
        fi
    done
    if [ -z "${PLASMA_SESSION}" ]; then
        PLASMA_SESSION="plasma.desktop"
        echo "[!] Warning: no Plasma session desktop file detected; defaulting to ${PLASMA_SESSION}."
    fi
    if [ ! -f "${ROOTFS_MNT}/usr/share/xsessions/${PLASMA_SESSION}" ]; then
        PLASMA_DISPLAY_SERVER="wayland"
        echo "[!] Warning: ${PLASMA_SESSION} is not an X11 session; using DisplayServer=${PLASMA_DISPLAY_SERVER}."
    fi
fi

cat > "${ROOTFS_MNT}/etc/sddm.conf.d/10-rk-autologin.conf" << SDDM_AUTLOGIN
[Autologin]
User=chaos
Session=${PLASMA_SESSION}
Relogin=false

[General]
DisplayServer=${PLASMA_DISPLAY_SERVER}
SDDM_AUTLOGIN

# Stale user-unit symlinks from old sway-focused rootfs trees can trigger
# waybar restart loops in Plasma sessions (and tank UI responsiveness).
rm -f "${ROOTFS_MNT}/etc/systemd/user/graphical-session.target.wants/waybar.service"

# Configure an on-screen keyboard at the greeter for touch-only login.
cat > "${ROOTFS_MNT}/etc/sddm.conf.d/20-rk-virtual-keyboard.conf" << 'SDDM_VK'
[General]
InputMethod=qtvirtualkeyboard
GreeterEnvironment=QT_IM_MODULE=qtvirtualkeyboard
SDDM_VK

# Auto-show Maliit keyboard in Plasma sessions (Qt + GTK apps).
mkdir -p "${ROOTFS_MNT}/home/chaos/.config/plasma-workspace/env"
cat > "${ROOTFS_MNT}/home/chaos/.config/plasma-workspace/env/90-inputmethod.sh" << 'IM_ENV'
#!/bin/sh
export GTK_IM_MODULE=Maliit
export QT_IM_MODULE=MaliitPhablet
export XMODIFIERS=@im=none
IM_ENV
chmod +x "${ROOTFS_MNT}/home/chaos/.config/plasma-workspace/env/90-inputmethod.sh"
chroot "${ROOTFS_MNT}" chown chaos:chaos /home/chaos/.config/plasma-workspace/env/90-inputmethod.sh || true

mkdir -p "${ROOTFS_MNT}/home/chaos/.config/autostart"
cat > "${ROOTFS_MNT}/home/chaos/.config/autostart/maliit-server.desktop" << 'MALIIT_AUTOSTART'
[Desktop Entry]
Type=Application
Name=Maliit Server
Comment=On-screen keyboard input method service
Exec=/usr/bin/maliit-server
OnlyShowIn=KDE;
X-GNOME-Autostart-enabled=true
NoDisplay=true
MALIIT_AUTOSTART
chroot "${ROOTFS_MNT}" chown chaos:chaos /home/chaos/.config/autostart/maliit-server.desktop || true

# Prevent duplicate/competing keyboards when reusing an old rootfs tree.
cat > "${ROOTFS_MNT}/home/chaos/.config/autostart/onboard.desktop" << 'ONBOARD_HIDE'
[Desktop Entry]
Hidden=true
ONBOARD_HIDE
cat > "${ROOTFS_MNT}/home/chaos/.config/autostart/maliit-keyboard.desktop" << 'MALIIT_KEYBOARD_HIDE'
[Desktop Entry]
Hidden=true
MALIIT_KEYBOARD_HIDE
chroot "${ROOTFS_MNT}" chown chaos:chaos /home/chaos/.config/autostart/onboard.desktop \
    /home/chaos/.config/autostart/maliit-keyboard.desktop || true

# Trim background autostarts that are unnecessary in the Plasma tablet image.
# These either belong to other desktops (XFCE/GNOME) or are optional daemons
# that cost responsiveness on software-rendered Plasma X11.
PLASMA_DISABLE_AUTOSTARTS="
ayatana-indicator-application.desktop
blueman.desktop
geoclue-demo-agent.desktop
kup-daemon.desktop
light-locker.desktop
org.gnome.Software.desktop
print-applet.desktop
rk-xfce4-panel.desktop
xfce4-notifyd.desktop
xfce4-power-manager.desktop
xfsettingsd.desktop
xiccd.desktop
"

for desktop in ${PLASMA_DISABLE_AUTOSTARTS}; do
cat > "${ROOTFS_MNT}/home/chaos/.config/autostart/${desktop}" << 'AUTOSTART_HIDE'
[Desktop Entry]
Hidden=true
AUTOSTART_HIDE
chroot "${ROOTFS_MNT}" chown chaos:chaos "/home/chaos/.config/autostart/${desktop}" || true
done

# Keep a fallback polkit agent autostart for Plasma sessions.
mkdir -p "${ROOTFS_MNT}/etc/xdg/autostart"
if [ ! -f "${ROOTFS_MNT}/etc/xdg/autostart/polkit-gnome-authentication-agent-1.desktop" ]; then
cat > "${ROOTFS_MNT}/etc/xdg/autostart/polkit-gnome-authentication-agent-1.desktop" << 'POLKIT'
[Desktop Entry]
Type=Application
Name=PolicyKit Authentication Agent
Exec=/usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1
OnlyShowIn=KDE;
X-GNOME-Autostart-enabled=true
POLKIT
fi

# Optional launcher shortcut for maliit keyboard.
mkdir -p "${ROOTFS_MNT}/home/chaos/Desktop"
cat > "${ROOTFS_MNT}/home/chaos/Desktop/on-screen-keyboard.desktop" << 'MALIIT'
[Desktop Entry]
Type=Application
Name=On-Screen Keyboard
Comment=Launch on-screen keyboard
Exec=maliit-keyboard
Icon=input-keyboard
Terminal=false
Categories=Utility;
MALIIT
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
        action.id == "org.freedesktop.login1.set-backlight";

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

Works in X11 and in Wayland sessions that provide swaymsg-compatible output IPC.

Under X11:  uses xrandr for display rotation and xinput for touch mapping.
Under Wayland: uses swaymsg output transforms, maps the touchscreen to the
               active output, and resets stale calibration matrices.
"""

import array
import fcntl
import glob
import json
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

ICON_DEFAULT = "video-display"
IDENTITY_TOUCH_MATRIX = "1 0 0 0 1 0"


def _swaysock_path():
    """Best-effort SWAYSOCK lookup for non-interactive contexts."""
    env_sock = os.environ.get("SWAYSOCK", "")
    if env_sock and os.path.exists(env_sock):
        return env_sock
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    if runtime:
        socks = sorted(glob.glob(os.path.join(runtime, "sway-ipc.*.sock")))
        if socks:
            return socks[-1]
    return None


def _swaymsg(args):
    """Run swaymsg with explicit socket fallback when needed."""
    cmd = ["swaymsg"]
    sock = _swaysock_path()
    if sock:
        cmd += ["--socket", sock]
    cmd += list(args)
    return subprocess.run(cmd, text=True, capture_output=True)


def _sway_output():
    """Return the name of the first active sway output via swaymsg JSON."""
    res = _swaymsg(["-t", "get_outputs"])
    if res.returncode != 0:
        return None
    try:
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
    res = _swaymsg(["-t", "get_inputs"])
    if res.returncode != 0:
        return None
    try:
        for dev in json.loads(res.stdout):
            if dev.get("type") == "touch":
                return dev["identifier"]
    except Exception:
        pass
    return None


def _wayland_current_orientation():
    """Read current active output transform and map it to our orientation key."""
    res = _swaymsg(["-t", "get_outputs"])
    if res.returncode != 0:
        return "normal"
    try:
        outputs = json.loads(res.stdout)
        target = None
        for out in outputs:
            if out.get("active"):
                target = out
                break
        if target is None and outputs:
            target = outputs[0]
        transform = str((target or {}).get("transform", "normal"))
        mapping = {
            "normal": "normal",
            "90": "right",
            "180": "inverted",
            "270": "left",
        }
        return mapping.get(transform, "normal")
    except Exception:
        return "normal"


def apply_orientation(orientation):
    """Rotate display and update touch mapping for the current session type."""
    if IS_WAYLAND:
        output = _sway_output()
        if not output:
            return False
        # Rotate the output
        res = _swaymsg(["output", output, "transform", WL_TRANSFORMS[orientation]])
        if res.returncode != 0:
            return False
        # Keep touch mapped to the active output and clear stale calibration.
        touch_id = _sway_touch_identifier()
        if touch_id:
            _swaymsg(["--", "input", touch_id, "map_to_output", output])
            _swaymsg(["--", "input", touch_id, "calibration_matrix",
                      IDENTITY_TOUCH_MATRIX])
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
        self._current = _wayland_current_orientation() if IS_WAYLAND else "normal"
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
                label="⚠ Rotation requires swaymsg-compatible Wayland"
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
    if IS_WAYLAND:
        # Ensure touch mapping starts in sync with the current transform.
        apply_orientation(app._current)
    if auto_start:
        app._auto = True
        app._auto_item.set_active(True)
        app._accel.start()
    app.run()


if __name__ == "__main__":
    main()
RK_SCREEN_ROTATE
chmod +x "${ROOTFS_MNT}/usr/local/bin/rk-screen-rotate.py"

# Wayland desktop env vars for Plasma sessions.
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
OnlyShowIn=KDE;
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

# 10d. RK817 battery gauge recovery (fixes occasional false 0% after cold-off).
echo "[*] Installing RK817 battery gauge recovery service..."
cat > "${ROOTFS_MNT}/usr/local/sbin/rk-battery-gauge-fix.sh" << 'RK_BAT_GAUGE_FIX'
#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin
LOG_FILE="/var/log/rk-battery-gauge-fix.log"
CAP_FILE="/sys/class/power_supply/battery/capacity"
VOLT_FILE="/sys/class/power_supply/battery/voltage_now"

say() {
    echo "[$(date -Iseconds)] rk-battery-gauge-fix: $*" >> "${LOG_FILE}"
}

read_int_file() {
    file="$1"
    if [ -f "${file}" ]; then
        tr -cd '0-9' < "${file}"
    fi
}

is_power_online() {
    for p in /sys/class/power_supply/ac/online /sys/class/power_supply/usb/online; do
        [ -f "${p}" ] || continue
        val="$(read_int_file "${p}")"
        [ -n "${val}" ] && [ "${val}" -eq 1 ] && return 0
    done
    return 1
}

mkdir -p /var/log
touch "${LOG_FILE}"

if ! command -v i2cset >/dev/null 2>&1; then
    say "i2cset not found, skipping"
    exit 0
fi

resolve_i2c_bus() {
    for dev in /sys/bus/i2c/devices/*-0020; do
        [ -e "${dev}" ] || continue
        bus="${dev##*/}"
        bus="${bus%-0020}"
        [ -n "${bus}" ] && {
            echo "${bus}"
            return 0
        }
    done

    [ -e /dev/i2c-0 ] && {
        echo "0"
        return 0
    }

    return 1
}

if [ ! -f "${CAP_FILE}" ] || [ ! -f "${VOLT_FILE}" ]; then
    say "battery sysfs missing, skipping"
    exit 0
fi

cap="$(read_int_file "${CAP_FILE}")"
volt="$(read_int_file "${VOLT_FILE}")"
[ -z "${cap}" ] && cap=0
[ -z "${volt}" ] && volt=0

# Trigger only on suspicious state:
# - battery reports 0%
# - but voltage is high enough to likely not be empty, or charger is connected
if [ "${cap}" -ne 0 ]; then
    say "capacity=${cap}% voltage_now=${volt}uV: no fix needed"
    exit 0
fi

if [ "${volt}" -lt 3600000 ] && ! is_power_online; then
    say "capacity=0 and low voltage (${volt}uV) with no charger: likely real empty, no fix"
    exit 0
fi

i2c_bus="$(resolve_i2c_bus || true)"
if [ -z "${i2c_bus}" ]; then
    say "could not locate RK817 i2c bus, skipping"
    exit 0
fi

say "detected possible stuck gauge (capacity=0 voltage_now=${volt}uV), applying fix on i2c-${i2c_bus}"
if command -v i2cget >/dev/null 2>&1; then
    gg_sts_raw="$(i2cget -f -y "${i2c_bus}" 0x20 0x57 2>/dev/null || true)"
    case "${gg_sts_raw}" in
        0x[0-9a-fA-F]|0x[0-9a-fA-F][0-9a-fA-F])
            gg_sts_new_dec=$((gg_sts_raw | 0x10))
            gg_sts_new_hex="$(printf '0x%02x' "${gg_sts_new_dec}")"
            i2cset -f -y "${i2c_bus}" 0x20 0x57 "${gg_sts_new_hex}" >/dev/null 2>&1 || {
                say "i2cset command failed"
                exit 0
            }
            say "GG_STS ${gg_sts_raw} -> ${gg_sts_new_hex} (set BAT_CON)"
            ;;
        *)
            say "GG_STS read failed (${gg_sts_raw}), falling back to legacy write 0x51"
            i2cset -f -y "${i2c_bus}" 0x20 0x57 0x51 >/dev/null 2>&1 || {
                say "i2cset command failed"
                exit 0
            }
            ;;
    esac
else
    say "i2cget not found, using legacy write 0x51"
    i2cset -f -y "${i2c_bus}" 0x20 0x57 0x51 >/dev/null 2>&1 || {
        say "i2cset command failed"
        exit 0
    }
fi

# Nudge power_supply userspace updates.
udevadm trigger --subsystem-match=power_supply --action=change >/dev/null 2>&1 || true
sleep 1

new_cap="$(read_int_file "${CAP_FILE}")"
[ -z "${new_cap}" ] && new_cap=0
if [ "${new_cap}" -eq 0 ]; then
    say "after fix: capacity still 0% (BAT_CON will take effect on next reboot)"
else
    say "after fix: capacity=${new_cap}%"
fi

exit 0
RK_BAT_GAUGE_FIX
chmod +x "${ROOTFS_MNT}/usr/local/sbin/rk-battery-gauge-fix.sh"

cat > "${ROOTFS_MNT}/etc/systemd/system/rk-battery-gauge-fix.service" << 'RK_BAT_GAUGE_FIX_UNIT'
[Unit]
Description=RK817 battery gauge recovery at boot
DefaultDependencies=no
After=local-fs.target systemd-udev-settle.service
Wants=systemd-udev-settle.service
Before=display-manager.service
ConditionPathExists=/dev/i2c-0
ConditionPathExists=/sys/class/power_supply/battery/capacity

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rk-battery-gauge-fix.sh
TimeoutSec=10

[Install]
WantedBy=multi-user.target
RK_BAT_GAUGE_FIX_UNIT
chroot "${ROOTFS_MNT}" systemctl enable rk-battery-gauge-fix.service

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
Before=multi-user.target graphical.target
ConditionPathExists=/usr/local/sbin/rk-apply-update.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rk-apply-update.sh
TimeoutSec=0
StandardOutput=journal
StandardError=journal

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
During apply, plymouth spinner is stopped and progress is logged in /var/log/rk-update.log.
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
