#!/bin/bash
# Great Wall V2 - DC-A568B V01 / RK3568 internal eMMC recovery (Linux userspace only).
#
# Runs from the UNMODIFIED golden Armbian boot chain (golden U-Boot, kernel 6.18.53-ophub, DTB, boot.scr).
# There is NO U-Boot stage-1 in V2 (V1 hung in U-Boot: its stage-1 used 'setexpr', which the golden/V1
# U-Boot 2017.09 binary does not contain -> infinite 'while' loop; see docs/V1-FAILURE-ANALYSIS.md).
#
# Order: diagnostics -> bounded pre-enumeration recovery (host reprobe / EMMC_RSTn pulse / power-on soak)
#        -> if a block device appears on fe310000.mmc: guard -> identify -> wipefs -> discard|zero-write
#        -> reprobe -> guard -> random write / reinit / read-back verify -> install ORIGINAL golden image
#        -> read-back SHA256 -> GPT backup relocation -> partition + fs verification -> result -> poweroff.
# Every destructive command is immediately preceded by gwr_guard (static check: v2/tests/check-destructive.sh).
# Nothing loops forever; every wait and retry is bounded.
export LC_ALL=C PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022

EMMC_HOST="fe310000.mmc"                      # RK3568 SDHCI (dwcmshc) eMMC controller
SD_HOSTS_RE="fe2b0000\.mmc|fe2c0000\.mmc"     # RK3568 SDMMC0 / SDMMC1 (dw_mmc)
MIN_B=$((20*1024**3)); MAX_B=$((40*1024**3))   # guard window for the ~32 GB eMMC
LOGLBL="RECOVERYLOG"
# Golden payload identity (physically proven image). The .gz hash is the file the operator supplied;
# the raw hash was recomputed during the V2 build with two independent decompressors + gzip CRC32.
GOLDEN_GZ_SHA="016a11416caea7729f35006b83a8e2a003ba77defd4e3f1b6522fca9e69074aa"
GOLDEN_IMG_SHA="c99b13ea629860a321ff489e4bcc53e651cc5a49b31e340733b8f999b5d6f0c6"
GOLDEN_IMG_BYTES=3699376128
GOLDEN_P1_START=32768;   GOLDEN_P1_SECTORS=1046528   # BOOT   ext4
GOLDEN_P2_START=1081344; GOLDEN_P2_SECTORS=6141952   # ROOTFS ext4
GOLDEN_P1_UUID="4fa931ad-b822-4a0f-9498-7a6d4dbffcc5"
GOLDEN_P2_UUID="5295c367-5e7a-48c3-8f7c-8bd9249ab874"
# EMMC_RSTn: RK3568 datasheet V2.3, ball F20 = EMMC_RSTn/FSPI_D2/FLASH_WPn/GPIO1_C7_d -> gpio1 line 23.
RSTN_GPIO_CTRL="fe740000.gpio"; RSTN_LINE=23

# ---- defaults (may be lowered/raised within hard limits by RECOVERYLOG/gwr-config.txt) ----------------
REBIND_ATTEMPTS=3        # plain host reprobes before anything else
RSTN_PULSE=1             # 1 = try EMMC_RSTn pulse if (and only if) the GPIO line is unclaimed
SOAK_MINUTES=60          # power-on soak: card stays powered, host reprobed every SOAK_INTERVAL_S
SOAK_INTERVAL_S=300
INSTALL=1                # 1 = install golden payload after successful erase + R/W verify
ZERO_WRITE_TIMEOUT_S=10800

# ---- test mode (fake sysfs + loop devices, used ONLY by v2/tests) -----------------------------------
# A systemd service always has INVOCATION_ID set -> test mode is impossible when started by the unit.
TEST=0
if [ "${GWR_TEST_MODE:-0}" = 1 ] && [ -z "${INVOCATION_ID:-}" ]; then TEST=1; fi
SYS=""; DEVDIR=/dev
if [ $TEST = 1 ]; then SYS=${GWR_TEST_SYSROOT:?}; DEVDIR=${GWR_TEST_DEVDIR:?}; fi

WORK=/run/gwr; [ $TEST = 1 ] && WORK=${GWR_TEST_WORK:?}
mkdir -p "$WORK"
T0=$(date +%s); RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
ts() { date '+%F %T'; }
el() { echo $(( $(date +%s)-T0 )); }

exec 9>"$WORK/lock"
flock -n 9 || { echo "gwr: another instance is running"; exit 0; }

# ---- locate RECOVERYLOG on the ROOT disk (never a global label lookup: eMMC may carry golden labels) ----
ROOTSRC=$(findmnt -no SOURCE / 2>/dev/null)
ROOTDISK="/dev/$(lsblk -no PKNAME "$ROOTSRC" 2>/dev/null | head -1)"
[ $TEST = 1 ] && ROOTDISK=${GWR_TEST_ROOTDISK:?}
MNT=/mnt/gwr-log; LOGDEV=""; LOGDISK=""
mount_log() {
  local i name lbl
  [ $TEST = 1 ] && { MNT=${GWR_TEST_LOGDIR:?}; LOGDEV=${GWR_TEST_LOGDEV:-}; LOGDISK=${GWR_TEST_LOGDISK:-}; return 0; }
  mkdir -p "$MNT"
  for i in $(seq 1 30); do
    while read -r name lbl; do
      [ "$lbl" = "$LOGLBL" ] && LOGDEV=$name
    done < <(lsblk -nrpo NAME,LABEL "$ROOTDISK" 2>/dev/null)
    [ -n "$LOGDEV" ] && break
    sleep 1
  done
  if [ -z "$LOGDEV" ]; then MNT=$WORK/log-fallback; mkdir -p "$MNT"; return 1; fi
  LOGDISK="/dev/$(lsblk -no PKNAME "$LOGDEV" 2>/dev/null | head -1)"
  mountpoint -q "$MNT" || mount -t vfat -o rw,flush,noatime "$LOGDEV" "$MNT"
}
mount_log; LOGMOUNT_RC=$?
mkdir -p "$MNT/STATE" "$MNT/attempts"
RUNLOG="$MNT/recovery-run.log"; DA="$MNT/destructive-actions.txt"; HW="$MNT/hardware-identification.txt"
ATT="$MNT/emmc-init-attempts.txt"

# ---- logging: RECOVERYLOG file + stdout (journal+console via unit) + kmsg + serial console --------------
say() {
  local m="[$(ts)] $*"
  echo "$m" >> "$RUNLOG" 2>/dev/null
  echo "$m"
  [ $TEST = 1 ] && return 0
  { echo "<5>gwr: $*" > /dev/kmsg; } 2>/dev/null
  # golden boots with console=ttyS2,1500000 console=tty1 loglevel=1 -> kmsg alone would not reach the UART
  [ -c /dev/ttyS2 ] && timeout 1 sh -c 'printf "%s\r\n" "$1" > /dev/ttyS2' _ "gwr: $*" 2>/dev/null
  return 0
}
dlog() { echo "[$(ts)] $*" >> "$DA"; say "DESTRUCTIVE-LOG: $*"; }
fsync_log() { sync; return 0; }

