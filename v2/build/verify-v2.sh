#!/bin/bash
# Offline verification of the finished V2 image against the golden image (read-only loop mounts).
# usage: verify-v2.sh <v2.img> <golden.img (raw, verified)> <repo-dir>
set -o pipefail
IMG=$1; GOLD=$2; REPO=$3; fail=0
GOLDEN_GZ_SHA=016a11416caea7729f35006b83a8e2a003ba77defd4e3f1b6522fca9e69074aa
GOLDEN_IMG_SHA=c99b13ea629860a321ff489e4bcc53e651cc5a49b31e340733b8f999b5d6f0c6
chk(){ if eval "$2" >/dev/null 2>&1; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
sec(){ dd if="$1" bs=512 skip="$2" count="$3" status=none | sha256sum | cut -d' ' -f1; }
W=$(mktemp -d); trap 'umount $W/* 2>/dev/null; losetup -d $LV $LG 2>/dev/null; rm -rf $W' EXIT

echo "== golden reference"; chk "golden raw sha256 = $GOLDEN_IMG_SHA" "[ \$(sha256sum '$GOLD' | cut -d' ' -f1) = $GOLDEN_IMG_SHA ]"
echo "== boot chain preservation (sector hashes, V2 vs golden)"
for r in "idbloader:64:16320" "uboot.itb:16384:16384" "lba34-32767(all pre-p1):34:32734" "p1-BOOT:32768:1046528"; do
  IFS=: read -r n s c <<<"$r"; a=$(sec "$IMG" "$s" "$c"); b=$(sec "$GOLD" "$s" "$c")
  printf '   %-24s V2=%s\n   %-24s GOLD=%s\n' "$n" "$a" "" "$b"; chk "$n byte-identical" "[ $a = $b ]"
done
echo "== partition table"
sfdisk -d "$IMG"; chk "sfdisk --verify" "sfdisk --verify '$IMG'"; chk "sgdisk -v clean" "sgdisk -v '$IMG' | grep -q 'No problems found'"
for n in 1 2; do
  chk "p$n start/size/type/partuuid identical to golden" "[ \"\$(sfdisk -d '$IMG' | grep -E '^[^ ]+$n :' | sed 's/^[^:]*://')\" = \"\$(sfdisk -d '$GOLD' | grep -E '^[^ ]+$n :' | sed 's/^[^:]*://')\" ]"
done
chk "p3 RECOVERYLOG at 7223296 size 4194304 (after ROOTFS, at end)" "sfdisk -d '$IMG' | grep -E 'start= *7223296, size= *4194304,.*name=\"RECOVERYLOG\"'"
chk "backup GPT at last LBA of the image" "[ \$(sfdisk -d '$IMG' | awk '/^last-lba/{print \$2}') -le \$(( \$(stat -c %s '$IMG')/512 - 34 )) ] && sgdisk -v '$IMG' | grep -q 'No problems'"

LV=$(losetup -fP -r --show "$IMG"); LG=$(losetup -fP -r --show "$GOLD"); sleep 1
mkdir -p $W/vb $W/vr $W/vl $W/gb $W/gr
mount -o ro ${LV}p1 $W/vb; mount -o ro ${LV}p2 $W/vr; mount -o ro ${LV}p3 $W/vl; mount -o ro ${LG}p1 $W/gb; mount -o ro ${LG}p2 $W/gr
echo "== boot files (p1) V2 vs golden"
for f in vmlinuz-6.18.53-ophub uInitrd-6.18.53-ophub initrd.img-6.18.53-ophub dtb/rockchip/rk3568-ztl-a568.dtb boot.scr boot.cmd armbianEnv.txt; do
  a=$(sha256sum "$W/vb/$f" | cut -d' ' -f1); b=$(sha256sum "$W/gb/$f" | cut -d' ' -f1); echo "   $f $a"; chk "boot file $f identical" "[ $a = $b ]"; done
chk "Image/uInitrd symlinks identical" "[ \$(readlink $W/vb/Image) = \$(readlink $W/gb/Image) ] && [ \$(readlink $W/vb/uInitrd) = \$(readlink $W/gb/uInitrd) ]"
chk "boot.scr contains NO Great Wall stage-1" "! grep -aqi 'gwr' $W/vb/boot.scr"
chk "filesystem UUIDs/labels identical (BOOT/ROOTFS)" "[ \"\$(blkid -o export ${LV}p1 | grep -E '^(UUID|LABEL|TYPE)=')\$(blkid -o export ${LV}p2 | grep -E '^(UUID|LABEL|TYPE)=')\" = \"\$(blkid -o export ${LG}p1 | grep -E '^(UUID|LABEL|TYPE)=')\$(blkid -o export ${LG}p2 | grep -E '^(UUID|LABEL|TYPE)=')\" ]"
chk "fsck BOOT clean (e2fsck -fn)" "e2fsck -fn ${LV}p1"; chk "fsck ROOTFS clean (e2fsck -fn)" "e2fsck -fn ${LV}p2"
chk "fsck RECOVERYLOG clean (fsck.vfat -n)" "fsck.vfat -n ${LV}p3"
chk "RECOVERYLOG is FAT32 labelled RECOVERYLOG" "[ \"\$(blkid -s TYPE -o value ${LV}p3)\$(blkid -s LABEL -o value ${LV}p3)\" = vfatRECOVERYLOG ]"

echo "== ROOTFS: complete list of differences V2 vs golden"
diff -rq --no-dereference $W/gr $W/vr 2>&1 | sed "s#$W/##g" | tee $W/rootdiff.txt
echo "   (also: symlink-level listing)"; (cd $W/vr && find . -newer $W/gr/etc/armbian-release -path ./proc -prune -o -print 2>/dev/null | head -0)
R=$W/vr
chk "recovery script installed, identical to repo" "cmp $R/usr/local/sbin/gwr-recovery.sh $REPO/v2/rootfs/usr/local/sbin/gwr-recovery.sh && [ -x $R/usr/local/sbin/gwr-recovery.sh ]"
chk "unit installed, identical to repo" "cmp $R/etc/systemd/system/gwr-recovery.service $REPO/v2/rootfs/etc/systemd/system/gwr-recovery.service"
chk "unit enabled (multi-user.target.wants)" "[ \"\$(readlink $R/etc/systemd/system/multi-user.target.wants/gwr-recovery.service)\" = /etc/systemd/system/gwr-recovery.service ]"
chk "armbian-resize-filesystem NOT enabled" "! [ -e $R/etc/systemd/system/multi-user.target.wants/armbian-resize-filesystem.service ] && ! ls $R/etc/systemd/system/*.wants/ | grep -q resize"
chk "/root/.no_rootfs_resize present (resize script self-disables)" "[ -f $R/root/.no_rootfs_resize ]"
chk "no growroot/growpart/cloud-init in rootfs" "! [ -e $R/usr/share/initramfs-tools/hooks/growroot ] && ! [ -e $R/usr/bin/growpart ] && ! [ -d $R/etc/cloud ]"
chk "ssh masked" "[ \"\$(readlink $R/etc/systemd/system/ssh.service)\" = /dev/null ] && ! [ -e $R/etc/systemd/system/multi-user.target.wants/ssh.service ]"
chk "unattended-upgrades/apt timers disabled" "! [ -e $R/etc/systemd/system/multi-user.target.wants/unattended-upgrades.service ] && ! [ -e $R/etc/systemd/system/timers.target.wants/apt-daily-upgrade.timer ]"
chk "NetworkManager still enabled (network independent of recovery)" "[ -L $R/etc/systemd/system/multi-user.target.wants/NetworkManager.service ]"
chk "/etc/gwr-build-info present" "grep -q 'golden offline patch' $R/etc/gwr-build-info"
chk "unchanged root files are only those expected" "! grep -vE 'gwr-recovery|gwr-build-info|no_rootfs_resize|armbian-resize-filesystem.service|ssh\.(service|socket)|unattended-upgrades.service|apt-daily(-upgrade)?\.timer|^Only in gr/etc/systemd/system/timers.target.wants: (apt-daily|apt-daily-upgrade)' $W/rootdiff.txt | grep -q ."
for t in bash systemctl blockdev wipefs blkdiscard dd sfdisk gzip sha256sum e2fsck blkid lsblk findmnt mmc gpioset gpioinfo timeout flock cmp od udevadm journalctl mount umount mountpoint; do
  chk "dependency present in ROOTFS: $t" "chroot $R /bin/sh -c 'command -v $t' || ls $R/usr/bin/$t $R/usr/sbin/$t $R/bin/$t $R/sbin/$t"; done
chk "script does not need zstd/sgdisk/xxd" "! grep -qE '(^|[ |(])(zstd|zstdcat|sgdisk|xxd)( |$)' $R/usr/local/sbin/gwr-recovery.sh"
echo "== static safety review of the script INSIDE the image"
bash "$REPO/v2/tests/check-destructive.sh" $R/usr/local/sbin/gwr-recovery.sh $R/etc/systemd/system/gwr-recovery.service | tail -3
chk "check-destructive.sh on image copy" "bash '$REPO/v2/tests/check-destructive.sh' $R/usr/local/sbin/gwr-recovery.sh $R/etc/systemd/system/gwr-recovery.service"
chk "shellcheck -S error on image copy" "shellcheck -S error $R/usr/local/sbin/gwr-recovery.sh"
echo "== RECOVERYLOG payload"
ls -la $W/vl $W/vl/payload $W/vl/escalation
chk "payload golden.img.gz sha256 = $GOLDEN_GZ_SHA" "[ \$(sha256sum $W/vl/payload/golden.img.gz | cut -d' ' -f1) = $GOLDEN_GZ_SHA ]"
chk "payload decompresses to golden raw sha256" "[ \$(gzip -dc $W/vl/payload/golden.img.gz | sha256sum | cut -d' ' -f1) = $GOLDEN_IMG_SHA ]"
chk "target.img.sha256 / size / source files consistent" "grep -q $GOLDEN_IMG_SHA $W/vl/payload/target.img.sha256 && [ \$(cat $W/vl/payload/target.img.size) = 3699376128 ] && grep -q $GOLDEN_GZ_SHA $W/vl/payload/source-golden-sha256.txt"
chk "payload MANIFEST verifies" "cd $W/vl && sha256sum -c payload/MANIFEST.sha256"
chk "script constants match payload" "grep -q \"GOLDEN_IMG_SHA=\\\"$GOLDEN_IMG_SHA\\\"\" $R/usr/local/sbin/gwr-recovery.sh && grep -q \"GOLDEN_GZ_SHA=\\\"$GOLDEN_GZ_SHA\\\"\" $R/usr/local/sbin/gwr-recovery.sh"
chk "RECOVERY-RESULT.txt = NOT_RUN_YET; no runtime logs pre-baked" "grep -q NOT_RUN_YET $W/vl/RECOVERY-RESULT.txt && ! [ -e $W/vl/DONE.txt ] && ! [ -e $W/vl/STATE/terminal.done ] && ! [ -e $W/vl/recovery-run.log ]"
chk "free space on RECOVERYLOG > 1 GiB" "[ \$(df -B1 --output=avail $W/vl | tail -1) -gt 1073741824 ]"
echo; [ $fail = 0 ] && echo "VERIFY RESULT: ALL PASS" || echo "VERIFY RESULT: FAILURES PRESENT"
exit $fail
