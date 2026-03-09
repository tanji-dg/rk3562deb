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

## Firefly wiki compatibility

This project keeps a lightweight custom build pipeline, but now exposes Firefly-style layout and commands:

- SDK-style top-level paths: `kernel`, `u-boot`, `rkbin`, `prebuilt_rootfs`, `output/update`
- Firefly-style commands:

```bash
./build.sh lunch
./build.sh uboot
./build.sh extboot
./build.sh updateimg
./build.sh all
```

`./build.sh all` remains the recommended command for full Debian image generation.

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

## Notes

- Default user: `firefly` / `firefly`
- Root password: `root`
- Root filesystem auto-expands on first boot.
- Kernel DTB is auto-detected from RK3562 DTBs if the preferred DTB is unavailable.
