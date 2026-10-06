# Great Wall V2 — BUILD REPORT

**Approach:** golden offline patch (NOT an Armbian rebuild). A copy of the physically-proven golden image
was patched locally in WSL2 (Debian 13); only a loop-mounted copy was ever touched. No GitHub Actions, no
physical disk writes, golden original never modified.

## 1. Deliverable
| | |
|---|---|
| Raw image | `great-wall-v2-golden-recovery.img` |
| Raw size | **5 846 859 776** bytes (5.45 GiB) |
| Raw SHA256 | `93b6c5bc4ee23c2ede222f83659013d286940a03cdbf212cf9851ddf184de515` |
| Transport | `great-wall-v2-golden-recovery.img.gz` (1 594 189 583 bytes, pigz -6) |
| Gz SHA256 | `a37a0ec1ded0299909d042708c8362c6126351e1a89cffe701e2f7d0659416cd` |
| Gz → decompressed SHA256 | `93b6c5bc…4de515` (equals raw — roundtrip verified) |

## 2. Golden source (verified before use)
- `.gz` sha256 `016a11416caea7729f35006b83a8e2a003ba77defd4e3f1b6522fca9e69074aa` ✓
- raw sha256 `c99b13ea629860a321ff489e4bcc53e651cc5a49b31e340733b8f999b5d6f0c6` ✓
  (re-derived with pigz, python-gzip and the gzip CRC32/ISIZE trailer; 3 699 376 128 bytes)

## 3. Boot chain — preserved byte-identical (SHA256, V2 vs golden)
| region | sha256 |
|---|---|
| idbloader (LBA 64, RK BootROM) | `28d3d039…36eef2` ✓ |
| u-boot.itb (LBA 16384, FIT) | `67920164…c28cef` ✓ |
| everything LBA 34–32767 | `135b2b2a…72db165` ✓ |
| p1 BOOT (whole ext4, 511 MiB) | `2a96ce76…24b5812b` ✓ |

Boot files individually identical too: `vmlinuz-6.18.53-ophub`, `uInitrd`, `initrd.img`,
`rk3568-ztl-a568.dtb`, `boot.scr`, `boot.cmd`, `armbianEnv.txt`, and the `Image`/`uInitrd` symlinks.
`boot.scr` contains **no** Great Wall code. Filesystem UUIDs/labels of BOOT and ROOTFS are unchanged.

## 4. Partition layout (final)
```
GPT, label-id F90034FF-947C-44A3-8B33-6928EFE543A7 (golden's)
p1  32768    +1046528  (511 MiB) ext4 BOOT    PARTUUID 81794D3E… (golden, unchanged)
p2  1081344  +6141952  (2.9 GiB) ext4 ROOTFS  PARTUUID CAC66463… (golden, unchanged)
p3  7223296  +4194304  (2 GiB)   FAT32 RECOVERYLOG   (new, appended after ROOTFS)
backup GPT moved to the real end of the enlarged image; sfdisk --verify + sgdisk -v clean
```
p1/p2 start, size, type and PARTUUID are byte-for-byte the golden values; only the image file was
enlarged and p3 appended. GPT relocation used `sfdisk --relocate gpt-bak-std`, the exact command first
proven on a throwaway 29 GiB loop image.

## 5. ROOTFS changes (complete list — nothing else differs from golden)
Added: `/usr/local/sbin/gwr-recovery.sh`, `/etc/systemd/system/gwr-recovery.service` (+ enable symlink),
`/etc/gwr-build-info`, `/root/.no_rootfs_resize`.
Disabled: `armbian-resize-filesystem` (wants-symlink removed; golden already ships `.no_rootfs_resize`
too → resize cannot grow ROOTFS into RECOVERYLOG), `ssh.service`/`ssh.socket` (masked → `/dev/null`;
golden enables root-password SSH with a default password), `unattended-upgrades.service`,
`apt-daily.timer`, `apt-daily-upgrade.timer`. NetworkManager left enabled.

## 6. RECOVERYLOG contents
`payload/golden.img.gz` (the ORIGINAL proven image, gz sha256 `016a1141…`, raw `c99b13ea…`),
`payload/target.img.sha256` + `.size` + `source-golden-sha256.txt` + `MANIFEST.sha256`,
`escalation/vendor-MiniLoaderAll.bin` (RK3568 loader from GB-RK3568-11 for MaskROM escalation),
`README.txt`, `gwr-config.txt`, `build-info.txt`, `RECOVERY-RESULT.txt`=NOT_RUN_YET, empty `STATE/`.

## 7. Dependencies
Script uses only tools present in the golden rootfs (bash, systemctl, wipefs, blkdiscard, dd, sfdisk,
gzip, sha256sum, e2fsck, blkid, lsblk, findmnt, mmc, gpioset/gpioinfo, timeout, flock, udevadm,
journalctl). It needs **no** zstd/sgdisk/xxd (the gaps that broke V1's installer path).

## 8. eMMC pre-enumeration recovery sequence (Linux, bounded)
1. Instrument: mmc tracepoints filtered to the eMMC host + narrow dynamic debug on sdhci/dwcmshc.
2. `REBIND_ATTEMPTS`×(default 3) controller **unbind/bind** of `fe310000.mmc` — **HOST_REPROBE**:
   re-runs SDHCI/controller reset + one full CMD0/CMD1 init at 400/300/200/100 kHz.
3. If still absent and the line is unused: up to 2× **EMMC_RSTn pulse** (GPIO1_C7, datasheet ball F20),
   driven low 100 ms→high through the gpio chardev while the host is unbound — **RSTN_PULSE**.
4. Power-on **soak** (default 60 min, reprobe every 5 min) — the card stays powered (rails are always-on).
Each attempt logs method, honest class, duration, observed CMD1 OCR and READY bit to
`emmc-init-attempts.txt`. **Power removal is never claimed:** vmmc=vcc3v3_sys and vqmmc=vcc_1v8 are
always-on fixed/PMIC rails (regulator summary), so true VCC/VCCQ removal is impossible in software and the
report says so. No infinite loops; no raw MMIO; no guessed GPIOs.

## 9. Local toolchain & safety
WSL2 Debian 13. Built from `v2/build/build-v2.sh`; verified by `v2/build/verify-v2.sh` (74/74 PASS) and
`v2/tests/{check-destructive.sh,sim-destructive.sh}`. `bash -n` passes under both the host bash and the
golden image's own aarch64 bash 5.2.15 (run via qemu-user). `shellcheck -S error` clean.

## 10. Source control
Repo `egecagintepe/ankaref-dc-a568b-rk3568-recovery`. V2 sources under `v2/`. Commit SHA: _see VERIFY-REPORT / git log_.

**No GitHub workflow was started. No physical disk was written. The golden original was not modified.**
