# Great Wall V2 — VERIFY REPORT

Generated 2026-10-06 14:24:48 UTC. All checks are offline (read-only loop mounts / sector hashes); no physical media involved.

## Static + offline suite results
- `bash -n` (host + golden aarch64 bash 5.2.15 via qemu-user): PASS
- `shellcheck -S error`: PASS (clean)
- `v2/tests/check-destructive.sh` (script + unit): all PASS
- `v2/build/verify-v2.sh` (image vs golden): **74 PASS / 0 FAIL**
- `v2/tests/sim-destructive.sh` (fake sysfs + loop devices): **23 PASS / 0 FAIL**

## Target-guard negative tests (each must REJECT)
target==root disk, target==RECOVERYLOG disk, SD host fe2b0000, capacity<20GiB, removable=1, type!=MMC, major!=179, >1 device on host, mounted target — all rejected. Good 32 GiB eMMC on fe310000 accepted.

## Full destructive flow on a disposable 24 GiB loop (real I/O, fake sysfs)
guard→wipefs→zero-write(no-discard path)→erase cleared start→random write/re-init/read-back OK at 5 points→golden written→read-back SHA256==c99b13ea… →GPT relocate+verify→partitions at golden offsets→terminal EMMC_RECOVERED_AND_LINUX_INSTALLED→terminal.done written. Re-run short-circuits to ALREADY_COMPLETED and leaves the device untouched. No-enumerate path →EMMC_STUCK_NOT_READY with zero destructive ops.

## Boot-chain preservation (SHA256, V2 vs golden — identical)
| region | V2 = golden |
|---|---|
| idbloader LBA64 | 28d3d039…36eef2 |
| u-boot.itb LBA16384 | 67920164…c28cef |
| LBA 34–32767 | 135b2b2a…72db165 |
| p1 BOOT ext4 | 2a96ce76…24b5812b |

boot.scr/boot.cmd/armbianEnv.txt/kernel/initramfs/DTB individually identical; boot.scr carries no GWR code.

## Payload
RECOVERYLOG/payload/golden.img.gz: gz sha256 016a1141… ✓, decompresses to c99b13ea… ✓ (3 699 376 128 bytes), MANIFEST.sha256 verifies.

## Final image hashes
- raw: `93b6c5bc4ee23c2ede222f83659013d286940a03cdbf212cf9851ddf184de515` (5 846 859 776 B)
- gz:  `a37a0ec1ded0299909d042708c8362c6126351e1a89cffe701e2f7d0659416cd` (1 594 189 583 B)
- gz→decompressed == raw ✓

## Not tested here (no hardware in this environment)
- Actual boot on the DC-A568B (golden chain is byte-identical to the already-proven golden image, so boot behaviour is expected unchanged).
- Real eMMC enumeration/erase on silicon (the destructive logic is proven on loop devices; the guard forbids acting on anything but a 20–40 GiB non-removable MMC on fe310000).
- Whether the V01 PCB populates the heartbeat LED (LED is runtime-verified and fail-safe; absence is harmless).
