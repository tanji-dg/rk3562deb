#!/bin/bash
set -e

export PATH="/usr/sbin:/sbin:$PATH"

# RK3562 Debian 12 Builder

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC_DIR="${ROOT_DIR}/src"
OUT_DIR="${ROOT_DIR}/out"
OUTPUT_DIR="${ROOT_DIR}/output"

# Versions & URLs
UBOOT_URL="https://github.com/Firefly-rk-linux/u-boot.git"
UBOOT_BRANCH="rk356x/firefly-5.10"
KERNEL_URL="https://github.com/rockchip-linux/kernel.git"
KERNEL_BRANCH="develop-6.1"
RKBIN_URL="https://github.com/rockchip-linux/rkbin.git"
RKBIN_BRANCH="master"

# RK3562 configs
UBOOT_DEFCONFIG="rk3562_defconfig"
KERNEL_DEFCONFIG="rockchip_linux_defconfig"
KERNEL_DTB="rk3562-rk817-tablet-v10.dtb"

CROSS_COMPILE="aarch64-linux-gnu-"
MAKE_THREADS=$(nproc)

echo "=== RK3562 Debian 12 Builder ==="

ensure_sdk_compat_layout() {
    mkdir -p "${ROOT_DIR}/app" "${ROOT_DIR}/buildroot" "${ROOT_DIR}/device" \
             "${ROOT_DIR}/docs" "${ROOT_DIR}/external" "${ROOT_DIR}/prebuilts" \
             "${ROOT_DIR}/tools" "${ROOT_DIR}/prebuilt_rootfs" "${OUTPUT_DIR}/update"

    if [ -d "${SRC_DIR}/kernel" ] && [ ! -e "${ROOT_DIR}/kernel" ]; then
        ln -s "src/kernel" "${ROOT_DIR}/kernel"
    fi
    if [ -d "${SRC_DIR}/u-boot" ] && [ ! -e "${ROOT_DIR}/u-boot" ]; then
        ln -s "src/u-boot" "${ROOT_DIR}/u-boot"
    fi
    if [ -d "${SRC_DIR}/rkbin" ] && [ ! -e "${ROOT_DIR}/rkbin" ]; then
        ln -s "src/rkbin" "${ROOT_DIR}/rkbin"
    fi
}

select_lunch() {
    cat << 'EOF'
############### Rockchip Linux SDK (compat) ###############

Pick a defconfig:
1. firefly_rk3562_aio-3562jq_debian_defconfig

Which would you like? [1]:
EOF
    read -r choice
    choice=${choice:-1}
    case "${choice}" in
        1)
            echo "firefly_rk3562_aio-3562jq_debian_defconfig" > "${ROOT_DIR}/.rk_lunch"
            echo "[+] Selected firefly_rk3562_aio-3562jq_debian_defconfig"
            ;;
        *)
            echo "[!] Unsupported selection '${choice}', defaulting to firefly_rk3562_aio-3562jq_debian_defconfig"
            echo "firefly_rk3562_aio-3562jq_debian_defconfig" > "${ROOT_DIR}/.rk_lunch"
            ;;
    esac
}

check_deps() {
    echo "[*] Checking dependencies..."
    local deps=("git" "make" "aarch64-linux-gnu-gcc" "bc" "bison" "flex" "dtc" "genimage" "wget" "tar" "mcopy" "debootstrap" "qemu-aarch64-static" "mkfs.ext4" "e2fsck")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "[-] Error: Missing dependency: $dep. Please install it."
            exit 1
        fi
    done
    echo "[+] All dependencies met."
}

setup_dirs() {
    mkdir -p "${SRC_DIR}"
    mkdir -p "${OUT_DIR}/boot"
    mkdir -p "${OUT_DIR}/rootfs"
    mkdir -p "${OUTPUT_DIR}/update"
}

