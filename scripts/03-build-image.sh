#!/bin/bash
# Build the flashable SD/eMMC image for the X98H: single ext4 partition that
# holds the whole Alpine rootfs (kernel, modules, extlinux.conf under /boot),
# plus the Allwinner bootloader written raw at KiB 8.
#
# u-boot's distro_bootcmd only scans partitions carrying the MBR bootable flag,
# so the partition must be marked bootable or the card boots nothing.
#
# Runs as root inside a privileged throwaway Debian container; writes /work.
set -euo pipefail

WORK=/work
ROOT="$WORK/rootfs"
UBOOT="$WORK/u-boot-sunxi-with-spl.bin"
IMGDIR="$WORK/image"
NAME=alpine-solovox-z8pro-3.22.6-6.18.53
IMG="$IMGDIR/$NAME.img"
KREL=6.18.53-ophub
SIZE_MB="${SIZE_MB:-4096}"
DISK_ID=abcd1234
ROOTFS_UUID=9f1c7a3e-5b21-4f8d-9a1c-7b2d4e6f8a90
LOOP=""
MOUNTED=0

[ -d "$ROOT" ] || { echo "rootfs missing: run 01/02 first" >&2; exit 1; }
[ -f "$UBOOT" ] || { echo "u-boot image missing: $UBOOT" >&2; exit 1; }

cleanup() {
  [ "$MOUNTED" = 1 ] && umount /mnt/target || true
  [ -n "$LOOP" ] && losetup -d "$LOOP" || true
}
trap cleanup EXIT

mkdir -p "$IMGDIR" /mnt/target
rm -f "$IMG"
truncate -s "${SIZE_MB}M" "$IMG"

echo "--- partition table"
sfdisk "$IMG" <<EOF
label: dos
label-id: 0x$DISK_ID
unit: sectors

start=2048, size=+, type=83, bootable
EOF

LOOP=$(losetup --find --show --partscan "$IMG")
sleep 1
P1="${LOOP}p1"
[ -b "$P1" ] || { echo "partition node $P1 missing" >&2; exit 1; }

echo "--- mkfs"
mkfs.ext4 -q -L rootfs -U "$ROOTFS_UUID" -m 1 "$P1"

echo "--- copy rootfs"
mount "$P1" /mnt/target
MOUNTED=1
rsync -aHAX --numeric-ids "$ROOT"/ /mnt/target/
sync
umount /mnt/target
MOUNTED=0
losetup -d "$LOOP"
LOOP=""

echo "--- write u-boot at KiB 8"
dd if="$UBOOT" of="$IMG" bs=1024 seek=8 conv=notrunc conv=fsync status=none
sync

echo "--- verify"
sfdisk -d "$IMG"
LOOP=$(losetup --find --show --partscan "$IMG")
sleep 1
P1="${LOOP}p1"
blkid "$P1" || true
fsck.ext4 -fn "$P1" || true
mount -o ro "$P1" /mnt/target
MOUNTED=1
echo "--- boot tree on image"
ls -l /mnt/target/boot /mnt/target/boot/extlinux
for chk in "/lib/modules/$KREL" "/boot/vmlinuz-$KREL" "/boot/dtbs/allwinner/sun50i-h618-x98h.dtb" "/boot/dtbs/allwinner/sun50i-h618-z8pro-ethfix.dtb" "/boot/dtbs/allwinner/overlay/sun50i-h618-z8pro.dtbo" "/boot/extlinux/extlinux.conf" "/sbin/init" "/usr/sbin/dropbear" "/etc/init.d/dropbear" "/etc/runlevels/default/dropbear" "/etc/runlevels/default/ntpd" "/etc/runlevels/boot/swclock" "/etc/conf.d/ntpd" "/usr/sbin/ota-flash" "/bin/busybox.static" "/boot/flash-initramfs.gz"; do
  # -L as well: /sbin/init is an absolute symlink and does not resolve on the host
  [ -e "/mnt/target$chk" ] || [ -L "/mnt/target$chk" ] || { echo "MISSING on image: $chk" >&2; exit 1; }
done
# openssh-server must not be present: dropbear is the ssh server here
[ -e /mnt/target/usr/sbin/sshd ] && { echo "openssh-server present on image (expected dropbear instead)" >&2; exit 1; }
echo "--- required paths present"
grep -q '^LABEL debug$' "$WORK/rootfs/boot/extlinux/extlinux.conf" || { echo "FAIL: debug label missing from extlinux.conf"; exit 1; }
grep -q '^LABEL flash$' "$WORK/rootfs/boot/extlinux/extlinux.conf" || { echo "FAIL: flash label missing from extlinux.conf"; exit 1; }
grep -q '^DEFAULT bsp$' "$WORK/rootfs/boot/extlinux/extlinux.conf" || { echo "FAIL: the image must boot bsp, not flash"; exit 1; }
gzip -dc "$WORK/rootfs/boot/flash-initramfs.gz" | cpio -t 2>/dev/null | grep -qx 'init' || { echo "FAIL: flash-initramfs.gz has no /init"; exit 1; }
{ [ -x "$WORK/rootfs/usr/sbin/resize2fs" ] || [ -x "$WORK/rootfs/sbin/resize2fs" ]; } || { echo "FAIL: resize2fs missing from the rootfs (no card expansion possible)"; exit 1; }
[ -x "$WORK/rootfs/etc/init.d/growfs" ] || { echo "FAIL: growfs service missing from the rootfs"; exit 1; }
[ -L "$WORK/rootfs/etc/runlevels/boot/growfs" ] || { echo "FAIL: growfs is not enabled in the boot runlevel"; exit 1; }
[ -x "$WORK/rootfs/etc/init.d/mdev-hotplug" ] || { echo "FAIL: mdev-hotplug service missing (hotplug would be dead)"; exit 1; }
[ -L "$WORK/rootfs/etc/runlevels/boot/mdev-hotplug" ] || { echo "FAIL: mdev-hotplug is not enabled in the boot runlevel"; exit 1; }
grep -q 'read_mbr_entry' "$WORK/rootfs/boot/flash-initramfs.gz" 2>/dev/null || true
echo "--- extlinux.conf"
cat /mnt/target/boot/extlinux/extlinux.conf
echo "--- u-boot magic on image"
od -A d -t x1 -N 16 -j 8192 "$IMG"
umount /mnt/target
MOUNTED=0
losetup -d "$LOOP"
LOOP=""

echo "--- image"
ls -lh "$IMG"
sha256sum "$IMG" | tee "$IMG.sha256"
# The build runs as root inside the container; hand the artifacts to whoever
# owns the workspace so later steps (publish) can rewrite the sidecars.
chown "$(stat -c '%u:%g' "$WORK")" "$IMG" "$IMG.sha256"
