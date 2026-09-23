#!/bin/bash
# Configure the bootstrapped Alpine rootfs for the X98H and drop in the
# Allwinner BSP kernel (6.18.53-ophub) that the box is known to boot with.
#
# Kernel choice: mainline has no node or driver for the X98H's wired port
# (sun50i-h616.dtsi defines only emac0; the X98H PHY hangs off emac1/RMII in
# the vendor DTB), so the BSP kernel + BSP DTB is used for hardware support.
# The Alpine linux-lts kernel stays on disk as a second extlinux entry.
#
# Runs as root inside a throwaway Debian container; writes only into /work.
set -euo pipefail

WORK=/work
ROOT="$WORK/rootfs"
KREL=6.18.53-ophub
KDIR=6.18.53
BOARD_HOSTNAME=x98h
ROOT_PARTUUID=abcd1234-01
TZ_NAME=Asia/Ho_Chi_Minh
SSH_PUBKEY_FILE="$WORK/x98h/authorized_keys"

[ -d "$ROOT" ] || { echo "rootfs missing: run 01 first" >&2; exit 1; }

cleanup() {
  for m in proc dev sys; do
    mountpoint -q "$ROOT/$m" && umount -R "$ROOT/$m" || true
  done
}
trap cleanup EXIT

mount -t proc proc "$ROOT/proc"
mount --rbind /dev "$ROOT/dev"
mount --rbind /sys "$ROOT/sys"

echo "--- extra packages"
chroot "$ROOT" /sbin/apk add --no-cache tzdata ifupdown-ng

echo "--- base config files"
printf '%s\n' "$BOARD_HOSTNAME" > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<EOF
127.0.0.1	localhost.localdomain localhost $BOARD_HOSTNAME
::1		localhost.localdomain localhost $BOARD_HOSTNAME
EOF

cat > "$ROOT/etc/fstab" <<EOF
# <file system>	<mount point>	<type>	<options>		<dump>	<pass>
UUID=9f1c7a3e-5b21-4f8d-9a1c-7b2d4e6f8a90	/	ext4	noatime,errors=remount-ro	0	1
EOF

cat > "$ROOT/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

printf '%s\n' "$TZ_NAME" > "$ROOT/etc/timezone"
ln -sf "/usr/share/zoneinfo/$TZ_NAME" "$ROOT/etc/localtime"

# Key-only remote login: dropbear host keys are generated on first start by
# dropbear-openrc; -s disables password auth (root's password is locked anyway).
cat > "$ROOT/etc/conf.d/dropbear" <<'EOF'
DROPBEAR_OPTS="-s"
DROPBEAR_BANNER=""
EOF
mkdir -p "$ROOT/root/.ssh"
install -m 600 "$SSH_PUBKEY_FILE" "$ROOT/root/.ssh/authorized_keys"

echo "--- enable services"
for svc in bootmisc devfs dmesg hwdrivers mdev modules root sysctl urandom syslog; do
  [ -x "$ROOT/etc/init.d/$svc" ] && ln -sf "/etc/init.d/$svc" "$ROOT/etc/runlevels/boot/$svc"
done
for svc in networking dropbear crond local; do
  [ -x "$ROOT/etc/init.d/$svc" ] && ln -sf "/etc/init.d/$svc" "$ROOT/etc/runlevels/default/$svc"
done
[ -x "$ROOT/etc/init.d/hostname" ] && ln -sf /etc/init.d/hostname "$ROOT/etc/runlevels/boot/hostname"

echo "--- BSP kernel files into /boot"
mkdir -p "$ROOT/boot/dtbs/allwinner/overlay" "$ROOT/boot/extlinux"
install -m 755 "$WORK/kernel/boot/vmlinuz-$KREL" "$ROOT/boot/vmlinuz-$KREL"
install -m 644 "$WORK/kernel/boot/System.map-$KREL" "$ROOT/boot/System.map-$KREL"
install -m 644 "$WORK/kernel/boot/config-$KREL" "$ROOT/boot/config-$KREL"
install -m 644 "$WORK/kernel/dtbs/sun50i-h618-x98h.dtb" "$ROOT/boot/dtbs/allwinner/sun50i-h618-x98h.dtb"