run_build_rootfs() {
    local preserve_env="RKDEBIAN_FORCE_CLEAN_ROOTFS,ROOTFS_IMAGE_SIZE,ROOTFS_HEADROOM_MB,ROOTFS_MIN_MB"
    if [ "${EUID}" -eq 0 ]; then
        bash "${ROOT_DIR}/build_rootfs.sh"
    else
        sudo --preserve-env="${preserve_env}" bash "${ROOT_DIR}/build_rootfs.sh"
    fi
}

build_uboot() {
    echo "[*] Building U-Boot..."
    cd "${SRC_DIR}"
    
    if [ ! -d "rkbin" ]; then
        git clone --depth 1 -b ${RKBIN_BRANCH} ${RKBIN_URL} rkbin
    fi
    
    if [ ! -d "u-boot" ]; then
        git clone --depth 1 -b ${UBOOT_BRANCH} ${UBOOT_URL} u-boot
    fi
    
    cd u-boot
    
    export KCFLAGS="-Wno-error"
    ABS_CROSS_COMPILE=$(dirname $(command -v aarch64-linux-gnu-gcc))"/aarch64-linux-gnu-"
    ./make.sh rk3562 CROSS_COMPILE=${ABS_CROSS_COMPILE}
    
    # Store artifacts
    local spl_loader
    spl_loader=$(ls -1 rk3562_spl_loader_*.bin 2>/dev/null | head -n1 || true)
    if [ -z "${spl_loader}" ]; then
        echo "[-] Error: rk3562_spl_loader_*.bin not found in U-Boot output."
        exit 1
    fi

    cp "${spl_loader}" "${OUT_DIR}/idbloader.img"
    cp uboot.img "${OUT_DIR}/u-boot.itb"
    
    echo "[+] U-Boot build complete."
    ensure_sdk_compat_layout
}

