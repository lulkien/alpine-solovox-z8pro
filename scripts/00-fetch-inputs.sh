#!/bin/bash
# Download and verify every build input that is too large or too stable
# upstream to commit. Run from the repository root:
#
#   bash scripts/00-fetch-inputs.sh
#
# Produces: u-boot-sunxi-with-spl.bin, alpine-minirootfs-*.tar.gz and
# kernel/{6.18.53.tar.gz, 6.18.53/, boot/, dtbs/}.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

KREL=6.18.53-ophub
KDIR=6.18.53
ALPINE_BRANCH=v3.22
ALPINE_RELEASE=3.22.6
ALPINE_MIRROR=https://dl-cdn.alpinelinux.org/alpine
MINIROOTFS=alpine-minirootfs-$ALPINE_RELEASE-aarch64.tar.gz
UBOOT=u-boot-sunxi-with-spl.bin

KERNEL_URL=https://github.com/ophub/kernel/releases/download/kernel_stable/$KDIR.tar.gz
UBOOT_URL=https://raw.githubusercontent.com/ophub/u-boot/main/u-boot/allwinner/x98h/$UBOOT
MINIROOTFS_URL=$ALPINE_MIRROR/$ALPINE_BRANCH/releases/aarch64/$MINIROOTFS

KERNEL_SHA=269dd8ded019f829723968a236bac40335dc9488aac8f22cf1afd5b9f3a20bb7
UBOOT_SHA=4c6afa2ef90610318dbd4f9a201a432610eb0eb025afd06e8d7bf69c17309e96
MINIROOTFS_SHA=821565fa8f3953eefd12497b166b4b50add2f7c57fb312e75862f5867e06fefe

check() {
  echo "$2  $1" | sha256sum -c -
}

fetch() {
  url=$1 out=$2
  if [ -f "$out" ]; then
    echo "have $out"
  else
    echo "fetch $url"
    curl -sSfL --retry 3 -o "$out.part" "$url"
    mv "$out.part" "$out"
  fi
}

fetch "$UBOOT_URL" "$UBOOT"
check "$UBOOT" "$UBOOT_SHA"

fetch "$MINIROOTFS_URL" "$MINIROOTFS"
check "$MINIROOTFS" "$MINIROOTFS_SHA"

mkdir -p kernel
fetch "$KERNEL_URL" "kernel/$KDIR.tar.gz"
check "kernel/$KDIR.tar.gz" "$KERNEL_SHA"

if [ ! -d "kernel/$KDIR" ]; then
  tar -xzf "kernel/$KDIR.tar.gz" -C kernel
fi

if [ ! -d kernel/boot ]; then
  mkdir -p kernel/boot kernel/dtbs
  tar -xzf "kernel/$KDIR/boot-$KREL.tar.gz" -C kernel/boot
  tar -xzf "kernel/$KDIR/dtb-allwinner-$KREL.tar.gz" -C kernel/dtbs
fi

echo
echo "inputs ready:"
ls -l "$UBOOT" "$MINIROOTFS" kernel/"$KDIR".tar.gz
ls -d kernel/boot kernel/dtbs kernel/"$KDIR" | sed 's/^/  /'
