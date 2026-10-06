# RECOVERY-DESIGN - Great Wall Recovery, DC_A568 RK3568

## Base (verified from upstream)
armbian/build `config/boards/ztl-a568.wip`: BOARDFAMILY=rk35xx, BOOTCONFIG=radxa-e25-rk3568_defconfig,
BOOT_FDT_FILE=rockchip/rk3568-ztl-a568.dtb, BOOT_SCENARIO=spl-blobs, GPT, FAT boot fs. DTS added by PR #10761.
No other board DTB is used. Armbian commit is recorded in BUILD-REPORT.md.

## Stage 1 - U-Boot (custom/userpatches/overlay/gwr-uboot-stage1.cmd)
Inserted into /boot/boot.cmd (recompiled to boot.scr) before bootargs are composed. Uses U-Boot's own MMC
stack: for mmc devices 0..2, up to 5x `mmc dev` + `mmc rescan` with 1 s pauses (each rescan re-runs the
full init incl. U-Boot's power cycle). Non-destructive; SD boot always continues. Result is passed to Linux
as `gwr_uboot_mmc=0:ok,1:fail,2:fail,` on the kernel command line.
Not done (limitations): U-Boot's CMD1 timeout is not patched (unverifiable without hardware/CI source tree),
forced 400/300/200/100 kHz init is not done, and CID/capacity are not captured in U-Boot (`mmc info`
output cannot be stored in env). Linux collects CID/CSD/EXT_CSD if the card enumerates.
U-Boot device numbers are not mapped to physical controllers; the flags are diagnostic only.

## Stage 2 - Linux (gwr-recovery.service -> /usr/local/sbin/gwr-recovery.sh)
1. Mounts FAT32 RECOVERYLOG, enables mmc dynamic debug, collects diagnostics.
2. If no block device appears on fe310000.mmc: up to 4x unbind/bind of the controller driver (host
   re-init + power cycle), 45 s wait each, overall ~15 min bound. Kernel frequency forcing is not exposed in sysfs
   before a card exists, so low-rate init is whatever the driver does.
3. No device -> RESULT=EMMC_STUCK_NOT_READY (mmc1 exists + timeout pattern or U-Boot fail) else EMMC_NOT_DETECTED.
4. Device present -> `gwr_guard` (below) -> log CID/CSD/EXT_CSD -> wipefs -> blkdiscard (else bounded 3600 s zero-write)
   -> rereadpt -> controller reprobe -> write/read/compare 1 MiB at start/middle/end (zeroed afterwards)
   -> if payload present: sha256 check, write, sgdisk -e, read-back sha256, sgdisk -v, e2fsck -n.
5. Terminal: RECOVERY-RESULT.txt, DONE.txt, sync, poweroff after 45 s. A `RESULT=EMMC_RECOVERED*` state is stored in
   STATE/terminal.done; later boots do nothing destructive.

## Target safety guard (gwr_guard, run before EVERY destructive command)
Target must: not be the root-backing disk or RECOVERYLOG disk; be sysfs type MMC with removable=0; resolve
(readlink of /sys/block/X/device) through `fe310000.mmc`; not through SD hosts fe2b0000/fe2c0000; be 20-40 GiB;
and be the only block device on that host. Any failure logs TARGET_IDENTIFICATION_FAILED and ends with
RESULT=ABORTED_TARGET_SAFETY_CHECK. Devices are never chosen by name order or size alone. (Assumption: SD host
is fe2b0000; the 461 GiB card is excluded by the host-path and capacity checks independently.)

## Install payload
A plain Armbian ZTL-A568 image built from the same board config (target.img.zst on RECOVERYLOG/payload).
Rockchip BootROM reads the same LBA64 idbloader layout from eMMC as from SD. Not boot-tested on hardware.

## Not implemented
LED signalling (secondary; DTS LED nodes not verified). Kernel/U-Boot source patches: none (no kernel or U-Boot
patch applied; the stock Armbian kernel's DYNAMIC_DEBUG is assumed - check mmc-trace.txt).
