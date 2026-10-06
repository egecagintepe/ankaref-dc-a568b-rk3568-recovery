#!/bin/bash
# Static verification of the finished image (read-only loop mounts of the IMAGE FILE).
set -uo pipefail
IMG=$1; fail=0
chk(){ if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
echo "== partition table"; sgdisk -p "$IMG"
chk "GPT valid" "sgdisk -v '$IMG' | grep -q 'No problems found'"
# bootloader placement: idbloader at LBA64 (RK BootROM), u-boot.itb at LBA16384
chk "idbloader at LBA64 non-empty" "[ \$(dd if='$IMG' bs=512 skip=64 count=64 status=none | tr -d '\000' | wc -c) -gt 1000 ]"
chk "u-boot.itb at LBA16384 (FIT magic d00dfeed)" "[ \"\$(dd if='$IMG' bs=512 skip=16384 count=1 status=none | head -c4 | xxd -p)\" = d00dfeed ]"
LO=$(sudo losetup -fP --show -r "$IMG"); trap 'sudo umount /mnt/v-root/boot 2>/dev/null; sudo umount /mnt/v-root /mnt/v-log 2>/dev/null; sudo losetup -d "$LO"' EXIT
sudo mkdir -p /mnt/v-root /mnt/v-log
ROOTP=$(sudo blkid -o device -t LABEL=armbi_root | grep "^$LO") ; BOOTP=$(sudo blkid -o device -t LABEL=armbi_boot | grep "^$LO" || true)
LOGP=$(sudo blkid -o device -t LABEL=RECOVERYLOG | grep "^$LO")
chk "root partition found" "[ -n '$ROOTP' ]"
sudo mount -o ro "$ROOTP" /mnt/v-root; [ -n "$BOOTP" ] && sudo mount -o ro "$BOOTP" /mnt/v-root/boot
sudo mount -o ro "$LOGP" /mnt/v-log
R=/mnt/v-root
chk "RECOVERYLOG is vfat FAT32" "sudo blkid -s TYPE -o value '$LOGP' | grep -qx vfat"
chk "rk3568-ztl-a568.dtb present" "ls $R/boot/dtb*/rockchip/rk3568-ztl-a568.dtb"
chk "boot fdtfile = ztl-a568" "grep -rq rk3568-ztl-a568 $R/boot/armbianEnv.txt $R/boot/boot.cmd || sudo grep -rq ztl-a568 $R/boot/armbianEnv.txt"
chk "kernel Image present" "ls $R/boot/Image* $R/boot/vmlinuz* 2>/dev/null | head -1 | grep -q ."
chk "initramfs (uInitrd) present" "ls $R/boot/uInitrd* | head -1 | grep -q ."
chk "boot.scr contains stage1" "grep -q gwr_uboot_mmc $R/boot/boot.cmd && strings $R/boot/boot.scr | grep -q gwr_uboot_mmc"
chk "recovery service enabled" "[ -L $R/etc/systemd/system/multi-user.target.wants/gwr-recovery.service ]"
chk "recovery script installed" "[ -x $R/usr/local/sbin/gwr-recovery.sh ]"
chk "resize service disabled" "! [ -L $R/etc/systemd/system/*.wants/armbian-resize-filesystem.service ]"
chk "payload present+sha" "[ -s /mnt/v-log/payload/target.img.zst ] && [ -s /mnt/v-log/payload/target.img.sha256 ]"
chk "guard present in script" "grep -q 'gwr_guard()' $R/usr/local/sbin/gwr-recovery.sh && grep -c 'gwr_guard \"' $R/usr/local/sbin/gwr-recovery.sh | awk '\$1>=6{f=1} END{exit !f}'"
# every destructive command must be preceded by a guard within the same block
chk "no destructive cmd on non-guarded device var" "! grep -nE '(blkdiscard|wipefs|dd .*of=)' $R/usr/local/sbin/gwr-recovery.sh | grep -vE '\\$DEV|WORK|\\$MNT|DA' "
exit $fail
