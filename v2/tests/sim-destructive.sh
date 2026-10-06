#!/bin/bash
# Safe simulation of the destructive flow against DISPOSABLE loop-backed images + a FAKE sysfs tree.
# No physical disk is ever touched. A private $DEVDIR holds mmcblkNN symlinks -> loop devices so the
# guard's node-name rules apply exactly as on hardware. Builds a fake /sys mirror so the guard, erase,
# write/verify, install, GPT-relocate and partition-discovery logic all run end to end.
# usage: sim-destructive.sh <repo-dir> <golden.img.gz>
set -u
REPO=$1; GZ=$2
SCRIPT=$REPO/v2/rootfs/usr/local/sbin/gwr-recovery.sh
GOLDEN_IMG_SHA=c99b13ea629860a321ff489e4bcc53e651cc5a49b31e340733b8f999b5d6f0c6
W=$(mktemp -d /root/gw2/sim.XXXX); pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
cleanup(){ set +e; for l in $(cat $W/loops 2>/dev/null); do umount ${l}* 2>/dev/null; losetup -d $l 2>/dev/null; done; umount $W/mnt-busy 2>/dev/null; rm -rf $W; }
trap cleanup EXIT
: > $W/loops
mkdir -p $W/dev $W/work $W/log

# fake sysfs for ONE eMMC block node on fe310000.mmc. $1 sysroot $2 nodename $3 size $4 removable $5 type $6 major
# (SD node mmcblk0 on fe2b0000 is always added.)
mkfake(){ local S=$1 N=$2 SZ=$3 RM=$4 TY=$5 MJ=$6
  rm -rf $S; local P=$S/sys/devices/platform
  mkdir -p $P/fe310000.mmc/mmc_host/mmc1/mmc1:0001/block/$N/device $P/fe310000.mmc/mmc_host/mmc1/mmc1:0001/block/$N/queue
  mkdir -p $S/sys/bus/platform/devices $S/sys/block
  ln -sfn ../../../devices/platform/fe310000.mmc $S/sys/bus/platform/devices/fe310000.mmc
  ln -sfn ../../../devices/platform/fe2b0000.mmc $S/sys/bus/platform/devices/fe2b0000.mmc
  local b=$P/fe310000.mmc/mmc_host/mmc1/mmc1:0001/block/$N
  echo "$RM" > $b/removable; echo "$TY" > $b/device/type; echo "$MJ:0" > $b/dev; echo 0 > $b/queue/discard_max_bytes
  ln -sfn ../devices/platform/fe310000.mmc/mmc_host/mmc1/mmc1:0001/block/$N $S/sys/block/$N
  # SD node mmcblk0 on fe2b0000
  local sb=$P/fe2b0000.mmc/mmc_host/mmc0/mmc0:0002/block/mmcblk0
  mkdir -p $sb/device $sb/queue; echo 0 > $sb/removable; echo MMC > $sb/device/type; echo 179:0 > $sb/dev; echo 0 > $sb/queue/discard_max_bytes
  ln -sfn ../devices/platform/fe2b0000.mmc/mmc_host/mmc0/mmc0:0002/block/mmcblk0 $S/sys/block/mmcblk0
}
sz_set(){ local b=$1/sys/devices/platform/fe310000.mmc/mmc_host/mmc1/mmc1:0001/block/$2; :; }  # size comes from blockdev on the loop

run_guard(){ # $1 sysroot $2 target-node-path $3 rootdisk $4 logdisk
  GWR_TEST_MODE=1 GWR_TEST_SYSROOT="$1" GWR_TEST_DEVDIR="$W/dev" GWR_TEST_WORK="$W/work" \
  GWR_TEST_ROOTDISK="$3" GWR_TEST_LOGDIR="$W/log" GWR_TEST_LOGDEV="" GWR_TEST_LOGDISK="$4" \
  GWR_TEST_GUARD_ONLY="$2" bash "$SCRIPT" >/dev/null 2>$W/guard.err; return $?
}

echo "===== GUARD NEGATIVE/POSITIVE MATRIX ====="
truncate -s 31268536320 $W/emmc.img      # 29.1 GiB
truncate -s 8000000000  $W/small.img
truncate -s 495000000000 $W/sd.img       # 461 GiB sparse
LE=$(losetup -fP --show $W/emmc.img); echo $LE >> $W/loops
LS=$(losetup -fP --show $W/sd.img);   echo $LS >> $W/loops
LB=$(losetup -fP --show $W/small.img);echo $LB >> $W/loops
ln -sf $LE $W/dev/mmcblk1      # eMMC target
ln -sf $LS $W/dev/mmcblk0      # SD
ln -sf $LB $W/dev/mmcblk2      # undersized

