#!/bin/bash
# Great Wall V2 LOCAL build (WSL2/Linux). Patches a COPY of the physically proven golden image:
#   - boot chain (LBA 64..32767) and p1 BOOT: untouched, byte-identical (verified below)
#   - p2 ROOTFS: recovery script + unit + build-info added; resize/ssh/auto-upgrade disabled
#   - image file enlarged, GPT backup moved to the new end, p3 FAT32 RECOVERYLOG appended with payload
# Operates on regular files and loop devices ONLY. Never touches a physical disk.
# usage: build-v2.sh <golden.img.gz> <repo-dir> <out-dir> [vendor MiniLoaderAll.bin]
set -euo pipefail
GZ=$1; REPO=$2; OUT=$3; LOADER=${4:-}
GOLDEN_GZ_SHA=016a11416caea7729f35006b83a8e2a003ba77defd4e3f1b6522fca9e69074aa
GOLDEN_IMG_SHA=c99b13ea629860a321ff489e4bcc53e651cc5a49b31e340733b8f999b5d6f0c6
GOLDEN_BYTES=3699376128
P3_START=7223296; P3_SECTORS=4194304        # 2 GiB RECOVERYLOG directly after golden ROOTFS (ends 7223295)
TOTAL_SECTORS=$((P3_START+P3_SECTORS+2048))  # + room for the backup GPT, 1 MiB aligned
IMG=$OUT/great-wall-v2-golden-recovery.img
log(){ echo "[build $(date +%T)] $*"; }
mkdir -p "$OUT"; W=$(mktemp -d /root/gw2/build.XXXX)
cleanup(){ set +e; umount "$W/r" "$W/l" 2>/dev/null; [ -n "${LO:-}" ] && losetup -d "$LO"; }
trap cleanup EXIT

log "verify golden .gz"; [ "$(sha256sum "$GZ" | cut -d' ' -f1)" = $GOLDEN_GZ_SHA ]
log "decompress golden to working copy"; gzip -dc "$GZ" > "$W/golden.img"
[ "$(stat -c %s "$W/golden.img")" = $GOLDEN_BYTES ]
[ "$(sha256sum "$W/golden.img" | cut -d' ' -f1)" = $GOLDEN_IMG_SHA ]
cp --sparse=always "$W/golden.img" "$IMG"

log "enlarge image file + relocate backup GPT + append RECOVERYLOG"
truncate -s $((TOTAL_SECTORS*512)) "$IMG"
sfdisk --relocate gpt-bak-std "$IMG"
echo "start=$P3_START, size=$P3_SECTORS, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name=\"RECOVERYLOG\"" | sfdisk --append --no-reread "$IMG"
sfdisk --verify "$IMG"

LO=$(losetup -fP --show "$IMG"); udevadm settle 2>/dev/null || true; sleep 1
mkfs.vfat -F 32 -n RECOVERYLOG "${LO}p3" >/dev/null
mkdir -p "$W/r" "$W/l"

log "patch ROOTFS (p2)"
mount "${LO}p2" "$W/r"; R=$W/r
install -D -m 0755 "$REPO/v2/rootfs/usr/local/sbin/gwr-recovery.sh" "$R/usr/local/sbin/gwr-recovery.sh"
install -D -m 0644 "$REPO/v2/rootfs/etc/systemd/system/gwr-recovery.service" "$R/etc/systemd/system/gwr-recovery.service"
ln -sf /etc/systemd/system/gwr-recovery.service "$R/etc/systemd/system/multi-user.target.wants/gwr-recovery.service"
# resize: must never grow ROOTFS over RECOVERYLOG (script honours /root/.no_rootfs_resize as well)
rm -f "$R/etc/systemd/system/multi-user.target.wants/armbian-resize-filesystem.service"
touch "$R/root/.no_rootfs_resize"
# ssh: golden enables root password login with a default password -> masked (firstrun's 'service ssh restart' then fails harmlessly)
rm -f "$R/etc/systemd/system/multi-user.target.wants/ssh.service" "$R/etc/systemd/system/sockets.target.wants/ssh.socket"
ln -sf /dev/null "$R/etc/systemd/system/ssh.service"; ln -sf /dev/null "$R/etc/systemd/system/ssh.socket"
# no package upgrades on the recovery SD (could rewrite /boot during a recovery run)
rm -f "$R/etc/systemd/system/multi-user.target.wants/unattended-upgrades.service" \
      "$R/etc/systemd/system/timers.target.wants/apt-daily.timer" "$R/etc/systemd/system/timers.target.wants/apt-daily-upgrade.timer"
COMMIT=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
cat > "$W/gwr-build-info" <<EOF
Great Wall V2 (golden offline patch)  built $(date -u '+%F %T UTC') on $(hostname) (local WSL build, no CI)
base: Armbian_26.11.0_rockchip_ztl-a568_bookworm_6.18.53_server_2026.09.26.img.gz sha256=$GOLDEN_GZ_SHA
base raw sha256=$GOLDEN_IMG_SHA
repo commit (source of scripts): $COMMIT
gwr-recovery.sh sha256=$(sha256sum "$R/usr/local/sbin/gwr-recovery.sh" | cut -d' ' -f1)
gwr-recovery.service sha256=$(sha256sum "$R/etc/systemd/system/gwr-recovery.service" | cut -d' ' -f1)
boot chain: golden, unmodified (no U-Boot stage-1)
EOF
install -m 0644 "$W/gwr-build-info" "$R/etc/gwr-build-info"
sync; umount "$W/r"

log "populate RECOVERYLOG (p3)"
mount "${LO}p3" "$W/l"; L=$W/l
mkdir -p "$L/payload" "$L/STATE" "$L/escalation"
cp "$GZ" "$L/payload/golden.img.gz"
echo "$GOLDEN_IMG_SHA  golden.img" > "$L/payload/target.img.sha256"
echo "$GOLDEN_BYTES" > "$L/payload/target.img.size"
echo "$GOLDEN_GZ_SHA  golden.img.gz" > "$L/payload/source-golden-sha256.txt"
[ -n "$LOADER" ] && [ -f "$LOADER" ] && cp "$LOADER" "$L/escalation/vendor-MiniLoaderAll.bin"
cp "$REPO/v2/build/RECOVERYLOG-README.txt" "$L/README.txt"
cp "$REPO/v2/build/gwr-config.txt" "$L/gwr-config.txt"
cp "$W/gwr-build-info" "$L/build-info.txt"
printf 'RESULT=NOT_RUN_YET\r\n\r\nGreat Wall V2 has not run on a board yet. Boot this SD in the DC-A568B and wait; it powers off by itself when finished.\r\n' > "$L/RECOVERY-RESULT.txt"
(cd "$L" && sha256sum payload/* > payload/MANIFEST.sha256)
sync; umount "$W/l"
losetup -d "$LO"; LO=""
log "done: $IMG ($(stat -c %s "$IMG") bytes)"
