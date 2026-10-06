# Why Great Wall V1 never reached the Linux recovery stage

Analysed from the actual flashed artifact `great-wall-dc-a568-recovery.img`
(sha256 `7b8ed4275655db72703c7c81ff4ed9daab2ac048c7dff3c8d17fd8a08541ffbc`,
from `great-wall-dc-a568-recovery.img.zst` sha256 `9d5408f14b9ccc4228853f88861f9f690bd58e2729f55ea93748fb73f1070c81`),
decompressed and loop-mounted read-only.

## Symptom (on the real board)
V1 was written to SD, run ~30 min in the DC-A568B, and produced **no** runtime files on RECOVERYLOG
(no `recovery-run.log`, `DONE.txt`, `mmc-trace.txt`, …); `RECOVERY-RESULT.txt` kept its image-creation
timestamp. So V1 never reached `/usr/local/sbin/gwr-recovery.sh` (the Linux Stage-2).

## Root cause: the U-Boot Stage-1 snippet
V1 injected a snippet into `boot.cmd` that ran **inside U-Boot before Linux**:

```
while test "${gwr_try}" -lt 5; do
    if mmc dev ${gwr_n}; then if mmc rescan ${gwr_n}; then setenv gwr_res "ok"; fi; fi
    if test "${gwr_res}" = "ok"; then setenv gwr_try 99; else
        setexpr gwr_try ${gwr_try} + 1    # <-- increments the loop counter
        sleep 1
    fi
done
```

The loop only terminates when `gwr_try` reaches 5 (or 99), and the **only** thing that increments
`gwr_try` is `setexpr`. I extracted the U-Boot binary from both the V1 and the golden `u-boot.itb`
(FIT image 0, "U-Boot", 1383008 bytes) and searched the command table:

| command | V1 u-boot.bin | golden u-boot.bin |
|---|---|---|
| `mmc`, `mmc rescan` | present | present |
| `test`, `while`, `sleep`, `setenv`, `gpio`, `fdt resize` | present | present |
| **`setexpr`** | **absent (0)** | **absent (0)** |

Armbian's `rockchip64` U-Boot (2017.09-based FIT, identical command set in V1 and golden) is built
**without `CONFIG_CMD_SETEXPR`**. When the hush parser hits an unknown command it prints
`Unknown command 'setexpr'` and continues, so `gwr_try` is **never incremented** → the `while` loop
can never reach 5 → **infinite loop in U-Boot**. The kernel is never booted, Linux never starts, and
RECOVERYLOG never receives a single runtime file. This matches the observed symptom exactly.

Secondary V1 differences (not the failure cause, but avoided in V2 anyway): FAT `/boot` instead of
golden ext4; kernel 6.18.55-current-rockchip64 instead of the proven 6.18.53-ophub; a different DTB; the
service used `Before=network-pre.target` (would hold off networking) and `Type=oneshot`; and the installer
assumed `zstd`/`sgdisk`, which are absent from the golden rootfs.

## V2 consequence
**V2 has no U-Boot Stage-1 at all.** It boots the golden chain byte-for-byte (idbloader, `u-boot.itb`,
`boot.scr`, kernel, initramfs, DTB, `armbianEnv.txt` all unchanged — proven by SHA256 in VERIFY-REPORT.md)
and does every bit of eMMC work from Linux userspace, where the command set is complete and bounded loops
are trivial to guarantee.
