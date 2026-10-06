#!/bin/bash
# usage: postprocess.sh recovery.img target.img.zst target.img.size target.img.sha256
# Appends RECOVERYLOG FAT32 partition + payload to the IMAGE FILE only (loop devices on the CI runner).
set -euo pipefail
IMG=$1; Z=$2; SIZEF=$3; SHAF=$4
EXTRA=$((3*1024*1024*1024))
cur=$(stat -c %s "$IMG"); truncate -s $((cur+EXTRA)) "$IMG"
sgdisk -e "$IMG"
sgdisk -n 0:0:0 -t 0:0700 -c 0:RECOVERYLOG "$IMG"
sgdisk -p "$IMG"
LO=$(sudo losetup -fP --show "$IMG")
trap 'sudo umount /mnt/gwr-pp 2>/dev/null || true; sudo losetup -d "$LO" 2>/dev/null || true' EXIT
N=$(sgdisk -p "$IMG" | awk '$7=="RECOVERYLOG"{print $1}')
test -n "$N"
sudo mkfs.vfat -F32 -n RECOVERYLOG "${LO}p${N}"
sudo mkdir -p /mnt/gwr-pp; sudo mount "${LO}p${N}" /mnt/gwr-pp
sudo mkdir -p /mnt/gwr-pp/payload /mnt/gwr-pp/STATE
sudo cp "$Z" /mnt/gwr-pp/payload/target.img.zst
sudo cp "$SIZEF" /mnt/gwr-pp/payload/target.img.size
sudo cp "$SHAF" /mnt/gwr-pp/payload/target.img.sha256
printf 'RESULT=NOT_RUN_YET\n\nRecovery has not run on a board yet. Boot this SD in the DC-A568B and wait; it powers off when finished.\n' | sudo tee /mnt/gwr-pp/RECOVERY-RESULT.txt >/dev/null
sync; sudo umount /mnt/gwr-pp
