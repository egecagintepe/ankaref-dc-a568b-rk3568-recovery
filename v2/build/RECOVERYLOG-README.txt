GREAT WALL V2 - DC-A568B V01 internal eMMC recovery (RECOVERYLOG partition)

1. Write the image to the microSD. Insert it into the DC-A568B, connect Ethernet if available, power on.
2. The board boots the unmodified golden Armbian. The recovery service starts by itself.
   Network (DHCP / ping) comes up in parallel. SSH is deliberately disabled.
3. Wait until the board powers OFF by itself. Without eMMC enumeration that takes about 70-80 min
   (bounded soak). With erase and install it can take up to ~4 h if the zero-write fallback is needed.
4. Put the SD card into a PC and open this drive:
     LIVE-STATUS.txt        current or last stage (updated atomically)
     RECOVERY-RESULT.txt    final result + explanation (first line RESULT=...)
     DONE.txt               written only when a run has finished
     emmc-init-attempts.txt every init attempt: method, class, observed CMD1 OCR, READY bit
     attempts/              per-attempt tracepoint snapshots
     recovery-run.log, mmc-trace.txt, hardware-identification.txt, destructive-actions.txt,
     full-dmesg.txt, journal-*.txt, build-info.txt
5. RESULT=EMMC_RECOVERED_AND_LINUX_INSTALLED:
     POWER OFF -> REMOVE THE RECOVERY SD -> POWER ON (the board then boots golden Armbian from eMMC).
   STATE/terminal.done prevents this SD from ever erasing the eMMC again. Delete that file to allow a new run.

gwr-config.txt lets you change the bounded retry budget (numeric values only, hard limits enforced).
escalation/vendor-MiniLoaderAll.bin is the RK3568 loader extracted from the vendor firmware
GB-RK3568-11-220713-151805-AAA.img. Use it for Rockchip MaskROM access from a PC (rkdeveloptool db / rfi)
if software recovery from Linux stops at EMMC_STUCK_NOT_READY.
