# ankaref-dc-a568b-rk3568-recovery

Software recovery of the **internal eMMC** on a **Great Wall / Dingchang DC-A568B V01** board
(Rockchip RK3568, eMMC controller `fe310000.mmc`). The board boots fine from microSD; its internal
eMMC answers CMD1 (OCR `0x40ff8080`) but never sets the READY bit ("Card stuck being busy"), so no
`/dev/mmcblkX` appears. This project builds a bootable microSD recovery image that tries, from Linux,
to force the eMMC into a usable state and then install a known-good Armbian onto it — collecting
forensic evidence if it cannot.

> Data on the internal eMMC is disposable. Full destructive access to the **internal eMMC only** is
> intended. The recovery SD and the host PC are never targets: every destructive action is gated by a
> strict target guard (internal controller `fe310000.mmc`, non-removable MMC, 20–40 GiB, exactly one
> device on that host, not the root/log disk, nothing mounted).

---

## ✅ Current version — **V2** (`v2/`)

**V2 is the version to use.** It is a *golden offline patch*: a copy of the physically-proven golden
Armbian image is patched locally, preserving the entire boot chain **byte-for-byte**, and all eMMC work
runs from Linux userspace.

| | |
|---|---|
| Boot chain | golden idbloader + `u-boot.itb` + `boot.scr` + kernel 6.18.53-ophub + DTB + `armbianEnv.txt`, all SHA256-identical (proven in [`v2/docs/VERIFY-REPORT.md`](v2/docs/VERIFY-REPORT.md)) |
| U-Boot stage-1 | **none** (this is what killed V1 — see below) |
| eMMC recovery | Linux only: bounded host reprobe → EMMC_RSTn pulse → power-on soak → erase → random R/W re-init verify → install the **original golden image** → read-back SHA256 → GPT relocate → fs verify |
| Target guard | before **every** destructive command |
| Tools needed | only what the golden rootfs already has (gzip not zstd, sfdisk not sgdisk) |
| Build | **local** (WSL2/Linux), no GitHub Actions, no disk writes |

### Layout
```
v2/rootfs/usr/local/sbin/gwr-recovery.sh        recovery logic (Linux Stage-2)
v2/rootfs/etc/systemd/system/gwr-recovery.service
v2/build/build-v2.sh                            builds the image from a golden .img.gz
v2/build/verify-v2.sh                           offline verification vs golden (74 checks)
v2/build/{RECOVERYLOG-README,gwr-config}.txt    files placed on the RECOVERYLOG partition
v2/tests/check-destructive.sh                   static safety review (guards, forbidden patterns)
v2/tests/sim-destructive.sh                     full destructive flow on fake sysfs + loop devices
v2/docs/{BUILD-REPORT,VERIFY-REPORT,V1-FAILURE-ANALYSIS}.md
v2/tools-rkunpack.py                            read-only RKFW/RKAF firmware unpacker
```

### Build it yourself
```bash
# in WSL2 / Linux, as root; needs: gdisk? no — only util-linux sfdisk, dosfstools, gzip, e2fsprogs, qemu-user (optional)
bash v2/build/build-v2.sh  <golden.img.gz>  <repo-dir>  <out-dir>  [vendor-MiniLoaderAll.bin]
bash v2/build/verify-v2.sh <out-dir>/great-wall-v2-golden-recovery.img  <golden.img raw>  <repo-dir>
bash v2/tests/sim-destructive.sh <repo-dir> <golden.img.gz>
```
The golden image is not stored in git (multi-GB). Its hashes:
`.gz` `016a11416caea7729f35006b83a8e2a003ba77defd4e3f1b6522fca9e69074aa`,
raw `c99b13ea629860a321ff489e4bcc53e651cc5a49b31e340733b8f999b5d6f0c6`.

### Using the image
Flash `great-wall-v2-golden-recovery.img` to a microSD, boot the DC-A568B, wait until it powers off,
then read the `RECOVERYLOG` FAT32 partition (`RECOVERY-RESULT.txt`, `LIVE-STATUS.txt`, logs). On
`EMMC_RECOVERED_AND_LINUX_INSTALLED`: power off → remove SD → power on. Full operator notes:
[`v2/build/RECOVERYLOG-README.txt`](v2/build/RECOVERYLOG-README.txt).

---

## ⚠️ V1 — **deprecated, never worked** (`custom/`, `scripts/`, `.github/workflows/`)

V1 was built in GitHub Actions and flashed to SD, but **never reached the Linux recovery stage**: it
injected a U-Boot stage-1 snippet into `boot.cmd` that used `setexpr` to advance a `while` loop, and
Armbian's rockchip64 U-Boot is built **without `CONFIG_CMD_SETEXPR`** → the loop never terminated →
infinite loop in U-Boot → Linux never booted. Full proof from the actual flashed artifact:
[`v2/docs/V1-FAILURE-ANALYSIS.md`](v2/docs/V1-FAILURE-ANALYSIS.md).

These paths are kept for history only. **Do not reuse** `custom/userpatches/overlay/gwr-uboot-stage1.cmd`
or dispatch the `.github/workflows/*` build — V2 replaces all of it and is built locally.
