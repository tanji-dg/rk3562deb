#!/bin/bash
set -e

# Register the qemu-aarch64 binfmt handler so debootstrap's arm64 second stage
# and the chroot package installs can execute under emulation. The "F" (fix
# binary) flag is required so the interpreter keeps working inside the chroot.
register_binfmt() {
    if [ ! -d /proc/sys/fs/binfmt_misc ]; then
        echo "[!] binfmt_misc not available in kernel; arm64 chroot will fail." >&2
        return
    fi
    if [ ! -e /proc/sys/fs/binfmt_misc/register ]; then
        mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
    fi
    if [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        return
    fi
    printf '%s' ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\x00:/usr/bin/qemu-aarch64-static:OCF' \
        > /proc/sys/fs/binfmt_misc/register 2>/dev/null \
        || echo "[!] Could not register qemu-aarch64 binfmt (need --privileged)." >&2
}

register_binfmt

# The bind-mounted repo and cloned src/ are owned by the host user, but the
# build runs as root inside the container. Without this, git aborts with
# "detected dubious ownership" during kernel source restores/checkouts.
git config --global --add safe.directory '*' 2>/dev/null || true

status=0
"$@" || status=$?

# Hand build artifacts back to the host user instead of leaving them root-owned.
# CRITICAL: never chown the out/rootfs tree. Its files must stay root-owned (0:0)
# with setuid bits intact (e.g. pkexec 4755), or `chown` strips them and image
# packaging / profile verification fails.
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ] && [ "${HOST_UID}" != "0" ]; then
    if [ -d /build/out ]; then
        find /build/out -xdev \
            \( -path /build/out/rootfs -o -path '/build/out/rootfs/*' \) -prune -o \
            -exec chown "${HOST_UID}:${HOST_GID}" {} + 2>/dev/null || true
    fi
    for d in output src; do
        [ -e "/build/${d}" ] && chown -R "${HOST_UID}:${HOST_GID}" "/build/${d}" 2>/dev/null || true
    done
fi

exit "${status}"
