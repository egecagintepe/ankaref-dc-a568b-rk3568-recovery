#!/bin/bash
# Runs inside the image chroot (Armbian userpatches hook). Recovery profile only.
set -euo pipefail
RELEASE=$1; LINUXFAMILY=$2; BOARD=$3
OV=/tmp/overlay

install -m 0755 $OV/gwr-recovery.sh /usr/local/sbin/gwr-recovery.sh
install -m 0644 $OV/gwr-recovery.service /etc/systemd/system/gwr-recovery.service
[ -f $OV/gwr-build-info ] && install -m 0644 $OV/gwr-build-info /etc/gwr-build-info
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/gwr-recovery.service /etc/systemd/system/multi-user.target.wants/gwr-recovery.service

# Recovery must never grow the root fs over the RECOVERYLOG partition appended later.
systemctl disable armbian-resize-filesystem.service 2>/dev/null || true
rm -f /root/.not_logged_in_yet
systemctl disable ssh.service 2>/dev/null || true

# Stage 1: prepend U-Boot probe to boot.cmd, immediately before bootargs are composed.
if [ -f /boot/boot.cmd ]; then
  awk -v snip="$OV/gwr-uboot-stage1.cmd" '
    /^setenv bootargs "root=/ && !done { while ((getline l < snip) > 0) print l; done=1 }
    { print }' /boot/boot.cmd > /boot/boot.cmd.new
  grep -q gwr_uboot_mmc /boot/boot.cmd.new || { echo "stage1 insertion FAILED"; exit 1; }
  mv /boot/boot.cmd.new /boot/boot.cmd
  mkimage -C none -A arm -T script -d /boot/boot.cmd /boot/boot.scr
else
  echo "no /boot/boot.cmd"; exit 1
fi