# ---- optional config (strict whitelist, numeric only, clamped) ----------------------------------------
cfg_load() {
  local f="$MNT/gwr-config.txt" k v
  [ -f "$f" ] || return 0
  while IFS='=' read -r k v; do
    k=$(echo "$k" | tr -d ' \r'); v=$(echo "$v" | tr -d ' \r')
    [[ $v =~ ^[0-9]+$ ]] || continue
    case $k in
      REBIND_ATTEMPTS) [ "$v" -le 10 ] && REBIND_ATTEMPTS=$v;;
      RSTN_PULSE) [ "$v" -le 1 ] && RSTN_PULSE=$v;;
      SOAK_MINUTES) [ "$v" -le 240 ] && SOAK_MINUTES=$v;;
      SOAK_INTERVAL_S) [ "$v" -ge 60 ] && [ "$v" -le 1800 ] && SOAK_INTERVAL_S=$v;;
      INSTALL) [ "$v" -le 1 ] && INSTALL=$v;;
      ZERO_WRITE_TIMEOUT_S) [ "$v" -ge 600 ] && [ "$v" -le 21600 ] && ZERO_WRITE_TIMEOUT_S=$v;;
    esac
  done < "$f"
}

# ---- LED (optional, fail-safe, only through a runtime-verified DT gpio-leds node) ----------------------
# Golden DT: /leds/led-0, gpio-leds, gpios = <&gpio0 RK_PC0 GPIO_ACTIVE_HIGH>, trigger heartbeat.
# Used ONLY if the running DT matches exactly AND the gpio phandle resolves to gpio@fdd60000 (GPIO0).
# NOTE: the vendor Android DTB (GB-RK3568-11) instead has a "work" LED on GPIO4_C4. Physical V01 LED
# wiring is unverified, so no LED is ever assumed and no raw GPIO is ever driven for signalling.
LEDDIR=""; LEDPID=""; LEDCUR=""
led_find() {
  local l n ph gp
  [ $TEST = 1 ] && return 1
  [ "$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)" = "ZTL A568" ] || return 1
  for l in /sys/class/leds/*; do
    [ -e "$l/of_node" ] || continue
    n=$(readlink -f "$l/of_node")
    [[ $n == */leds/led-0 ]] || continue
    grep -aq gpio-leds "$n/../compatible" 2>/dev/null || continue
    gp=$(od -An -tx1 -v "$n/gpios" 2>/dev/null | tr -d ' \n')
    [ "${gp:8}" = "0000001000000000" ] || continue
    ph=${gp:0:8}
    # the referenced controller must be GPIO0 (fdd60000)
    [ "$(od -An -tx1 -v /proc/device-tree/*/gpio@fdd60000/phandle /proc/device-tree/gpio@fdd60000/phandle 2>/dev/null | tr -d ' \n' | head -c 8)" = "$ph" ] || continue
    if [ -w "$l/brightness" ] && [ -w "$l/trigger" ]; then LEDDIR=$l; return 0; fi
  done
  return 1
}
led_stop() { if [ -n "$LEDPID" ]; then kill "$LEDPID" 2>/dev/null; wait "$LEDPID" 2>/dev/null; LEDPID=""; fi; return 0; }
led_state() { # LINUX_BOOTED RECOVERY_RUNNING EMMC_DETECTED DESTRUCTIVE_RECOVERY SUCCESS FAILURE
  [ -n "$LEDDIR" ] || return 0
  [ "$1" = "$LEDCUR" ] && return 0
  LEDCUR=$1; led_stop
  echo none > "$LEDDIR/trigger" 2>/dev/null
  local seq
  case $1 in
    LINUX_BOOTED)         seq="1 0.25 0 0.25 1 0.25 0 0.25 1 0.25 0 1.5";;
    RECOVERY_RUNNING)     echo heartbeat > "$LEDDIR/trigger" 2>/dev/null; return 0;;
    EMMC_DETECTED)        seq="1 0.15 0 0.15 1 0.15 0 0.9";;
    DESTRUCTIVE_RECOVERY) seq="1 0.1 0 0.1";;
    SUCCESS)              echo 1 > "$LEDDIR/brightness" 2>/dev/null; return 0;;
    FAILURE)              seq="1 0.15 0 0.15 1 0.15 0 0.15 1 0.15 0 1.2";;
    *) return 0;;
  esac
  ( end=$((SECONDS+21600)); while [ $SECONDS -lt $end ]; do set -- $seq; while [ $# -ge 2 ]; do echo "$1" > "$LEDDIR/brightness"; sleep "$2"; shift 2; done; done ) >/dev/null 2>&1 &
  LEDPID=$!
}

# ---- LIVE-STATUS.txt (atomic tmp+rename; quick-look only, logs are authoritative) ---------------------
CUR_STATE=""; CUR_STAGE=""; CUR_ATTEMPT=""; CUR_METHOD=""; LAST_OCR=""; LAST_READY=""
live() { # $1 STATE $2 STAGE [$3 ATTEMPT] [$4 METHOD] [$5 RESULT]
  CUR_STATE=$1; CUR_STAGE=$2; CUR_ATTEMPT=${3:-}; CUR_METHOD=${4:-}
  {
    printf 'STATE=%s\nSTAGE=%s\n' "$1" "$2"
    [ -n "${3:-}" ] && printf 'ATTEMPT=%s\n' "$3"
    [ -n "${4:-}" ] && printf 'METHOD=%s\n' "$4"
    [ -n "$LAST_OCR" ] && printf 'LAST_OCR=%s\nREADY=%s\n' "$LAST_OCR" "$LAST_READY"
    [ -n "${5:-}" ] && printf 'RESULT=%s\n' "$5"
    printf 'RUN_ID=%s\nUPDATED=%s\nELAPSED_S=%s\n' "$RUN_ID" "$(ts)" "$(el)"
  } > "$MNT/.LIVE-STATUS.tmp" 2>/dev/null && mv -f "$MNT/.LIVE-STATUS.tmp" "$MNT/LIVE-STATUS.txt" 2>/dev/null
  echo "RUN_ID=$RUN_ID STAGE=$2" > "$MNT/STATE/in-progress" 2>/dev/null
  led_state "$1"
  say "STATE=$1 STAGE=$2${3:+ ATTEMPT=$3}${4:+ METHOD=$4}${LAST_OCR:+ LAST_OCR=$LAST_OCR READY=$LAST_READY}${5:+ RESULT=$5}"
  fsync_log
  return 0
}
on_term() { say "SIGTERM received at stage ${CUR_STAGE:-?} (shutdown or service stop)"; led_stop; fsync_log; exit 143; }
trap on_term TERM
trap led_stop EXIT

# ---- sysfs helpers -----------------------------------------------------------------------------------
host_dev() { echo "$SYS/sys/bus/platform/devices/$EMMC_HOST"; }
host_name() { # mmcN of the eMMC controller (derived, never assumed to be mmc1)
  local h; for h in "$(host_dev)"/mmc_host/mmc*; do [ -e "$h" ] && { basename "$h"; return 0; }; done; return 1
}
find_emmc() { # block device whose sysfs device path runs through fe310000.mmc
  local b n
  for b in "$SYS"/sys/block/mmcblk*; do
    [ -e "$b" ] || continue
    n=$(basename "$b"); [[ $n =~ ^mmcblk[0-9]+$ ]] || continue
    if [[ $(readlink -f "$b/device") == */$EMMC_HOST/* ]]; then echo "$DEVDIR/$n"; return 0; fi
  done
  return 1
}
wait_emmc() { local i; for i in $(seq 1 "$1"); do find_emmc && return 0; [ $TEST = 1 ] || sleep 1; done; return 1; }

# ---- instrumentation: tracepoints filtered to the eMMC host, narrow dynamic debug ----------------------
TR=""
instr_on() {
  [ $TEST = 1 ] && return 0
  local h; h=$(host_name) || h=""
  mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
  if [ -d /sys/kernel/tracing/events ]; then TR=/sys/kernel/tracing
  else mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null && TR=/sys/kernel/tracing
       [ -d $TR/events ] || TR=/sys/kernel/debug/tracing; fi
  if [ -d "$TR/events/mmc" ] && [ -n "$h" ]; then
    echo 8192 > $TR/buffer_size_kb 2>/dev/null
    echo "name == \"$h\"" > $TR/events/mmc/filter 2>/dev/null
    echo 1 > $TR/events/mmc/enable 2>/dev/null
    echo 1 > $TR/tracing_on 2>/dev/null
    say "tracepoints: $TR/events/mmc enabled, filter name==$h (eMMC host only)"
  else
    TR=""; say "tracepoints: mmc trace events unavailable - OCR can only come from kernel messages"
  fi
  local c=/sys/kernel/debug/dynamic_debug/control
  if [ -w $c ]; then
    # only eMMC-specific code: sdhci + dwcmshc drivers are used solely by fe310000 on this board
    # (SD/SDIO use dw_mmc), plus the core's per-frequency init message.
    echo 'file drivers/mmc/host/sdhci-of-dwcmshc.c +pflmt' > $c 2>/dev/null
    echo 'file drivers/mmc/host/sdhci.c +pflmt' > $c 2>/dev/null
    echo 'func mmc_rescan_try_freq +pflmt' > $c 2>/dev/null
    say "dynamic debug: sdhci-of-dwcmshc.c, sdhci.c, mmc_rescan_try_freq enabled"
  else
    say "dynamic debug control not writable"
  fi
}
trace_clear() { [ -n "$TR" ] && echo > $TR/trace 2>/dev/null; return 0; }
# parse the last CMD1 (SEND_OP_COND) response actually observed in this attempt
ocr_observe() { # $1 = trace snapshot file
  local o=""
  [ -s "$1" ] && o=$(grep -E 'mmc_request_done:.*cmd_opcode=1 ' "$1" | grep -oE 'cmd_resp=0x[0-9a-f]+' | tail -1 | cut -d= -f2)
  if [ -n "$o" ]; then
    LAST_OCR=$(printf '0x%08x' "$o")
    if (( (o >> 31) & 1 )); then LAST_READY=1; else LAST_READY=0; fi
    return 0
  fi
  return 1
}

# ---- recovery methods (each one is CLASSIFIED honestly in the attempt log) ----------------------------
# HOST_REPROBE : platform driver unbind+bind of fe310000.mmc. Re-runs host init (SDHCI software reset, the
#                rk35xx driver's controller reset, clock/PHY setup) and one full mmc core init sequence
#                (CMD0, CMD1 at 400/300/200/100 kHz). It does NOT remove card power: vmmc=vcc3v3_sys and
#                vqmmc=vcc_1v8 are always-on fixed/PMIC rails shared with the rest of the board.
# RSTN_PULSE   : SoC pin EMMC_RSTn (GPIO1_C7) driven low then high through the gpio character device while
#                the host is unbound. Board routing of that ball to the eMMC RST_n ball is NOT verified, and
#                a card honours RST_n only if EXT_CSD[162] RST_n_FUNCTION=1. Done only if the line is unused.
# POWER_REMOVAL: NOT AVAILABLE in software on this board (see above). Never claimed.
host_unbind() {
  local drv; drv=$(readlink -f "$(host_dev)/driver" 2>/dev/null)
  [ -n "$drv" ] && [ -d "$drv" ] || return 1
  echo "$EMMC_HOST" > "$drv/unbind" 2>>"$WORK/err"
}
host_bind() {
  local d
  for d in "$SYS"/sys/bus/platform/drivers/*; do
    [ -e "$d/bind" ] || continue
    case $(basename "$d") in *dwcmshc*|sdhci*) echo "$EMMC_HOST" > "$d/bind" 2>>"$WORK/err" && return 0;; esac
  done
  echo "$EMMC_HOST" > "$SYS/sys/bus/platform/drivers_probe" 2>>"$WORK/err"
}
reprobe() { # HOST_REPROBE
  if [ $TEST = 1 ]; then say "TEST: host reprobe simulated"; [ -n "${GWR_TEST_REPROBE_HOOK:-}" ] && "$GWR_TEST_REPROBE_HOOK"; return 0; fi
  if [ -L "$(host_dev)/driver" ]; then host_unbind; sleep 3; host_bind
  else say "no driver bound to $EMMC_HOST; requesting probe"; host_bind; fi
}
rstn_chip() { # gpiochipN whose sysfs device is fe740000.gpio (GPIO1)
  local c; for c in /sys/bus/gpio/devices/gpiochip*; do
    [[ $(readlink -f "$c") == */$RSTN_GPIO_CTRL/* ]] && { basename "$c"; return 0; }; done; return 1
}
rstn_pulse() { # returns 0 if a pulse was actually driven
  local chip info
  [ $TEST = 1 ] && return 1
  command -v gpioset >/dev/null || { say "RSTN: gpioset absent"; return 1; }
  chip=$(rstn_chip) || { say "RSTN: $RSTN_GPIO_CTRL gpiochip not found"; return 1; }
  info=$(gpioinfo "$chip" 2>/dev/null | grep -E "^\s*line\s+$RSTN_LINE:")
  say "RSTN: $chip line $RSTN_LINE before: $info"
  if ! echo "$info" | grep -q 'unused'; then say "RSTN: line in use by a driver - not touched"; return 1; fi
  grep -E "pin 55 " /sys/kernel/debug/pinctrl/*/pinmux-pins 2>/dev/null | head -2 | while read -r l; do say "RSTN: pinmux $l"; done
  host_unbind; sleep 1
  gpioset -m time -u 100000 "$chip" "$RSTN_LINE=0"; local r1=$?   # RST_n low 100 ms (JEDEC tRSTW >= 1 us)
  gpioset -m time -u 1000 "$chip" "$RSTN_LINE=1"; local r2=$?     # release high
  say "RSTN: pulse low(100ms)->high rc=$r1/$r2; after: $(gpioinfo "$chip" 2>/dev/null | grep -E "^\s*line\s+$RSTN_LINE:")"
  sleep 1                                                            # >> tRSCA 200 us before CMD1
  host_bind
  [ $r1 = 0 ] && [ $r2 = 0 ]
}

ATTN=0
attempt() { # $1 METHOD  $2 CLASS  $3 label  -> sets DEV if the card enumerates
  ATTN=$((ATTN+1)); local t1 t2 cnt_before cnt_after snap="$MNT/attempts/attempt-$(printf %02d $ATTN)-$1.txt" did=1
  live RECOVERY_RUNNING EMMC_REPROBE "$ATTN ($3)" "$1"
  cnt_before=$(dmesg 2>/dev/null | grep -c "$(host_name 2>/dev/null || echo mmc_x): Card stuck being busy")
  trace_clear; t1=$(date +%s)
  case $1 in
    controller_rebind|soak_rebind) reprobe;;
    rstn_pulse) rstn_pulse || { did=0; say "RSTN method not executed (preconditions); falling back to plain reprobe"; reprobe; };;
  esac
  DEV=$(wait_emmc 45 | head -1); t2=$(date +%s)
  cnt_after=$(dmesg 2>/dev/null | grep -c "$(host_name 2>/dev/null || echo mmc_x): Card stuck being busy")
  {
    echo "attempt=$ATTN method=$1 class=$2 executed=$did start=$t1 end=$t2 duration_s=$((t2-t1))"
    echo "host=$(host_name 2>/dev/null) driver=$(readlink -f "$(host_dev)/driver" 2>/dev/null)"
    echo "blockdev=${DEV:-none} new_card_stuck_busy_msgs=$((cnt_after-cnt_before))"
    echo "power_removed=NO (vmmc/vqmmc always-on rails)"
    echo "--- ios"; cat /sys/kernel/debug/"$(host_name 2>/dev/null)"/ios 2>/dev/null
    echo "--- tracepoints (eMMC host only)"; [ -n "$TR" ] && cat $TR/trace 2>/dev/null | tail -n 4000
  } > "$snap" 2>&1
  LAST_OCR=""; LAST_READY=""
  if ocr_observe "$snap"; then :; fi
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$ATTN" "$1" "$2" "$did" "$((t2-t1))" "${DEV:-none}" "${LAST_OCR:-not_observed}" "${LAST_READY:-n/a}" "$((cnt_after-cnt_before))" >> "$ATT"
  live RECOVERY_RUNNING EMMC_REPROBE "$ATTN ($3)" "$1"
  [ -n "$DEV" ]
}

# ---- diagnostics ---------------------------------------------------------------------------------------
collect() {
  [ $TEST = 1 ] && { echo "test mode" > "$HW.collect"; return 0; }
  local h dt p; h=$(host_name 2>/dev/null)
  {
    echo "=== run $RUN_ID  $(ts)"; echo "=== uname"; uname -a
    echo "=== model"; tr -d '\0' < /proc/device-tree/model; echo
    echo "=== cmdline"; cat /proc/cmdline
    echo "=== lsblk"; lsblk -b -o NAME,SIZE,TYPE,RM,MOUNTPOINT,LABEL,UUID,PKNAME
    echo "=== mmc hosts"; for p in /sys/class/mmc_host/*; do echo "$p -> $(readlink -f "$p")"; done
    for p in /sys/block/mmcblk*; do [ -e "$p" ] && echo "$p -> $(readlink -f "$p/device") type=$(cat "$p/device/type" 2>/dev/null)"; done
    echo "=== eMMC host $EMMC_HOST = ${h:-<no mmc_host>}  driver: $(readlink -f "$(host_dev)/driver" 2>/dev/null)"
    echo "=== DT properties of $EMMC_HOST"
    dt=$(readlink -f "$(host_dev)/of_node" 2>/dev/null)
    if [ -d "$dt" ]; then for p in "$dt"/*; do [ -f "$p" ] && printf '%-28s %s\n' "$(basename "$p")" "$(od -An -tx1 -v "$p" | tr -d '\n' | head -c 200)"; done; fi
    echo "=== debugfs $h"; for p in /sys/kernel/debug/"$h"/*; do [ -f "$p" ] && { echo "--- $p"; head -c 3000 "$p" 2>/dev/null; echo; }; done
    echo "=== pinmux pin 55 (GPIO1_C7 / EMMC_RSTn) and eMMC pins"; grep -hE 'pin (4[4-9]|5[0-5]) ' /sys/kernel/debug/pinctrl/*/pinmux-pins 2>/dev/null
    grep -hE 'pin 55 ' /sys/kernel/debug/pinctrl/*/pinconf-pins 2>/dev/null
    echo "=== gpioinfo GPIO1"; c=$(rstn_chip) && gpioinfo "$c" 2>/dev/null
    echo "=== regulators"; cat /sys/kernel/debug/regulator/regulator_summary 2>/dev/null
    echo "=== clocks (emmc)"; grep -iE 'emmc|sdhci' /sys/kernel/debug/clk/clk_summary 2>/dev/null
    echo "=== leds"; ls -l /sys/class/leds/ 2>/dev/null
  } > "$HW" 2>&1
  dmesg > "$MNT/full-dmesg.txt" 2>&1
  dmesg | grep -iE 'mmc|sdhci|dwcmshc|fe310000|emmc|gwr' > "$MNT/mmc-trace.txt" 2>&1
  [ -n "$TR" ] && cp $TR/trace "$MNT/mmc-tracepoints-last.txt" 2>/dev/null
  journalctl -b -u gwr-recovery.service --no-pager > "$MNT/journal-gwr-recovery.txt" 2>/dev/null
  journalctl -b -k --no-pager | grep -iE 'mmc|sdhci|dwcmshc|fe310000|gwr' > "$MNT/journal-kernel-mmc.txt" 2>/dev/null
  fsync_log
}

# ---- TARGET GUARD (non-negotiable; run before EVERY destructive command) --------------------------------
gwr_guard() {
  local dev=$1 n real size fail=0 cnt=0 b
  n=$(basename "$dev")
  [[ $n =~ ^mmcblk[0-9]+$ ]] || { dlog "GUARD FAIL(0) bad node name $dev"; dlog TARGET_IDENTIFICATION_FAILED; return 1; }
  [ "$dev" = "$DEVDIR/$n" ] || { dlog "GUARD FAIL(0) node outside $DEVDIR"; fail=1; }
  [ -b "$dev" ] || { dlog "GUARD FAIL(0) $dev is not a block device"; fail=1; }
  real=$(readlink -f "$SYS/sys/block/$n/device")
  size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
  dlog "GUARD target=$dev sysdev=$real size=$size rootsrc=$ROOTSRC rootdisk=$ROOTDISK logdisk=$LOGDISK"
  # 1. not the root-backing disk, not the RECOVERYLOG disk
  if [ "$dev" = "$ROOTDISK" ] || [ "$dev" = "$LOGDISK" ] || [[ "$ROOTSRC" == "$dev"* ]]; then dlog "GUARD FAIL(1) root/log disk"; fail=1; fi
  # 2. non-removable, MMC type (eMMC, not SD/SDIO), block major 179 (mmcblk)
  if [ "$(cat "$SYS/sys/block/$n/removable" 2>/dev/null)" != "0" ] || [ "$(cat "$SYS/sys/block/$n/device/type" 2>/dev/null)" != "MMC" ]; then dlog "GUARD FAIL(2) not non-removable MMC type"; fail=1; fi
  [[ $(cat "$SYS/sys/block/$n/dev" 2>/dev/null) == 179:* ]] || { dlog "GUARD FAIL(2b) not an mmcblk major"; fail=1; }
  # 3. host path runs through the internal controller
  [[ $real == */$EMMC_HOST/* ]] || { dlog "GUARD FAIL(3) host is not $EMMC_HOST"; fail=1; }
  # 4. not via an SD controller
  if [[ $real =~ $SD_HOSTS_RE ]]; then dlog "GUARD FAIL(4) SD controller"; fail=1; fi
  # 5/6. capacity window (also excludes the ~461 GiB recovery SD)
  if ! { [ "$size" -ge $MIN_B ] && [ "$size" -le $MAX_B ]; }; then dlog "GUARD FAIL(5/6) capacity $size outside 20-40GiB"; fail=1; fi
  # 7. exactly one block device on the eMMC host
  for b in "$SYS"/sys/block/mmcblk*; do
    [[ $(basename "$b") =~ ^mmcblk[0-9]+$ ]] && [[ $(readlink -f "$b/device") == */$EMMC_HOST/* ]] && cnt=$((cnt+1))
  done
  [ "$cnt" = 1 ] || { dlog "GUARD FAIL(7) $cnt devices on $EMMC_HOST (ambiguous)"; fail=1; }
  # 8. nothing on the target is mounted (checked by node name and by resolved path)
  local rp; rp=$(readlink -f "$dev")
  if grep -qE "^($dev|$rp)(p[0-9]+)? " /proc/mounts; then dlog "GUARD FAIL(8) target or a partition is mounted"; fail=1; fi
  if [ $fail -ne 0 ]; then dlog "TARGET_IDENTIFICATION_FAILED"; return 1; fi
  dlog "GUARD PASS for $dev"
  return 0
}

# ---- result (terminal: never returns) --------------------------------------------------------------------
result() { # $1 RESULT  $2 explanation
  case $1 in EMMC_RECOVERED*) live SUCCESS FINAL_RESULT "" "" "$1";; *) live FAILURE FINAL_RESULT "" "" "$1";; esac
  collect
  {
    echo "RESULT=$1"; echo
    echo "$2"; echo
    echo "run: $RUN_ID   finished: $(ts)   elapsed: $(el)s"
    echo "eMMC controller: $EMMC_HOST   mmc host: $(host_name 2>/dev/null || echo none)"
    echo "init attempts: $ATTN (see emmc-init-attempts.txt and attempts/)"
    echo "last observed CMD1 OCR: ${LAST_OCR_ANY:-not observed in this run}   READY(bit31): ${LAST_READY_ANY:-n/a}"
    echo "block device ever appeared: ${EVER_DEV:-no}"
    echo "reached stages: ${REACHED:-diagnostics}"
    echo "power removal of the eMMC: NOT POSSIBLE IN SOFTWARE (vmmc=vcc3v3_sys, vqmmc=vcc_1v8 are always-on)"
    case $1 in
      EMMC_RECOVERED_AND_LINUX_INSTALLED)
        echo; echo "NEXT: POWER OFF -> REMOVE THE RECOVERY SD -> POWER ON. The board should boot golden Armbian from eMMC."
        echo "      (eMMC and SD carry identical filesystem UUIDs until the SD is removed.)";;
    esac
    echo; echo "files: LIVE-STATUS.txt recovery-run.log emmc-init-attempts.txt attempts/ mmc-trace.txt mmc-tracepoints-last.txt"
    echo "       hardware-identification.txt destructive-actions.txt full-dmesg.txt journal-*.txt build-info.txt"
  } > "$MNT/RECOVERY-RESULT.txt"
  echo "$1 $(ts) $RUN_ID" >> "$MNT/STATE/run-history.txt"
  case $1 in EMMC_RECOVERED*) { echo "RESULT=$1"; echo "RUN_ID=$RUN_ID"; echo "DONE $(ts)"; } > "$MNT/STATE/terminal.done";; esac
  rm -f "$MNT/STATE/in-progress"; echo 0 > "$MNT/STATE/interrupted-count"
  echo "DONE $(ts) RESULT=$1 RUN_ID=$RUN_ID" > "$MNT/DONE.txt"
  fsync_log; say "FINAL RESULT=$1"
  if [ $TEST = 1 ]; then echo "$1" > "$WORK/test-result"; exit 0; fi
  led_state "${CUR_STATE}"; sleep 30; sync
  [ "$LOGMOUNT_RC" = 0 ] && umount "$MNT" 2>/dev/null
  sync; systemctl poweroff --no-block; exit 0
}

# ======================================== MAIN ===========================================================
# test-only: evaluate the guard alone against a fake target (unreachable under systemd, see TEST gate)
if [ $TEST = 1 ] && [ -n "${GWR_TEST_GUARD_ONLY:-}" ]; then gwr_guard "$GWR_TEST_GUARD_ONLY"; exit $?; fi
cfg_load
REACHED="LINUX_BOOTED"; EVER_DEV=""; LAST_OCR_ANY=""; LAST_READY_ANY=""
say "Great Wall V2 start run=$RUN_ID root=$ROOTSRC rootdisk=$ROOTDISK logdev=${LOGDEV:-NONE(rc=$LOGMOUNT_RC)}"
led_find && say "LED: using $LEDDIR (verified DT node leds/led-0 on GPIO0_C0)" || say "LED: no runtime-verified LED; signalling disabled"
live LINUX_BOOTED LINUX_BOOTED

# never repeat destructive work after a recorded success
if [ -f "$MNT/STATE/terminal.done" ] && grep -qE '^RESULT=EMMC_RECOVERED' "$MNT/STATE/terminal.done"; then
  say "terminal success already recorded ($(head -1 "$MNT/STATE/terminal.done")); NOTHING will be erased. Delete STATE/terminal.done to allow a new run."
  echo "[$(ts)] run $RUN_ID: terminal state present, no action" >> "$MNT/STATE/run-history.txt"
  rm -f "$MNT/STATE/in-progress"
  live SUCCESS FINAL_RESULT "" "" "ALREADY_COMPLETED"
  [ $TEST = 1 ] && { echo ALREADY_COMPLETED > "$WORK/test-result"; exit 0; }
  sync; sleep 30; systemctl poweroff --no-block; exit 0
fi
# interrupted-run accounting (watchdog reset, power loss): after 3 consecutive interruptions -> evidence only
IC=0
if [ -f "$MNT/STATE/in-progress" ]; then
  IC=$(( $(cat "$MNT/STATE/interrupted-count" 2>/dev/null || echo 0) + 1 )); echo $IC > "$MNT/STATE/interrupted-count"
  say "previous run was interrupted ($(cat "$MNT/STATE/in-progress")); consecutive interruptions=$IC"
  echo "[$(ts)] interrupted: $(cat "$MNT/STATE/in-progress")" >> "$MNT/STATE/run-history.txt"
fi

: > "$DA"; : > "$HW"
[ -f "$ATT" ] && mv -f "$ATT" "$ATT.prev"
echo "attempt,method,class,executed,duration_s,blockdev,last_cmd1_ocr,ready_bit31,new_card_stuck_busy_msgs" > "$ATT"
{ cat /etc/gwr-build-info 2>/dev/null || echo "build info missing"; echo "boot-time-kernel: $(uname -a)"; echo "run: $RUN_ID"
  echo "config: REBIND_ATTEMPTS=$REBIND_ATTEMPTS RSTN_PULSE=$RSTN_PULSE SOAK_MINUTES=$SOAK_MINUTES SOAK_INTERVAL_S=$SOAK_INTERVAL_S INSTALL=$INSTALL ZERO_WRITE_TIMEOUT_S=$ZERO_WRITE_TIMEOUT_S"
} > "$MNT/build-info.txt"

if [ "$IC" -ge 3 ]; then
  result RECOVERY_INTERRUPTED_REPEATEDLY "Three consecutive runs ended without a result (reset/power loss at stage: see STATE/run-history.txt). Evidence-only stop; nothing destructive was done in this run. Delete STATE/interrupted-count and STATE/in-progress to retry."
fi

live RECOVERY_RUNNING INITIAL_DIAGNOSTICS
instr_on
collect
[ -e "$(host_dev)" ] || result EMMC_CONTROLLER_ABSENT "Platform device $EMMC_HOST does not exist in the running kernel/DT. No eMMC access is possible from Linux."
REACHED="$REACHED INITIAL_DIAGNOSTICS"

# boot-time probe result (from this boot's kernel log, before any action of ours)
BOOT_BUSY=$(dmesg 2>/dev/null | grep -c "$(host_name 2>/dev/null || echo mmc_x): Card stuck being busy")
say "boot-time probe: host=$(host_name 2>/dev/null || echo none) 'Card stuck being busy' messages=$BOOT_BUSY"

DEV=$(find_emmc)
if [ -z "$DEV" ]; then
  REACHED="$REACHED EMMC_INIT_RECOVERY"
  live RECOVERY_RUNNING EMMC_INIT_RECOVERY
  rec_ocr() { [ -n "$LAST_OCR" ] && { LAST_OCR_ANY=$LAST_OCR; LAST_READY_ANY=$LAST_READY; }; return 0; }
  for i in $(seq 1 "$REBIND_ATTEMPTS"); do
    attempt controller_rebind HOST_REPROBE "rebind $i/$REBIND_ATTEMPTS" && break; rec_ocr
    [ $TEST = 1 ] || sleep $((i*10))
  done
  if [ -z "$DEV" ] && [ "$RSTN_PULSE" = 1 ]; then
    for i in 1 2; do attempt rstn_pulse RSTN_PULSE "rstn $i/2" && break; rec_ocr; [ $TEST = 1 ] || sleep 10; done
  fi
  if [ -z "$DEV" ] && [ "$SOAK_MINUTES" -gt 0 ]; then
    SOAK_END=$(( $(date +%s) + SOAK_MINUTES*60 )); k=0
    say "power-on soak: card stays powered (always-on rails); host reprobe every ${SOAK_INTERVAL_S}s for up to ${SOAK_MINUTES} min"
    while [ -z "$DEV" ] && [ "$(date +%s)" -lt "$SOAK_END" ]; do
      k=$((k+1))
      live RECOVERY_RUNNING EMMC_INIT_RECOVERY "soak $k" soak_wait
      if [ $TEST = 1 ]; then :; else sleep "$SOAK_INTERVAL_S"; fi
      attempt soak_rebind HOST_REPROBE "soak $k" && break; rec_ocr
      [ $TEST = 1 ] && [ $k -ge 2 ] && break
    done
  fi
  rec_ocr
  collect
  if [ -z "$DEV" ]; then
    if [ "$LAST_READY_ANY" = 0 ] || [ "$(dmesg 2>/dev/null | grep -c "$(host_name 2>/dev/null || echo mmc_x): Card stuck being busy")" -gt 0 ] || [ "${GWR_TEST_FORCE_STUCK:-0}" = 1 ]; then
      result EMMC_STUCK_NOT_READY "The SoC boots and Linux runs from SD. Controller $EMMC_HOST exists and its driver probes. The eMMC answers CMD1 (SEND_OP_COND) but never sets READY (OCR bit 31) - last OCR observed in this run: ${LAST_OCR_ANY:-not captured by tracepoints, inferred from kernel 'Card stuck being busy'}. Methods tried: $ATTN attempts (host reprobe x$REBIND_ATTEMPTS, EMMC_RSTn pulse if line free, power-on soak ${SOAK_MINUTES} min) - see emmc-init-attempts.txt. Card power could NOT be removed (always-on rails). No block device ever appeared, so erase/write/read were not reachable. Software recovery stops here: the device never leaves its power-up busy state. Escalation: Rockchip MaskROM/loader access (vendor MiniLoaderAll in escalation/), then ISP/BGA rework or eMMC replacement."
    fi
    result EMMC_NOT_DETECTED "No block device on $EMMC_HOST after $ATTN attempts and no CMD1 busy evidence was captured. See emmc-init-attempts.txt, mmc-trace.txt."
  fi
fi

# ============================== eMMC ENUMERATED ===========================================================
EVER_DEV=$DEV; REACHED="$REACHED EMMC_DETECTED"
live EMMC_DETECTED EMMC_DETECTED
live EMMC_DETECTED TARGET_GUARD
gwr_guard "$DEV" || result ABORTED_TARGET_SAFETY_CHECK "TARGET_IDENTIFICATION_FAILED. Nothing was erased. See destructive-actions.txt."
M=$(basename "$DEV"); D=$SYS/sys/block/$M/device
{
  echo "=== eMMC identification ($RUN_ID)"; echo "node: $DEV"; echo "bytes: $(blockdev --getsize64 "$DEV")"
  for f in cid csd name manfid oemid serial date fwrev hwrev prv rev life_time pre_eol_info ext_csd_rev preferred_erase_size erase_size enhanced_area_size rel_sectors ocr; do echo "$f: $(cat "$D/$f" 2>/dev/null)"; done
  echo "discard_max_bytes: $(cat "$SYS/sys/block/$M/queue/discard_max_bytes" 2>/dev/null)"
  echo "=== EXT_CSD (mmc-utils)"; timeout 30 mmc extcsd read "$DEV" 2>&1 | head -200
} | tee -a "$HW" >> "$DA"
REACHED="$REACHED IDENTIFIED"

live DESTRUCTIVE_RECOVERY ERASE
dlog "BEGIN destructive recovery on $DEV"
sync
for p in $(lsblk -nrpo NAME "$DEV" 2>/dev/null | tail -n +2); do umount "$p" 2>>"$DA"; done
gwr_guard "$DEV" || result ABORTED_TARGET_SAFETY_CHECK "guard failed before wipefs"
dlog "wipefs -af $DEV"; timeout 120 wipefs -af "$DEV" >>"$DA" 2>&1; dlog "wipefs exit=$?"

DISC=$(cat "$SYS/sys/block/$M/queue/discard_max_bytes" 2>/dev/null || echo 0)
[ "${GWR_TEST_NODISCARD:-0}" = 1 ] && [ $TEST = 1 ] && DISC=0
ERASED=0
if [ "${DISC:-0}" -gt 0 ]; then
  gwr_guard "$DEV" || result ABORTED_TARGET_SAFETY_CHECK "guard failed before discard"
  te=$(date +%s); dlog "ERASE: whole-device discard on $DEV"
  timeout 3600 blkdiscard "$DEV" >>"$DA" 2>&1; rc=$?; dlog "blkdiscard exit=$rc duration=$(( $(date +%s)-te ))s"
  [ $rc -eq 0 ] && ERASED=1 && ERASE_METHOD=discard
else
  dlog "discard not advertised (discard_max_bytes=$DISC)"
fi
if [ $ERASED -eq 0 ]; then
  gwr_guard "$DEV" || result ABORTED_TARGET_SAFETY_CHECK "guard failed before zero-write"
  te=$(date +%s); dlog "FULL zero-write fallback over $DEV (bounded ${ZERO_WRITE_TIMEOUT_S}s)"
  timeout "$ZERO_WRITE_TIMEOUT_S" dd if=/dev/zero of="$DEV" bs=4M oflag=direct conv=fsync status=none 2>"$WORK/dd.err"; rc=$?
  cat "$WORK/dd.err" >> "$DA"; dlog "zero-write exit=$rc duration=$(( $(date +%s)-te ))s"
  # dd on a block device ends with ENOSPC exactly at the end of the device
  if [ $rc -eq 0 ] || { [ $rc -eq 1 ] && grep -q 'No space left' "$WORK/dd.err"; }; then ERASED=1; ERASE_METHOD=zero-write; fi
fi
[ $ERASED -eq 1 ] || result EMMC_DETECTED_ERASE_FAILED "eMMC enumerated as $DEV but neither discard nor full zero-write completed. See destructive-actions.txt."
REACHED="$REACHED ERASED($ERASE_METHOD)"
blockdev --flushbufs "$DEV" 2>>"$DA"; blockdev --rereadpt "$DEV" >>"$DA" 2>&1; dlog "rereadpt exit=$?"

# reprobe + rediscover + guard
live DESTRUCTIVE_RECOVERY EMMC_REPROBE "post-erase" controller_rebind
reprobe; DEV2=$(wait_emmc 60 | head -1); dlog "post-erase device=${DEV2:-none}"
[ -n "$DEV2" ] || result EMMC_ERASED_VERIFY_FAILED "eMMC disappeared after erase and controller reprobe."
gwr_guard "$DEV2" || result ABORTED_TARGET_SAFETY_CHECK "guard failed after post-erase reprobe"
DEV=$DEV2; M=$(basename "$DEV")

# ---- random write -> flush -> card re-init -> read-back verification -------------------------------------
live DESTRUCTIVE_RECOVERY READWRITE_VERIFY
SZ=$(blockdev --getsize64 "$DEV"); CH=$((4*1024*1024)); NCH=$((SZ/CH))
POS="0 $((NCH/4)) $((NCH/2)) $((3*NCH/4)) $((NCH-1))"   # chunk indices: start, quarters, end
BAD=0
for c in $POS; do
  head -c $CH /dev/urandom > "$WORK/pat-$c.bin"
  gwr_guard "$DEV" || result ABORTED_TARGET_SAFETY_CHECK "guard failed before verify write"
  timeout 120 dd if="$WORK/pat-$c.bin" of="$DEV" bs=$CH seek="$c" count=1 oflag=direct conv=fsync,notrunc status=none 2>>"$DA"; dlog "verify write chunk=$c exit=$?"
done
sync; blockdev --flushbufs "$DEV" 2>>"$DA"
[ $TEST = 1 ] || echo 3 > /proc/sys/vm/drop_caches
live DESTRUCTIVE_RECOVERY EMMC_REPROBE "pre-readback" controller_rebind
reprobe; DEV2=$(wait_emmc 60 | head -1); dlog "pre-readback device=${DEV2:-none}"
[ -n "$DEV2" ] || result EMMC_ERASED_VERIFY_FAILED "eMMC disappeared on re-init between verify write and read-back."
gwr_guard "$DEV2" || result ABORTED_TARGET_SAFETY_CHECK "guard failed before read-back"
DEV=$DEV2
for c in $POS; do
  timeout 120 dd if="$DEV" of="$WORK/rb-$c.bin" bs=$CH skip="$c" count=1 iflag=direct status=none 2>>"$DA"; r=$?
  if cmp -s "$WORK/pat-$c.bin" "$WORK/rb-$c.bin"; then dlog "verify chunk=$c offset=$((c*CH)) OK (read exit=$r)"
  else dlog "verify chunk=$c offset=$((c*CH)) MISMATCH (read exit=$r) $(cmp "$WORK/pat-$c.bin" "$WORK/rb-$c.bin" 2>&1 | head -1)"; BAD=1; fi
done
for c in $POS; do
  gwr_guard "$DEV" || result ABORTED_TARGET_SAFETY_CHECK "guard failed before restoring verify region"
  timeout 120 dd if=/dev/zero of="$DEV" bs=$CH seek="$c" count=1 oflag=direct conv=fsync,notrunc status=none 2>>"$DA"; dlog "restore chunk=$c exit=$?"
done
rm -f "$WORK"/pat-*.bin "$WORK"/rb-*.bin
[ $BAD -eq 0 ] || result EMMC_ERASED_VERIFY_FAILED "Erase completed but random write -> re-init -> read-back verification FAILED (see destructive-actions.txt). No OS was installed."
REACHED="$REACHED READWRITE_VERIFIED"

# ---- install the ORIGINAL golden image -------------------------------------------------------------------
PAY="$MNT/payload"
[ "$INSTALL" = 1 ] || result EMMC_RECOVERED_READWRITE_OK "eMMC erased ($ERASE_METHOD) and write/re-init/read-back verified at start, quarters and end. INSTALL=0 in gwr-config.txt: no OS written."
if ! [ -f "$PAY/golden.img.gz" ]; then
  result EMMC_RECOVERED_READWRITE_OK "eMMC erased and read/write verified, but payload/golden.img.gz is missing - no OS written."
fi
live DESTRUCTIVE_RECOVERY INSTALL
dlog "payload check: sha256 of golden.img.gz"
HGZ=$(sha256sum "$PAY/golden.img.gz" | cut -d' ' -f1)
HIMG=$(gzip -dc "$PAY/golden.img.gz" | sha256sum | cut -d' ' -f1)
dlog "payload gz=$HGZ (expect $GOLDEN_GZ_SHA) raw=$HIMG (expect $GOLDEN_IMG_SHA)"
if [ "$HGZ" != "$GOLDEN_GZ_SHA" ] || [ "$HIMG" != "$GOLDEN_IMG_SHA" ]; then
  result EMMC_RECOVERED_READWRITE_OK_INSTALL_FAILED "eMMC erased and read/write verified, but the golden payload failed its SHA256 check - nothing was installed."
fi
[ "$(blockdev --getsize64 "$DEV")" -gt "$GOLDEN_IMG_BYTES" ] || result EMMC_RECOVERED_READWRITE_OK_INSTALL_FAILED "eMMC smaller than the golden image."
gwr_guard "$DEV" || result ABORTED_TARGET_SAFETY_CHECK "guard failed before install"
ti=$(date +%s); dlog "install: gzip -dc golden.img.gz | dd of=$DEV"
gzip -dc "$PAY/golden.img.gz" | timeout 5400 dd of="$DEV" bs=4M iflag=fullblock oflag=direct conv=fsync status=none 2>>"$DA"
PS=("${PIPESTATUS[@]}"); dlog "install exit gzip=${PS[0]} dd=${PS[1]} duration=$(( $(date +%s)-ti ))s"
sync; blockdev --flushbufs "$DEV" 2>>"$DA"; [ $TEST = 1 ] || echo 3 > /proc/sys/vm/drop_caches
live DESTRUCTIVE_RECOVERY READBACK_VERIFY
# read back EXACTLY the written byte count, BEFORE the GPT backup header is relocated
HRB=$(timeout 2400 dd if="$DEV" bs=4M iflag=direct,count_bytes count=$GOLDEN_IMG_BYTES status=none | sha256sum | cut -d' ' -f1)
dlog "read-back sha256 ($GOLDEN_IMG_BYTES bytes) = $HRB expected $GOLDEN_IMG_SHA"
if [ "${PS[0]}" != 0 ] || [ "${PS[1]}" != 0 ] || [ "$HRB" != "$GOLDEN_IMG_SHA" ]; then
  result EMMC_RECOVERED_READWRITE_OK_INSTALL_FAILED "Golden image write or read-back verification failed (gzip=${PS[0]} dd=${PS[1]} readback=$HRB). eMMC must not be booted."
fi
REACHED="$REACHED INSTALLED READBACK_SHA_OK"

# ---- GPT: move the backup header to the real end of the eMMC (method proven on a throwaway loop image) ----
gwr_guard "$DEV" || result ABORTED_TARGET_SAFETY_CHECK "guard failed before GPT relocation"
dlog "GPT: relocating backup header to the end of $DEV"
timeout 120 sfdisk --relocate gpt-bak-std "$DEV" >>"$DA" 2>&1; rc=$?; dlog "relocate exit=$rc"
timeout 120 sfdisk --verify "$DEV" >>"$DA" 2>&1; vrc=$?; dlog "sfdisk --verify exit=$vrc"
blockdev --rereadpt "$DEV" >>"$DA" 2>&1; [ $TEST = 1 ] || { udevadm settle -t 30; sleep 2; }
[ -n "${GWR_TEST_PARTSCAN_HOOK:-}" ] && [ $TEST = 1 ] && "$GWR_TEST_PARTSCAN_HOOK"
GPT_OK=0; [ $rc = 0 ] && [ $vrc = 0 ] && GPT_OK=1

# ---- partitions derived ONLY from the guarded target (never global label/UUID lookup) --------------------
P1=""; P2=""
for d in "$SYS/sys/block/$M/$M"p*; do
  [ -f "$d/partition" ] || continue
  pn=$(cat "$d/partition"); st=$(cat "$d/start"); sz=$(cat "$d/size")
  dlog "partition $(basename "$d") n=$pn start=$st sectors=$sz"
  [ "$pn" = 1 ] && [ "$st" = $GOLDEN_P1_START ] && [ "$sz" = $GOLDEN_P1_SECTORS ] && P1=$DEVDIR/$(basename "$d")
  [ "$pn" = 2 ] && [ "$st" = $GOLDEN_P2_START ] && [ "$sz" = $GOLDEN_P2_SECTORS ] && P2=$DEVDIR/$(basename "$d")
done
FS_OK=0
if [ -n "$P1" ] && [ -n "$P2" ]; then
  u1=$(blkid -p -s UUID -o value "$P1" 2>/dev/null); u2=$(blkid -p -s UUID -o value "$P2" 2>/dev/null)
  dlog "target p1=$P1 uuid=$u1  p2=$P2 uuid=$u2 (probed directly on the target nodes)"
  e2fsck -fn "$P1" >>"$DA" 2>&1; e1=$?; e2fsck -fn "$P2" >>"$DA" 2>&1; e2=$?
  dlog "e2fsck -fn exit p1=$e1 p2=$e2"
  [ "$u1" = "$GOLDEN_P1_UUID" ] && [ "$u2" = "$GOLDEN_P2_UUID" ] && [ $e1 = 0 ] && [ $e2 = 0 ] && FS_OK=1
else
  dlog "expected golden partitions not found on $DEV after re-read"
fi
if [ $GPT_OK = 1 ] && [ $FS_OK = 1 ]; then
  result EMMC_RECOVERED_AND_LINUX_INSTALLED "eMMC recovered: erased ($ERASE_METHOD), random write/re-init/read-back verified, ORIGINAL golden Armbian written, read-back SHA256 of $GOLDEN_IMG_BYTES bytes = $HRB (matches), GPT backup relocated and verified, BOOT/ROOTFS partitions at golden offsets, e2fsck -n clean."
fi
result EMMC_RECOVERED_READWRITE_OK_INSTALL_FAILED "Golden image written and read-back SHA256 matched, but post-install checks failed (GPT relocate/verify ok=$GPT_OK, partitions/fs ok=$FS_OK). See destructive-actions.txt."