S=$W/sysA; mkfake $S mmcblk1 31268536320 0 MMC 179
run_guard $S $W/dev/mmcblk1 /dev/mmcblk0 ""           && ok "good eMMC accepted" || no "good eMMC rejected ($(tail -1 $W/guard.err))"
run_guard $S $W/dev/mmcblk1 $W/dev/mmcblk1 ""         && no "root-disk target accepted" || ok "rejects target == root disk"
run_guard $S $W/dev/mmcblk1 /dev/mmcblk0 $W/dev/mmcblk1 && no "log-disk target accepted" || ok "rejects target == RECOVERYLOG disk"
# SD host: point mmcblk1 symlink at the SD loop AND make fake host say removable SD... instead use a node whose sysfs is on fe2b0000:
S_sd=$W/sysSD; mkfake $S_sd mmcblk0 495000000000 0 MMC 179   # mmcblk0 only exists on SD host in this fake
run_guard $S_sd $W/dev/mmcblk0 /dev/mmcblkX ""        && no "SD host accepted" || ok "rejects SD host fe2b0000"
S2=$W/sysB; mkfake $S2 mmcblk2 8000000000 0 MMC 179
run_guard $S2 $W/dev/mmcblk2 /dev/mmcblk0 ""          && no "undersized accepted" || ok "rejects capacity < 20 GiB"
S3=$W/sysC; mkfake $S3 mmcblk1 31268536320 1 MMC 179
run_guard $S3 $W/dev/mmcblk1 /dev/mmcblk0 ""          && no "removable accepted" || ok "rejects removable=1"
S4=$W/sysD; mkfake $S4 mmcblk1 31268536320 0 SD 179
run_guard $S4 $W/dev/mmcblk1 /dev/mmcblk0 ""          && no "type SD accepted" || ok "rejects type != MMC"
S5=$W/sysE; mkfake $S5 mmcblk1 31268536320 0 MMC 8
run_guard $S5 $W/dev/mmcblk1 /dev/mmcblk0 ""          && no "major 8 accepted" || ok "rejects non-179 major"
S6=$W/sysF; mkfake $S6 mmcblk1 31268536320 0 MMC 179
P6=$S6/sys/devices/platform/fe310000.mmc/mmc_host/mmc1/mmc1:0003/block/mmcblk9
mkdir -p $P6/device; echo 0 > $P6/removable; echo MMC > $P6/device/type; echo 179:9 > $P6/dev
ln -sfn ../devices/platform/fe310000.mmc/mmc_host/mmc1/mmc1:0003/block/mmcblk9 $S6/sys/block/mmcblk9
run_guard $S6 $W/dev/mmcblk1 /dev/mmcblk0 ""          && no "ambiguous host accepted" || ok "rejects >1 device on eMMC host"
S7=$W/sysG; mkfake $S7 mmcblk1 31268536320 0 MMC 179
mkdir -p $W/mnt-busy; mkfs.ext4 -qF -O ^has_journal $LE 2>/dev/null; mount $LE $W/mnt-busy 2>/dev/null; grep -q mnt-busy /proc/mounts && echo "   (target mounted for test)" || echo "   (WARN mount failed)"
run_guard $S7 $W/dev/mmcblk1 /dev/mmcblk0 ""          && no "mounted target accepted" || ok "rejects mounted target"
umount $W/mnt-busy 2>/dev/null

echo "===== FULL DESTRUCTIVE FLOW ON A FAKE 'eMMC' (24 GiB sparse loop) ====="
truncate -s $((24*1024*1024*1024)) $W/target.img
LT=$(losetup -fP --show $W/target.img); echo $LT >> $W/loops
ln -sf $LT $W/dev/mmcblk1
ST=$W/sysT; mkfake $ST mmcblk1 $((24*1024*1024*1024)) 0 MMC 179
dd if=/dev/urandom of=$LT bs=1M count=8 conv=notrunc status=none   # dirty the start
cat > $W/partscan.sh <<PS
#!/bin/bash
partx -d $LT 2>/dev/null; partx -a $LT 2>/dev/null
B=$ST/sys/devices/platform/fe310000.mmc/mmc_host/mmc1/mmc1:0001/block/mmcblk1
for pn in 1 2; do
  [ -b ${LT}p\$pn ] || continue
  mkdir -p \$B/mmcblk1p\$pn
  echo \$pn > \$B/mmcblk1p\$pn/partition
  cat /sys/block/$(basename $LT)/$(basename $LT)p\$pn/start > \$B/mmcblk1p\$pn/start
  cat /sys/block/$(basename $LT)/$(basename $LT)p\$pn/size  > \$B/mmcblk1p\$pn/size
  ln -sf ${LT}p\$pn $W/dev/mmcblk1p\$pn
done
PS
chmod +x $W/partscan.sh
mkdir -p $W/log/payload; cp $GZ $W/log/payload/golden.img.gz
echo "$GOLDEN_IMG_SHA  golden.img" > $W/log/payload/target.img.sha256; echo 3699376128 > $W/log/payload/target.img.size