build_kernel() {
    echo "[*] Building Linux Kernel..."
    cd "${SRC_DIR}"
    
    if [ ! -d "kernel" ]; then
        git clone --depth 1 -b ${KERNEL_BRANCH} ${KERNEL_URL} kernel
    fi

    cd kernel

    # Apply local overlay (custom drivers, defconfig, DTS, firmware) if existing
    if [ -d "${ROOT_DIR}/overlay" ]; then
        cp -r "${ROOT_DIR}/overlay/." .

        if [ -d .git ]; then
            local pmic_overlay_files=(
                "drivers/mfd/rk808.c"
                "drivers/power/supply/rk817_battery.c"
                "drivers/power/supply/rk817_charger.c"
            )

            if [ "${RKDEBIAN_KEEP_OVERLAY_PMIC_PATCHES:-0}" = "1" ]; then
                echo "[!] Keeping overlay PMIC kernel files (RKDEBIAN_KEEP_OVERLAY_PMIC_PATCHES=1)."
            else
                # Kernel 6.1 baseline: prefer upstream PMIC drivers first.
                # Set RKDEBIAN_KEEP_OVERLAY_PMIC_PATCHES=1 to re-enable overlay versions.
                for file in "${pmic_overlay_files[@]}"; do
                    if [ -f "${ROOT_DIR}/overlay/${file}" ]; then
                        echo "[*] Restoring upstream kernel file for ${file}."
                        git checkout -- "${file}"
                    fi
                done
            fi
        fi
    fi

    # RK817 hard power-off fix:
    # force DEV_OFF over SMBus in rk817_shutdown_prepare() to avoid
    # poweroff->immediate-reboot behavior on this tablet.
    local rk817_dev_off_patch="${ROOT_DIR}/overlay/kernel-patches/rk817-dev-off-poweroff.patch"
    if [ -f "${rk817_dev_off_patch}" ]; then
        if grep -q "shutdown: SYS_CFG3=0x%02x, wrote DEV_OFF" drivers/mfd/rk808.c; then
            echo "[*] RK817 DEV_OFF shutdown fix already present."
        else
            echo "[*] Applying RK817 DEV_OFF shutdown fix..."
            if ! git apply --whitespace=nowarn "${rk817_dev_off_patch}"; then
                echo "[-] Error: failed to apply RK817 DEV_OFF shutdown fix."
                exit 1
            fi
        fi
    fi

    # Use the configured defconfig, with a rockchip fallback if needed.
    if [ ! -f "arch/arm64/configs/${KERNEL_DEFCONFIG}" ]; then
        echo "Warning: ${KERNEL_DEFCONFIG} not found. Attempting rockchip_linux_defconfig..."
        KERNEL_DEFCONFIG="rockchip_linux_defconfig"
    fi

    RKDEBIAN_ALLOW_WARNINGS=1 make ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE} WERROR=0 ${KERNEL_DEFCONFIG}

    # GCC 14 + modern binutils can fail at vmlinux link when patchable-function-entry
    # sections are emitted via dynamic ftrace. Disable those tracing options explicitly.
    if [ -x "scripts/config" ]; then
        scripts/config --disable DYNAMIC_FTRACE_WITH_REGS || true
        scripts/config --disable DYNAMIC_FTRACE || true
        scripts/config --disable FTRACE_MCOUNT_RECORD || true
        scripts/config --disable FTRACE_MCOUNT_USE_PATCHABLE_FUNCTION_ENTRY || true

        # Force Seekwave SWT6621S/EA6621 stack and disable legacy Broadcom path.
        scripts/config --disable BCMDHD || true
        scripts/config --disable AP6XXX || true
        scripts/config --disable WL_ROCKCHIP || true
        scripts/config --disable WIFI_BUILD_MODULE || true
        scripts/config --enable SEEKWAVE_BSP_DRIVERS || true
        scripts/config --enable SKW_SDIOHAL || true
        scripts/config --enable SKW_BSP_UCOM || true
        scripts/config --enable SKW_BSP_BOOT || true
        scripts/config --enable WLAN_VENDOR_SEEKWAVE || true
        scripts/config --enable SKW_VENDOR || true
        scripts/config --enable SKW_DFS_MASTER || true
        scripts/config --module SKW_BT || true
        # Enable Rockchip sensor framework before selecting accel drivers.
        scripts/config --enable SENSOR_DEVICE || true
        scripts/config --enable GSENSOR_DEVICE || true
        scripts/config --enable SKW_LOG_WARN || true
        scripts/config --disable SKW_LOG_DEBUG || true
        scripts/config --disable SKW_LOG_DETAIL || true
        # Build Android-matching accelerometer drivers (SC7A20/DA223).
        scripts/config --enable GS_SC7A20 || true
        scripts/config --enable GS_DA223 || true
        scripts/config --enable GS_DA228E || true
        # Keep Rockchip ASoC options aligned with known-good newrk3562 audio.
        scripts/config --enable SND_CTL_FAST_LOOKUP || true
        scripts/config --enable SND_SOC_ROCKCHIP_ASRC || true
        scripts/config --enable SND_SOC_ROCKCHIP_DLP || true
        scripts/config --enable SND_SOC_ROCKCHIP_DLP_PCM || true
        scripts/config --enable SND_SOC_ROCKCHIP_MULTI_DAIS || true
        scripts/config --enable SND_SOC_ROCKCHIP_PDM_V2 || true
        scripts/config --enable SND_SOC_ROCKCHIP_TRCM || true
        # Avoid black screen before userspace by enabling early fb console/logo.
        scripts/config --enable FRAMEBUFFER_CONSOLE || true
        scripts/config --enable LOGO || true
        scripts/config --enable LOGO_LINUX_CLUT224 || true
        scripts/config --set-str EXTRA_FIRMWARE "RAM_RW_KERNEL_DRAM.bin ROM_EXEC_KERNEL_IRAM.bin EA6621Q_SEEKWAVE_R00005.bin" || true
        scripts/config --set-str EXTRA_FIRMWARE_DIR "firmware" || true

        RKDEBIAN_ALLOW_WARNINGS=1 make ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE} olddefconfig
    fi

    RKDEBIAN_ALLOW_WARNINGS=1 make ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE} WERROR=0 -j${MAKE_THREADS} Image dtbs modules

    # Find the compiled DTB
    local dtb_path=""
    dtb_path=$(find arch/arm64/boot/dts/rockchip/ -name "${KERNEL_DTB}" | head -n1 || true)
    if [ -z "${dtb_path}" ]; then
        dtb_path=$(find arch/arm64/boot/dts/rockchip/ -name "rk3562-*.dtb" | grep -E 'linux|firefly|aio|evb' | head -n1 || true)
    fi
    if [ -z "${dtb_path}" ]; then
        dtb_path=$(find arch/arm64/boot/dts/rockchip/ -name "rk3562-*.dtb" | head -n1 || true)
    fi

    if [ -z "${dtb_path}" ]; then
        echo "[-] Error: Failed to find any rk3562 DTB in arch/arm64/boot/dts/rockchip/."
        exit 1
    fi

    cp "${dtb_path}" "${OUT_DIR}/boot/rk3562.dtb"
    cp arch/arm64/boot/Image "${OUT_DIR}/boot/Image"
    
    echo "[+] Using DTB: $(basename "${dtb_path}")"

    # Install modules for Debian rootfs
    echo "[*] Installing kernel modules..."
    rm -rf "${OUT_DIR}/modules_staging"
    mkdir -p "${OUT_DIR}/modules_staging"
    RKDEBIAN_ALLOW_WARNINGS=1 make ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE} modules_install \
        WERROR=0 \
        INSTALL_MOD_PATH="${OUT_DIR}/modules_staging"
    
    echo "[+] Kernel build complete."
    ensure_sdk_compat_layout
}

