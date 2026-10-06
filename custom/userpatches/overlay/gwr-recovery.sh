#!/bin/bash
# Great Wall Recovery - Stage 2 (Linux). DC-A568B V01 / RK3568. eMMC host = fe310000.mmc
# Bounded, logged, never loops forever. Every destructive path is preceded by gwr_guard().
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin
EMMC_HOST="fe310000.mmc"
SD_HOSTS_RE="fe2b0000\.mmc|fe2c0000\.mmc"
MIN_B=$((20*1024**3)); MAX_B=$((40*1024**3))
LOGLBL="RECOVERYLOG"; MNT=/mnt/gwr-log
WORK=/run/gwr; mkdir -p "$WORK" "$MNT"
T0=$(date +%s)

ts() { date '+%F %T'; }

# --- mount result partition (FAT32, Windows readable) -------------------------
LOGDEV=""
mount_log() {
  local d=""
  for _ in $(seq 1 30); do
    d=$(blkid -L "$LOGLBL" 2>/dev/null) && [ -n "$d" ] && break
    sleep 1
  done
  if [ -z "$d" ]; then MNT=$WORK/log; mkdir -p "$MNT"; return 1; fi
  LOGDEV=$d
  mountpoint -q "$MNT" || mount -t vfat -o rw,flush "$d" "$MNT"
}
mount_log
mkdir -p "$MNT/STATE"
DA="$MNT/destructive-actions.txt"; HW="$MNT/hardware-identification.txt"
say() { echo "[$(ts)] $*" | tee -a "$MNT/recovery-run.log" >&2; }
dlog() { echo "[$(ts)] $*" >> "$DA"; say "DESTRUCTIVE-LOG: $*"; }

# --- terminal-state marker: never repeat erase on a recovered eMMC ------------
if [ -f "$MNT/STATE/terminal.done" ] && grep -qE '^RESULT=EMMC_RECOVERED' "$MNT/STATE/terminal.done"; then
  say "terminal recovered state already recorded; no further action"
  sync; sleep 30; systemctl poweroff; exit 0
fi

: > "$DA"; : > "$HW"
{
  cat /etc/gwr-build-info 2>/dev/null || echo "build info missing"
  echo "boot-time-kernel: $(uname -a)"
} > "$MNT/build-info.txt"

ROOTSRC=$(findmnt -no SOURCE / 2>/dev/null)
ROOTDISK="/dev/$(lsblk -no PKNAME "$ROOTSRC" 2>/dev/null | head -1)"
LOGDISK=""; [ -n "$LOGDEV" ] && LOGDISK="/dev/$(lsblk -no PKNAME "$LOGDEV" 2>/dev/null | head -1)"

# --- diagnostics --------------------------------------------------------------
dyndbg() {
  mount -t debugfs none /sys/kernel/debug 2>/dev/null
  local c=/sys/kernel/debug/dynamic_debug/control
  if [ -w $c ]; then
    echo 'file drivers/mmc/core/* +pflmt' > $c
    echo 'file drivers/mmc/host/sdhci* +pflmt' > $c
    echo 'file drivers/mmc/host/dw_mmc* +pflmt' > $c
  fi
}
collect() {
  {
    echo "=== uname"; uname -a
    echo "=== cmdline"; cat /proc/cmdline
    echo "=== lsblk"; lsblk -b -o NAME,SIZE,TYPE,RM,MOUNTPOINT,LABEL,PKNAME
    echo "=== blkid"; blkid
    echo "=== mmc sysfs"
    for h in /sys/class/mmc_host/*; do echo "$h -> $(readlink -f "$h")"; done
    for b in /sys/block/mmcblk*; do [ -e "$b" ] && echo "$b -> $(readlink -f "$b/device") type=$(cat "$b/device/type" 2>/dev/null)"; done
    echo "=== bound driver"; readlink -f /sys/bus/platform/devices/$EMMC_HOST/driver
    echo "=== DT $EMMC_HOST"
    local dt; dt=$(readlink -f /sys/bus/platform/devices/$EMMC_HOST/of_node 2>/dev/null)
    if [ -d "$dt" ]; then
      for p in "$dt"/*; do
        [ -f "$p" ] && { printf '%s: ' "$(basename "$p")"; tr '\0' ' ' < "$p" | strings | head -c 300; echo; }
      done
    fi
    echo "=== pinctrl"; grep -i -B1 -A6 "$EMMC_HOST" /sys/kernel/debug/pinctrl/pinctrl-handles 2>/dev/null
    echo "=== debugfs mmc"
    for f in /sys/kernel/debug/mmc*/*; do [ -f "$f" ] && { echo "--- $f"; head -c 4000 "$f" 2>/dev/null; }; done
    echo "=== regulators"; cat /sys/kernel/debug/regulator/regulator_summary 2>/dev/null
    echo "=== u-boot stage1 result"; tr ' ' '\n' < /proc/cmdline | grep gwr_uboot_mmc
  } > "$HW" 2>&1
  dmesg > "$MNT/full-dmesg.txt" 2>&1
  dmesg | grep -iE 'mmc|sdhci|dwcmshc|fe310000|emmc' > "$MNT/mmc-trace.txt" 2>&1
}
# eMMC node = block device whose parent host is fe310000.mmc (no capacity/ordering logic)
find_emmc() {
  local b n
  for b in /sys/block/mmcblk[0-9]*; do
    n=$(basename "$b"); [[ $n =~ ^mmcblk[0-9]+$ ]] || continue
    if readlink -f "$b/device" | grep -q "/$EMMC_HOST/"; then echo "/dev/$n"; return 0; fi
  done
  return 1
}
# bounded unbind/bind of the controller = full host re-init including power cycle
reprobe() {
  local drv; drv=$(readlink -f /sys/bus/platform/devices/$EMMC_HOST/driver 2>/dev/null)
  if [ -z "$drv" ] || [ ! -d "$drv" ]; then
    say "no driver bound to $EMMC_HOST, requesting probe"
    echo "$EMMC_HOST" > /sys/bus/platform/drivers_probe 2>/dev/null
    return
  fi
  echo "$EMMC_HOST" > "$drv/unbind" 2>>"$WORK/err"; sleep 3
  echo "$EMMC_HOST" > "$drv/bind" 2>>"$WORK/err"
}
wait_emmc() { local i; for i in $(seq 1 "$1"); do find_emmc && return 0; sleep 1; done; return 1; }