echo "-- running full flow (TEST mode, real loop I/O, fake sysfs, NODISCARD -> zero-write path)"
GWR_TEST_MODE=1 GWR_TEST_SYSROOT=$ST GWR_TEST_DEVDIR=$W/dev GWR_TEST_WORK=$W/work \
GWR_TEST_ROOTDISK=/dev/mmcblk0 GWR_TEST_LOGDIR=$W/log GWR_TEST_LOGDEV="" GWR_TEST_LOGDISK="" \
GWR_TEST_NODISCARD=1 GWR_TEST_PARTSCAN_HOOK=$W/partscan.sh \
timeout 2400 bash "$SCRIPT" > $W/flow.log 2>&1
RES=$(cat $W/work/test-result 2>/dev/null); echo "   flow result: $RES"
DA=$W/log/destructive-actions.txt
grep -qE 'GUARD PASS' $DA && ok "guard ran before destructive ops" || no "no guard in destructive log"
grep -q 'wipefs exit=0' $DA && ok "wipefs executed" || no "wipefs"
grep -qE 'zero-write exit=(0|1)' $DA && ok "zero-write fallback executed (no discard)" || no "zero-write"
[ "$(dd if=$LT bs=1M count=8 status=none | tr -d '\0' | wc -c)" -lt 1000000 ] && ok "device start cleared by erase" || no "erase did not clear start"
grep -q 'verify chunk=.* OK' $DA && ! grep -q 'MISMATCH' $DA && ok "random write/read-back verify OK at all points" || no "verify mismatch"
grep -q "read-back sha256 .*= $GOLDEN_IMG_SHA expected $GOLDEN_IMG_SHA" $DA && ok "post-install read-back SHA256 == golden" || no "install read-back sha"
grep -q 'relocate exit=0' $DA && grep -q 'sfdisk --verify exit=0' $DA && ok "GPT backup relocated + verified on target" || no "GPT relocate"
[ "$RES" = EMMC_RECOVERED_AND_LINUX_INSTALLED ] && ok "terminal result EMMC_RECOVERED_AND_LINUX_INSTALLED" || no "unexpected terminal result: $RES"
[ -f $W/log/STATE/terminal.done ] && ok "terminal.done written" || no "terminal.done missing"

echo "-- second run must NOT re-erase (terminal.done present)"
dd if=/dev/urandom of=$LT bs=1M count=1 seek=100 conv=notrunc status=none
marker=$(dd if=$LT bs=1M count=1 skip=100 status=none | sha256sum | cut -d' ' -f1)
GWR_TEST_MODE=1 GWR_TEST_SYSROOT=$ST GWR_TEST_DEVDIR=$W/dev GWR_TEST_WORK=$W/work2 \
GWR_TEST_ROOTDISK=/dev/mmcblk0 GWR_TEST_LOGDIR=$W/log GWR_TEST_LOGDEV="" GWR_TEST_LOGDISK="" \
timeout 120 bash "$SCRIPT" > $W/flow2.log 2>&1
[ "$(cat $W/work2/test-result)" = ALREADY_COMPLETED ] && ok "re-run short-circuits to ALREADY_COMPLETED" || no "re-run did not short-circuit"
[ "$(dd if=$LT bs=1M count=1 skip=100 status=none | sha256sum | cut -d' ' -f1)" = "$marker" ] && ok "re-run left device untouched" || no "re-run modified device"

echo "-- STUCK path: eMMC host present, NO block device -> EMMC_STUCK_NOT_READY, zero destructive ops"
SN=$W/sysN; mkdir -p $SN/sys/devices/platform/fe310000.mmc/mmc_host/mmc1 $SN/sys/block $SN/sys/bus/platform/devices
ln -sfn ../../../devices/platform/fe310000.mmc $SN/sys/bus/platform/devices/fe310000.mmc
GWR_TEST_MODE=1 GWR_TEST_SYSROOT=$SN GWR_TEST_DEVDIR=$W/dev GWR_TEST_WORK=$W/work3 \
GWR_TEST_ROOTDISK=/dev/mmcblk0 GWR_TEST_LOGDIR=$W/log3 GWR_TEST_LOGDEV="" GWR_TEST_LOGDISK="" \
GWR_TEST_FORCE_STUCK=1 timeout 120 bash "$SCRIPT" > $W/flow3.log 2>&1
R3=$(cat $W/work3/test-result 2>/dev/null)
[ "$R3" = EMMC_STUCK_NOT_READY ] && ok "no-enumerate -> EMMC_STUCK_NOT_READY" || no "stuck path gave: $R3"
! grep -qE 'wipefs|zero-write|blkdiscard' $W/log3/destructive-actions.txt 2>/dev/null && ok "no destructive op without a block device" || no "destructive op ran with no device!"

echo; echo "SIM SUMMARY: pass=$pass fail=$fail"; exit $fail
