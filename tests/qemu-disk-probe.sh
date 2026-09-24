#!/bin/bash
# qemu-disk-probe.sh: debug helper. Boots a minimal initramfs on QEMU with a
# virtio-blk disk and answers one question: do sparse writes with dd land on the
# device, from a pipe and from a file, in a guest with no rootfs? Prints the
# device contents (in the guest) and dumps the host-side file afterwards.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
KREL=6.18.53-ophub

docker run --rm --privileged -v /dev:/dev -v "$REPO/rootfs":/rootfs:ro alpine:3.22 sh -euxc '
apk add --no-cache qemu-system-aarch64 cpio gzip coreutils >/dev/null 2>&1
mkdir -p /t/ir/bin /t/ir/dev /t/ir/proc /t/ir/sys /t/ir/tmp /t/ir/lib/modules/'$KREL'
cp /rootfs/bin/busybox.static /t/ir/bin/busybox
ln -sf busybox /t/ir/bin/sh
mknod -m 600 /t/ir/dev/console c 5 1
mknod -m 666 /t/ir/dev/null c 1 3
for m in failover net_failover virtio_pci_modern_dev virtio_pci_legacy_dev virtio_pci virtio_blk virtio_net; do
  src=$(find /rootfs/lib/modules/'$KREL' -name "$m.ko" | head -1); [ -n "$src" ] && cp "$src" /t/ir/lib/modules/'$KREL'/
done
cat > /t/ir/init <<"EOS"
#!/bin/busybox sh
/bin/busybox --install -s /bin
mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev
mkdir -p /tmp; mount -t tmpfs tmpfs /tmp
for m in failover net_failover virtio_pci_modern_dev virtio_pci_legacy_dev virtio_pci virtio_blk virtio_net; do
  insmod /lib/modules/KREL/$m.ko 2>/dev/null || true
done
echo "probe> devices:"; ls /dev/vd* 2>/dev/null
echo "probe> vda size: $(cat /sys/class/block/vda/size 2>/dev/null)"
printf "AAAAAAAA" > /tmp/pat
echo "=== 1. write from a FILE with seek"
dd if=/tmp/pat of=/dev/vda bs=4096 count=1 seek=0 conv=notrunc 2>&1 | tail -2
echo "=== 2. write from a PIPE with seek"
printf "BBBBBBBB" | dd bs=4096 count=1 seek=1 of=/dev/vda conv=notrunc 2>&1 | tail -2
echo "=== 3. write from a PIPE to an explicit offset with skip/count like bmap-write"
printf "CCCCCCCC" | dd bs=4096 count=1 seek=2 of=/dev/vda conv=notrunc 2>&1 | tail -2
sync
echo "=== read back /dev/vda (first 16 KiB)"
od -A d -c -N 16384 /dev/vda | grep -v "^\*" | head -20
echo "=== host-side file after QEMU: dumped by the wrapper"
poweroff -f
EOS
sed -i "s/KREL/'$KREL'/" /t/ir/init
chmod 755 /t/ir/init
( cd /t/ir && find . | cpio -o -H newc --quiet | gzip -9 ) > /t/probe-initramfs.gz

truncate -s 4294967296 /t/probe.img
timeout 300 qemu-system-aarch64 \
  -machine virt -cpu cortex-a53 -m 512 \
  -kernel /rootfs/boot/vmlinuz-'$KREL' \
  -initrd /t/probe-initramfs.gz \
  -append "rdinit=/init console=ttyAMA0 net.ifnames=0 panic=1" \
  -drive file=/t/probe.img,format=raw,if=none,id=d0 \
  -device virtio-blk-pci,drive=d0 \
  -display none -monitor none -serial stdio -no-reboot 2>&1 | tail -30 || true

echo "=== host-side /t/probe.img, first 16 KiB"
od -A d -c -N 16384 /t/probe.img | grep -v "^\*" | head -20
'
