#!/bin/bash
# Bootstrap an aarch64 Alpine (v3.22 stable) rootfs for the X98H (Allwinner H618).
# Runs as root inside a throwaway Debian container; the host registers
# qemu-aarch64 binfmt with the F flag, so aarch64 binaries in the chroot run
# without copying qemu into it. Writes only into /work.
#
# Why a chroot instead of `apk.static --root`: apk-tools 3.x rejected every
# APKINDEX fetched through --root as UNTRUSTED even with the signing key in
# place, so the chroot path (native apk, minirootfs keys) is used instead.
set -euo pipefail

WORK=/work
ROOT="$WORK/rootfs"
BRANCH=v3.22
RELEASE=3.22.6
MIRROR=https://dl-cdn.alpinelinux.org/alpine
TARBALL=alpine-minirootfs-${RELEASE}-aarch64.tar.gz

mkdir -p "$ROOT"
if [ ! -f "$WORK/$TARBALL" ]; then
  curl -sSfLo "$WORK/$TARBALL" "$MIRROR/$BRANCH/releases/aarch64/$TARBALL"
fi
tar -xzf "$WORK/$TARBALL" -C "$ROOT"

printf '%s\n' "$MIRROR/$BRANCH/main" "$MIRROR/$BRANCH/community" > "$ROOT/etc/apk/repositories"
cp /etc/resolv.conf "$ROOT/etc/resolv.conf"

cleanup() {
  for m in proc dev sys; do
    mountpoint -q "$ROOT/$m" && umount -R "$ROOT/$m" || true
  done
}
trap cleanup EXIT

mount -t proc proc "$ROOT/proc"
mount --rbind /dev "$ROOT/dev"
mount --rbind /sys "$ROOT/sys"
mkdir -p "$ROOT/dev/pts"

echo "--- apk update"
chroot "$ROOT" /sbin/apk update

echo "--- apk add"
# dropbear replaces openssh-server (same authorized_keys, key-only login).
# openssh-client-default/-keygen stay for the ssh/scp/sftp, ssh-keygen CLIs.
chroot "$ROOT" /sbin/apk add --no-cache \
  alpine-base linux-lts alpine-conf \
  dropbear dropbear-openrc openssh-client-default openssh-keygen \
  e2fsprogs dosfstools

echo "--- installed kernel"
chroot "$ROOT" /sbin/apk info -e linux-lts || true
ls -lh "$ROOT/boot"

echo "--- h618 devicetrees present"
ls "$ROOT/boot/dtbs-lts/allwinner/" 2>/dev/null | grep h618 || true

cleanup
echo "--- rootfs size"
du -sh "$ROOT"
