# RK3562 Debian 12 (XFCE4) Image Builder

This project builds a bootable Debian 12 (Bookworm) SD card image for RK3562 boards with XFCE4.

## One-command build

From the project root:

```bash
chmod +x build build.sh build_rootfs.sh
./build all
```

Output image:

- `out/rk3562-debian.img`
- `output/update/update.img` (Firefly wiki-compatible path)
- `output/update/update.tar.gz` (offline boot-time update package)

## Firefly wiki compatibility

This project keeps a lightweight custom build pipeline, but now exposes Firefly-style layout and commands:

- SDK-style top-level paths: `kernel`, `u-boot`, `rkbin`, `prebuilt_rootfs`, `output/update`
- Firefly-style commands:

```bash
./build.sh lunch
./build.sh uboot
./build.sh extboot
./build.sh updateimg
./build.sh updatepkg
./build.sh all
```

`./build.sh all` remains the recommended command for full Debian image generation.
`./build.sh updatepkg` builds only the boot-time update tarball from current `out/rootfs` + `out/boot`.

## Prerequisites (Ubuntu/Debian host)

```bash
sudo apt update
sudo apt install -y \
  git make gcc-aarch64-linux-gnu bc bison flex device-tree-compiler \
  genimage wget tar mtools debootstrap qemu-user-static e2fsprogs
```

## Flash image to SD card

Replace `/dev/sdX` with your SD card device:

```bash
sudo dd if=out/rk3562-debian.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

## Offline update package (no SD removal)

1. Build/update package on host:

```bash
./build.sh updatepkg
```

2. Copy package to device:

```bash
scp output/update/update.tar.gz chaos@<board-ip>:/home/chaos/
ssh chaos@<board-ip> 'sudo install -d -m 0775 -o chaos -g chaos /update && sudo mv /home/chaos/update.tar.gz /update/update.tar.gz'
```

3. Reboot the device. On boot, `rk-apply-update.service` will:
- detect `/update/update.tar.gz`
- apply `rootfs/` payload onto `/`
- apply `boot/` payload to `/boot` when available
- archive package to `/update/update-applied-<timestamp>.tar.gz`
- reboot once to finalize

## Notes

- Default user: `chaos` / `chaos`
- Root password: `root`
- Root filesystem auto-expands on first boot.
- Kernel DTB is auto-detected from RK3562 DTBs if the preferred DTB is unavailable.