# --- safety guard -------------------------------------------------------------
# returns 0 only if EVERY check passes. Identification is by sysfs host path, never by order.
gwr_guard() {
  local dev=$1 n real size fail=0 cnt=0 b
  n=$(basename "$dev")
  [[ $n =~ ^mmcblk[0-9]+$ ]] || { dlog "GUARD FAIL: bad node $dev"; dlog TARGET_IDENTIFICATION_FAILED; return 1; }
  real=$(readlink -f "/sys/block/$n/device")
  size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
  dlog "GUARD target=$dev sysdev=$real size=$size rootsrc=$ROOTSRC rootdisk=$ROOTDISK logdisk=$LOGDISK"
  # 1. not the root-backing disk (nor the result partition's disk)
  if [ "$dev" = "$ROOTDISK" ] || [ "$dev" = "$LOGDISK" ] || [[ "$ROOTSRC" == "$dev"* ]]; then dlog "GUARD FAIL(1) root/log disk"; fail=1; fi
  # 2. non-removable, MMC type (eMMC, not SD)
  if [ "$(cat "/sys/block/$n/removable" 2>/dev/null)" != "0" ] || [ "$(cat "/sys/block/$n/device/type" 2>/dev/null)" != "MMC" ]; then dlog "GUARD FAIL(2) not non-removable MMC type"; fail=1; fi
  # 3. host maps to internal controller
  [[ $real == */$EMMC_HOST/* ]] || { dlog "GUARD FAIL(3) host is not $EMMC_HOST"; fail=1; }
  # 4. not the SD controller
  if [[ $real =~ $SD_HOSTS_RE ]]; then dlog "GUARD FAIL(4) SD controller"; fail=1; fi
  # 5/6. capacity window (also excludes the ~461GiB recovery SD)
  if ! { [ "$size" -ge $MIN_B ] && [ "$size" -le $MAX_B ]; }; then dlog "GUARD FAIL(5/6) capacity $size outside 20-40GiB"; fail=1; fi
  # exactly one block device on the eMMC host
  for b in /sys/block/mmcblk[0-9]*; do
    [[ $(basename "$b") =~ ^mmcblk[0-9]+$ ]] && readlink -f "$b/device" | grep -q "/$EMMC_HOST/" && cnt=$((cnt+1))
  done
  [ "$cnt" = 1 ] || { dlog "GUARD FAIL: $cnt devices on $EMMC_HOST (ambiguous)"; fail=1; }
  if [ $fail -ne 0 ]; then dlog "TARGET_IDENTIFICATION_FAILED"; return 1; fi
  dlog "GUARD PASS for $dev"
  return 0
}

result() { # $1 STATE ; $2 text   (terminal: never returns)
  {
    echo "RESULT=$1"; echo; echo "$2"; echo
    echo "finished: $(ts) (elapsed $(( $(date +%s)-T0 ))s)"
    echo "files: full-dmesg.txt mmc-trace.txt hardware-identification.txt destructive-actions.txt build-info.txt"
  } > "$MNT/RECOVERY-RESULT.txt"
  echo "$1 $(ts)" > "$MNT/STATE/last-result.txt"
  case $1 in EMMC_RECOVERED*) { echo "RESULT=$1"; echo "DONE $(ts)"; } > "$MNT/STATE/terminal.done";; esac
  echo "DONE $(ts)" > "$MNT/DONE.txt"
  collect; sync; say "FINAL RESULT=$1"
  sleep 45; sync; systemctl poweroff; exit 0
}

# --- Stage 2 main -------------------------------------------------------------
dyndbg
say "start; root=$ROOTSRC rootdisk=$ROOTDISK logdev=${LOGDEV:-none}"
[ -e /sys/bus/platform/devices/$EMMC_HOST ] || say "$EMMC_HOST platform device absent"
collect

DEV=$(find_emmc)
for att in 1 2 3 4; do
  [ -n "$DEV" ] && break
  say "eMMC reprobe attempt $att/4"
  reprobe
  DEV=$(wait_emmc 45 | head -1)
  dmesg | tail -n 40 >> "$MNT/recovery-run.log"
  if [ -z "$DEV" ] && [ $(( $(date +%s)-T0 )) -gt 900 ]; then break; fi
done
collect
if [ -z "$DEV" ]; then
  if [ -e /sys/class/mmc_host/mmc1 ] && { dmesg | grep -qE 'mmc1: .*(error -110|[Tt]imeout|timed out)' || tr ' ' '\n' < /proc/cmdline | grep -q 'gwr_uboot_mmc=.*:fail'; }; then
    result EMMC_STUCK_NOT_READY "Controller $EMMC_HOST (mmc1) exists but the card never completes init (timeouts in mmc-trace.txt). Linux retries: 4x unbind/bind. U-Boot stage1: $(tr ' ' '\n' < /proc/cmdline | grep gwr_uboot_mmc). The cause (hardware, rail, reset line, device) is NOT determined by this tool."
  fi
  result EMMC_NOT_DETECTED "No block device appeared on $EMMC_HOST after reprobing. No timeout pattern identified; see mmc-trace.txt."
fi

# eMMC enumerated as a block device ---------------------------------------------
gwr_guard "$DEV" || result ABORTED_TARGET_SAFETY_CHECK "TARGET_IDENTIFICATION_FAILED. Nothing was erased. See destructive-actions.txt."
M=$(basename "$DEV"); D=/sys/block/$M/device
{
  echo "=== eMMC identification"; echo "node: $DEV"; echo "bytes: $(blockdev --getsize64 "$DEV")"
  for f in cid csd name manfid oemid serial date fwrev hwrev preferred_erase_size erase_size rel_sectors; do echo "$f: $(cat "$D/$f" 2>/dev/null)"; done
  echo "discard_max_bytes: $(cat /sys/block/$M/queue/discard_max_bytes 2>/dev/null)"
  echo "=== EXT_CSD"
  if command -v mmc >/dev/null; then mmc extcsd read "$DEV" 2>&1 | head -80; else echo "mmc-utils absent"; fi
} | tee -a "$HW" >> "$DA"

dlog "BEGIN destructive recovery on $DEV"
sync
for p in $(lsblk -nro NAME "$DEV" | tail -n +2); do umount "/dev/$p" 2>>"$DA"; done
gwr_guard "$DEV" || result ABORTED_TARGET_SAFETY_CHECK "guard failed before wipefs"
dlog "wipefs -a $DEV"; timeout 120 wipefs -af "$DEV" >>"$DA" 2>&1; dlog "wipefs exit=$?"

DISC=$(cat /sys/block/$M/queue/discard_max_bytes 2>/dev/null || echo 0)
ERASED=0
if [ "${DISC:-0}" -gt 0 ]; then
  gwr_guard "$DEV" || result ABORTED_TARGET_SAFETY_CHECK "guard failed before discard"
  dlog "blkdiscard $DEV"; timeout 1800 blkdiscard "$DEV" >>"$DA" 2>&1; rc=$?; dlog "blkdiscard exit=$rc"
  [ $rc -eq 0 ] && ERASED=1
else
  dlog "discard not advertised"
fi
if [ $ERASED -eq 0 ]; then
  gwr_guard "$DEV" || result ABORTED_TARGET_SAFETY_CHECK "guard failed before zero-write"
  dlog "zero-write fallback $DEV (bounded 3600s)"
  timeout 3600 dd if=/dev/zero of="$DEV" bs=4M oflag=direct conv=fsync status=none 2>"$WORK/dd.err"; rc=$?
  cat "$WORK/dd.err" >> "$DA"; dlog "zero-write exit=$rc"
  # dd on a block device ends with 'No space left' once the whole device is written
  if [ $rc -eq 0 ] || { [ $rc -eq 1 ] && grep -q 'No space left' "$WORK/dd.err"; }; then ERASED=1; fi
fi
[ $ERASED -eq 1 ] || result EMMC_DETECTED_ERASE_FAILED "eMMC enumerated as $DEV but neither discard nor full zero-write completed. See destructive-actions.txt."

blockdev --rereadpt "$DEV" >>"$DA" 2>&1; dlog "rereadpt exit=$?"
reprobe; DEV2=$(wait_emmc 60 | head -1); dlog "post-erase device=${DEV2:-none}"
[ -n "$DEV2" ] || result EMMC_ERASED_VERIFY_FAILED "eMMC disappeared after erase and controller reprobe."
gwr_guard "$DEV2" || result ABORTED_TARGET_SAFETY_CHECK "guard failed after reprobe"
DEV=$DEV2

SZ=$(blockdev --getsize64 "$DEV"); MB=1048576; BAD=0
for pos in 0 $(( (SZ/2/MB)*MB )) $(( SZ-MB )); do
  gwr_guard "$DEV" || result ABORTED_TARGET_SAFETY_CHECK "guard failed in verify"
  head -c $MB /dev/urandom > "$WORK/pat.bin"
  timeout 120 dd if="$WORK/pat.bin" of="$DEV" bs=$MB seek=$((pos/MB)) oflag=direct conv=fsync status=none 2>>"$DA"; w=$?
  sync; echo 3 > /proc/sys/vm/drop_caches
  timeout 120 dd if="$DEV" of="$WORK/rb.bin" bs=$MB skip=$((pos/MB)) count=1 iflag=direct status=none 2>>"$DA"; r=$?
  if cmp -s "$WORK/pat.bin" "$WORK/rb.bin"; then dlog "verify@$pos OK (w=$w r=$r)"; else dlog "verify@$pos MISMATCH (w=$w r=$r)"; BAD=1; fi
  head -c $MB /dev/zero | timeout 120 dd of="$DEV" bs=$MB seek=$((pos/MB)) oflag=direct conv=fsync status=none 2>>"$DA"
done
[ $BAD -eq 0 ] || result EMMC_ERASED_VERIFY_FAILED "Erase completed but write/read-back verification FAILED (see destructive-actions.txt)."

# --- optional install of verified ZTL-A568 Armbian image ----------------------
PAY="$MNT/payload"
if [ -f "$PAY/target.img.zst" ] && [ -f "$PAY/target.img.size" ] && [ -f "$PAY/target.img.sha256" ]; then
  gwr_guard "$DEV" || result ABORTED_TARGET_SAFETY_CHECK "guard failed before install"
  IMGB=$(cat "$PAY/target.img.size"); H2=$(awk '{print $1}' "$PAY/target.img.sha256")
  dlog "verify payload integrity"
  HP=$(zstdcat "$PAY/target.img.zst" | sha256sum | awk '{print $1}')
  if [ "$HP" = "$H2" ]; then
    dlog "payload sha256 OK; writing to $DEV"
    zstdcat "$PAY/target.img.zst" | timeout 3000 dd of="$DEV" bs=4M oflag=direct conv=fsync status=none 2>>"$DA"; rc=${PIPESTATUS[1]}; dlog "install dd exit=$rc"
    sync; sgdisk -e "$DEV" >>"$DA" 2>&1; blockdev --rereadpt "$DEV" >>"$DA" 2>&1; sleep 3
    echo 3 > /proc/sys/vm/drop_caches
    H1=$(head -c "$IMGB" "$DEV" | sha256sum | awk '{print $1}')
    dlog "readback sha256=$H1 expected=$H2"
    sgdisk -v "$DEV" >>"$DA" 2>&1; dlog "sgdisk -v exit=$?"
    RP=$(blkid -L armbi_root 2>/dev/null)
    if [ -n "$RP" ] && [[ "$RP" == "$DEV"* ]]; then e2fsck -fn "$RP" >>"$DA" 2>&1; dlog "e2fsck -n exit=$? on $RP"; else dlog "root partition armbi_root not found on target"; fi
    if [ "$H1" = "$H2" ] && [ "$rc" = 0 ]; then
      result EMMC_RECOVERED_AND_LINUX_INSTALLED "eMMC erased, write/read verified at start/middle/end, then the Armbian ZTL-A568 image was written and read-back SHA256 matched ($H1). Remove the SD and power-cycle to boot from eMMC."
    fi
    result EMMC_RECOVERED_READWRITE_OK "eMMC read/write verified, but the Linux install failed or its hash mismatched (see destructive-actions.txt)."
  fi
  dlog "payload sha256 MISMATCH - install skipped"
fi
result EMMC_RECOVERED_READWRITE_OK "eMMC erase and write/read verification succeeded at start/middle/end. No install payload was written."
