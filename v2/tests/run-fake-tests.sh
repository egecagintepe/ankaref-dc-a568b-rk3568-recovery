#!/bin/bash
# Fake-hardware tests: the REAL gwr-recovery.sh runs in test mode against a fake sysfs tree whose
# "eMMC" block device is a sparse loop-backed FILE. No physical disk is ever used.
# usage: run-fake-tests.sh <repo> <golden.img.gz> <golden.img raw>
set -u
REPO=$1; GZ=$2; GOLD=$3
SCRIPT=$REPO/v2/rootfs/usr/local/sbin/gwr-recovery.sh
T=/root/gw2/fake; rm -rf $T; mkdir -p $T
P=0; F=0
ok(){ echo "PASS: $*"; P=$((P+1)); }; ko(){ echo "FAIL: $*"; F=$((F+1)); }
GIB=$((1024**3))

mkfake() { # $1 name(mmcblkN) $2 loopdev $3 host-path-component  -> fake sysfs entry + dev symlink
  local n=$1 lo=$2 host=$3 card
  card=$T/sys/devices/platform/$host/mmc_host/mmc1/mmc1:0001
  mkdir -p "$card" "$T/sys/block/$n/queue" "$T/dev"
  echo MMC > "$card/type"; echo 0 > "$T/sys/block/$n/removable"; echo "179:${n#m