#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT_DIR="${ROOT_DIR}/out"
OUTPUT_DIR="${ROOT_DIR}/output/update"
PKG_PATH="${1:-${OUTPUT_DIR}/update.tar.gz}"
STAGE_DIR="${OUT_DIR}/update_pkg_stage"

ROOTFS_DIR="${OUT_DIR}/rootfs"
BOOT_DIR="${OUT_DIR}/boot"

if [ ! -d "${ROOTFS_DIR}" ]; then
    echo "[-] Missing rootfs directory: ${ROOTFS_DIR}"
    exit 1
fi

for required in "${BOOT_DIR}/Image" "${BOOT_DIR}/rk3562.dtb" "${BOOT_DIR}/rk3562-fallback.dtb" "${BOOT_DIR}/extlinux/extlinux.conf"; do
    if [ ! -f "${required}" ]; then
        echo "[-] Missing boot artifact: ${required}"
        exit 1
    fi
done

echo "[*] Creating offline update package..."
# Stage dir can contain root-owned files from prior sudo tar runs.
sudo rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}/rootfs" "${STAGE_DIR}/boot/extlinux" "${OUTPUT_DIR}"

echo "[*] Staging rootfs payload..."
sudo tar \
    --exclude='./dev/*' \
    --exclude='./proc/*' \
    --exclude='./sys/*' \
    --exclude='./run/*' \
    --exclude='./tmp/*' \
    --exclude='./var/tmp/*' \
    --exclude='./mnt/*' \
    --exclude='./media/*' \
    --exclude='./lost+found' \
    --exclude='./home/*' \
    --exclude='./boot/*' \
    --exclude='./update/*' \
    --exclude='./etc/machine-id' \
    --exclude='./var/lib/systemd/random-seed' \
    -C "${ROOTFS_DIR}" -cpf - . | sudo tar -C "${STAGE_DIR}/rootfs" -xpf -

cp -f "${BOOT_DIR}/Image" "${STAGE_DIR}/boot/Image"
cp -f "${BOOT_DIR}/rk3562.dtb" "${STAGE_DIR}/boot/rk3562.dtb"
cp -f "${BOOT_DIR}/rk3562-fallback.dtb" "${STAGE_DIR}/boot/rk3562-fallback.dtb"
cp -f "${BOOT_DIR}/extlinux/extlinux.conf" "${STAGE_DIR}/boot/extlinux/extlinux.conf"

{
    echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "git_rev=$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "format=v1"
    echo "rootfs_path=/"
    echo "boot_path=/boot"
} > "${STAGE_DIR}/manifest.txt"

mkdir -p "$(dirname "${PKG_PATH}")"
sudo tar -C "${STAGE_DIR}" -czf "${PKG_PATH}" .
sudo chown "$(id -u):$(id -g)" "${PKG_PATH}" || true

sudo rm -rf "${STAGE_DIR}"
echo "[+] Update package ready: ${PKG_PATH}"