create_image() {
    echo "[*] Generating final SD card image..."
    cd "${ROOT_DIR}"
    
    # Setup extlinux.conf into boot folder
    mkdir -p "${OUT_DIR}/boot/extlinux"
    cp "${ROOT_DIR}/extlinux.conf" "${OUT_DIR}/boot/extlinux/extlinux.conf"

    for required in "${OUT_DIR}/idbloader.img" "${OUT_DIR}/u-boot.itb" "${OUT_DIR}/boot/Image" "${OUT_DIR}/boot/rk3562.dtb"; do
        if [ ! -f "${required}" ]; then
            echo "[-] Error: Missing build artifact: ${required}"
            exit 1
        fi
    done
    
    # Cleanup old artifacts
    rm -rf "${OUT_DIR}/tmp"
    mkdir -p "${OUT_DIR}/tmp"

    echo "[*] Creating rootfs.ext4 image..."
    rm -f "${OUT_DIR}/rootfs.ext4"

    # Size policy:
    # - default: auto (rootfs apparent size + headroom, aligned)
    #   * headroom: ROOTFS_HEADROOM_MB (default 512)
    #   * floor:    ROOTFS_MIN_MB      (default 2560)
    # - override: ROOTFS_IMAGE_SIZE=<size> (examples: 4G, 3584M)
    # The rootfs is expanded on first boot by expand-rootfs.service, so we keep
    # the build artifact compact while preserving enough installation headroom.
    local rootfs_image_size="${ROOTFS_IMAGE_SIZE:-auto}"
    if [ "${rootfs_image_size}" = "auto" ]; then
        local rootfs_used_bytes reserve_bytes min_bytes align_bytes size_bytes
        local reserve_mb min_mb
        reserve_mb="${ROOTFS_HEADROOM_MB:-512}"
        min_mb="${ROOTFS_MIN_MB:-2560}"
        case "${reserve_mb}" in
            ''|*[!0-9]*) reserve_mb=512 ;;
        esac
        case "${min_mb}" in
            ''|*[!0-9]*) min_mb=2560 ;;
        esac
        rootfs_used_bytes=$(sudo du -s -B1 "${OUT_DIR}/rootfs" | awk '{print $1}')
        reserve_bytes=$((reserve_mb * 1024 * 1024))
        min_bytes=$((min_mb * 1024 * 1024))
        align_bytes=$((64 * 1024 * 1024))       # align to 64 MiB
        size_bytes=$((rootfs_used_bytes + reserve_bytes))
        if [ "${size_bytes}" -lt "${min_bytes}" ]; then
            size_bytes="${min_bytes}"
        fi
        size_bytes=$(( ( (size_bytes + align_bytes - 1) / align_bytes ) * align_bytes ))
        echo "[*] rootfs usage: $((rootfs_used_bytes / 1024 / 1024)) MiB; headroom: ${reserve_mb} MiB; image size: $((size_bytes / 1024 / 1024)) MiB"
        truncate -s "${size_bytes}" "${OUT_DIR}/rootfs.ext4"
    else
        echo "[*] Using ROOTFS_IMAGE_SIZE=${rootfs_image_size}"
        truncate -s "${rootfs_image_size}" "${OUT_DIR}/rootfs.ext4"
    fi

    # NetworkManager refuses non-root-owned device plugins; fix ownership in
    # source rootfs before packing the final image.
    sudo find "${OUT_DIR}/rootfs/usr/lib" -type f -path '*/NetworkManager/*/libnm-*.so' \
        -exec chown root:root {} + 2>/dev/null || true

    sudo mkfs.ext4 -F \
        -L rootfs \
        -U c0ffee11-2233-4455-6677-8899aabbccdd \
        -d "${OUT_DIR}/rootfs" \
        -E lazy_itable_init=0,lazy_journal_init=0 \
        -O ^metadata_csum_seed,^orphan_file \
        "${OUT_DIR}/rootfs.ext4"

    # Keep a bit more usable free space on small images.
    sudo tune2fs -m 1 "${OUT_DIR}/rootfs.ext4" >/dev/null 2>&1 || true

    if ! sudo e2fsck -pf "${OUT_DIR}/rootfs.ext4"; then
        echo "[-] Error: rootfs.ext4 consistency check failed."
        exit 1
    fi
    
    sudo genimage \
        --config "${ROOT_DIR}/genimage.cfg" \
        --rootpath "${OUT_DIR}/rootfs" \
        --tmppath "${OUT_DIR}/tmp" \
        --inputpath "${OUT_DIR}" \
        --outputpath "${OUT_DIR}"

    cp -f "${OUT_DIR}/rk3562-debian.img" "${OUTPUT_DIR}/update/update.img"

    if [ -f "${OUT_DIR}/rootfs.ext4" ]; then
        ln -sfn "../out/rootfs.ext4" "${ROOT_DIR}/prebuilt_rootfs/rk3562_debian_rootfs.img"
    fi

    ensure_sdk_compat_layout
    
    echo "[+] Done! Image is available at ${OUT_DIR}/rk3562-debian.img"
    echo "[+] Firefly-compatible image path: ${OUTPUT_DIR}/update/update.img"
}

