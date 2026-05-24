FROM debian:bookworm

# RK3562 Debian image build environment.
# Mirrors the host dependencies listed in README.md plus the bits needed to run
# the build as root inside a privileged container (debootstrap arm64 chroot via
# qemu-user-static, genimage, sudo).
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        git make \
        gcc-aarch64-linux-gnu \
        build-essential \
        bc bison flex device-tree-compiler \
        genimage wget tar mtools dosfstools \
        xz-utils \
        debootstrap qemu-user-static binfmt-support \
        e2fsprogs \
        sudo \
        python3 python3-dev python3-setuptools \
        python3-pyelftools python3-pkg-resources \
        libssl-dev libelf-dev libgnutls28-dev uuid-dev \
        swig pkg-config \
        cpio kmod rsync file \
    && rm -rf /var/lib/apt/lists/*

# Firefly's U-Boot make.sh gates the FIT packaging step on `which python2`, but
# Debian 12 ships no python2. The packaging path itself (scripts/fit*.sh) drives
# mkimage/dtc and does not actually execute Python, so a python3 shim satisfies
# the gate without behavioural impact.
RUN ln -sf /usr/bin/python3 /usr/local/bin/python2 \
    && ln -sf /usr/bin/python3 /usr/local/bin/python

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /build
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["./build.sh", "all"]
