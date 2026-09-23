# alpine-solovox-z8pro

Alpine Linux SD/eMMC image for the Solovox Z8Pro, an X98H-clone Allwinner H618
TV box.

Builds a 4 GiB raw image (u-boot + BSP kernel + Alpine 3.22 rootfs) entirely on
an x86_64 host: no root, no card reader, no cross toolchain — a qemu binfmt
chroot bootstraps the rootfs and a privileged container assembles the image.

Quick start:

```bash
bash scripts/00-fetch-inputs.sh
docker run --rm --privileged -v "$PWD":/work debian:trixie bash /work/scripts/01-bootstrap-rootfs.sh
docker run --rm --privileged -v "$PWD":/work debian:trixie \
  bash -c 'apt-get update -qq && apt-get install -y -qq rsync e2fsprogs fdisk dosfstools device-tree-compiler && bash /work/scripts/02-configure-rootfs.sh'
docker run --rm --privileged -v /dev:/dev -v "$PWD":/work debian:trixie \
  bash -c 'apt-get update -qq && apt-get install -y -qq rsync e2fsprogs fdisk dosfstools device-tree-compiler && bash /work/scripts/03-build-image.sh'
```

Then flash `image/*.img` to an SD card and boot it.

Documentation: [docs/README.md](docs/README.md) — kernel choice (why the
Allwinner BSP kernel rather than mainline), image layout, package set, the Z8Pro
Ethernet PHY overlay, and open items.