echo "--- Z8Pro / X98H-clone ethernet overlay -> merged DTB"
# Overlay sets the emac1 MDIO PHY reg from 1 to 0 (clone PHY strapping).
# Merged at build time: the kernel has no initramfs here to apply overlays,
# and this u-boot is not relied on for FDTOVERLAYS support.
dtc -@ -I dts -O dtb -o "$WORK/x98h/sun50i-h618-z8pro.dtbo" "$WORK/x98h/sun50i-h618-z8pro-overlay.dts" 2>/dev/null
fdtoverlay -i "$ROOT/boot/dtbs/allwinner/sun50i-h618-x98h.dtb" \
           -o "$ROOT/boot/dtbs/allwinner/sun50i-h618-x98h-ethfix.dtb" \
           "$WORK/x98h/sun50i-h618-z8pro.dtbo"
install -m 644 "$WORK/x98h/sun50i-h618-z8pro.dtbo" "$ROOT/boot/dtbs/allwinner/overlay/"
# The merge must actually have landed: PHY reg 0x00 on the emac1 MDIO bus.
dtc -I dtb -O dts "$ROOT/boot/dtbs/allwinner/sun50i-h618-x98h-ethfix.dtb" 2>/dev/null \
  | sed -n '/ethernet-phy@1/,/};/p' | grep -q "reg = <0x00>" \
  || { echo "ethfix overlay did not apply (PHY reg still 1)" >&2; exit 1; }
echo "    merged: $(ls -l "$ROOT/boot/dtbs/allwinner/sun50i-h618-x98h-ethfix.dtb" | awk '{print $5}') bytes"

echo "--- BSP modules into /lib/modules"
# The tarball's top-level directory is already named <KREL>, so it must be
# unpacked into /lib/modules or the modules land at /<KREL>.
rm -rf "$ROOT/$KREL" "$ROOT/lib/modules/$KREL"
mkdir -p "$ROOT/lib/modules"
tar -xzf "$WORK/kernel/$KDIR/modules-$KREL.tar.gz" -C "$ROOT/lib/modules"
ls "$ROOT/lib/modules"
[ -d "$ROOT/lib/modules/$KREL" ] || { echo "BSP modules did not extract to /lib/modules/$KREL" >&2; exit 1; }

echo "--- extlinux.conf"
cat > "$ROOT/boot/extlinux/extlinux.conf" <<EOF
TIMEOUT 30
DEFAULT bsp
MENU TITLE X98H Alpine

LABEL bsp
  MENU LABEL Alpine (BSP kernel $KREL, Z8Pro ethfix)
  LINUX /boot/vmlinuz-$KREL
  FDT /boot/dtbs/allwinner/sun50i-h618-x98h-ethfix.dtb
  APPEND root=PARTUUID=$ROOT_PARTUUID rw rootwait console=tty0 console=ttyS0,115200 no_console_suspend consoleblank=0 max_loop=128 net.ifnames=0 video=HDMI-A-1:1920x1080@60e

LABEL bsp-nofix
  MENU LABEL Alpine (BSP kernel $KREL, unpatched vendor DTB)
  LINUX /boot/vmlinuz-$KREL
  FDT /boot/dtbs/allwinner/sun50i-h618-x98h.dtb
  APPEND root=PARTUUID=$ROOT_PARTUUID rw rootwait console=tty0 console=ttyS0,115200 no_console_suspend consoleblank=0 max_loop=128 net.ifnames=0 video=HDMI-A-1:1920x1080@60e

LABEL mainline
  MENU LABEL Alpine (mainline linux-lts, no wired ethernet)
  LINUX /boot/vmlinuz-lts
  INITRD /boot/initramfs-lts
  FDT /boot/dtbs-lts/allwinner/sun50i-h618-transpeed-8k618-t.dtb
  APPEND root=PARTUUID=$ROOT_PARTUUID rw rootwait console=tty0 console=ttyS0,115200 max_loop=128 net.ifnames=0
EOF

echo "--- resulting /boot"
ls -lh "$ROOT/boot"

cleanup
echo "--- rootfs size"
du -sh "$ROOT"
