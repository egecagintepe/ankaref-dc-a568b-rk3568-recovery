# Great Wall Recovery - STAGE 1 (runs inside U-Boot, before Linux).
# Uses U-Boot's own MMC stack. Non-destructive: only 'mmc dev'/'mmc rescan'.
# Never selects a boot/erase target; SD boot continues no matter what happens.
setenv gwr_state ""
setenv gwr_ok ""
for gwr_n in 0 1 2; do
	setenv gwr_try 0
	setenv gwr_res "fail"
	while test "${gwr_try}" -lt 5; do
		if mmc dev ${gwr_n}; then
			if mmc rescan ${gwr_n}; then setenv gwr_res "ok"; fi
		fi
		if test "${gwr_res}" = "ok"; then setenv gwr_try 99; else
			setexpr gwr_try ${gwr_try} + 1
			sleep 1
		fi
	done
	setenv gwr_state "${gwr_state}${gwr_n}:${gwr_res},"
done
# restore the device we booted from (explicit devnum is used for all loads anyway)
mmc dev ${devnum}
echo "GWR stage1 mmc probe: ${gwr_state}"
setenv extraargs "${extraargs} gwr_uboot_mmc=${gwr_state}"