create_update_package() {
    echo "[*] Building offline update package..."
    local updater="${ROOT_DIR}/tools/make_update_tar.sh"
    if [ ! -x "${updater}" ]; then
        chmod +x "${updater}"
    fi
    "${updater}" "${OUTPUT_DIR}/update/update.tar.gz"
}

CMD="${1:-all}"

case "${CMD}" in
    check)
        check_deps
        ensure_sdk_compat_layout
        ;;
    lunch)
        ensure_sdk_compat_layout
        select_lunch
        ;;
    uboot)
        check_deps
        setup_dirs
        build_uboot
        ;;
    extboot)
        check_deps
        setup_dirs
        build_kernel
        ;;
    updateimg)
        create_image
        ;;
    updatepkg)
        create_update_package
        ;;
    compile)
        check_deps
        setup_dirs
        build_uboot
        build_kernel
        ;;
    rootfs)
        run_build_rootfs
        ;;
    image)
        create_image
        ;;
    all)
        check_deps
        setup_dirs
        build_uboot
        build_kernel
        run_build_rootfs
        create_image
        create_update_package
        ;;
    *)
        echo "Usage: $0 {check|lunch|uboot|extboot|updateimg|updatepkg|compile|rootfs|image|all}"
        exit 1
        ;;
esac
