#!/bin/bash
# Static review of gwr-recovery.sh: every destructive command must have a gwr_guard call
# (with abort-on-fail) within the preceding WINDOW lines, and the guard must encode every required check.
# usage: check-destructive.sh /path/to/gwr-recovery.sh
set -u
F=$1; WINDOW=10; fail=0
p(){ echo "$1: $2"; if [ "$1" = FAIL ]; then fail=1; fi; return 0; }
awk -v W=$WINDOW '
  /^gwr_guard\(\)/ {inguard=1} inguard && /^}/ {inguard=0; next} inguard {next}
  /^[[:space:]]*#/ {next}
  /gwr_guard "\$DEV2?" *\|\| *result ABORTED_TARGET_SAFETY_CHECK/ {last=NR; used=0}
  /(^|[^a-z_])(blkdiscard|wipefs) / || /of="\$DEV"/ || /sgdisk -e "\$DEV"/ {
     ok = (last>0 && NR-last<=W && !used); used=1;
     printf "%s line %d: %s\n", (ok?"PASS":"FAIL"), NR, substr($0,1,90)
  }' "$F" > /tmp/destr.$$
cat /tmp/destr.$$; grep -q '^FAIL' /tmp/destr.$$ && fail=1
n=$(grep -c '^PASS' /tmp/destr.$$); [ "$n" -ge 7 ] && p PASS "$n destructive commands all guard-protected" || p FAIL "only $n destructive commands matched (expected >=7)"
rm -f /tmp/destr.$$
if grep -B1 'head -c \$MB /dev/urandom' "$F" | grep -q 'gwr_guard "\$DEV" || result ABORTED'; then p PASS "verify loop: guard at top of every iteration"; else p FAIL "verify loop: no guard at loop top"; fi
G=$(awk '/^gwr_guard\(\)/,/^}/' "$F")
chkg(){ if grep -q -- "$2" <<<"$G"; then p PASS "guard: $1"; else p FAIL "guard: $1"; fi; }
chkg "rejects root disk"               'dev" = "\$ROOTDISK"'
chkg "rejects log/recovery disk"       'dev" = "\$LOGDISK"'
chkg "rejects root source prefix"      'ROOTSRC" == "\$dev"'
chkg "requires removable=0"            'removable'
chkg "requires type MMC"               '!= "MMC"'
chkg "requires host fe310000.mmc"      'EMMC_HOST'
chkg "rejects SD hosts regex"          'SD_HOSTS_RE'
chkg "capacity lower bound MIN_B"      '-ge \$MIN_B'
chkg "capacity upper bound MAX_B"      '-le \$MAX_B'
chkg "exactly one device on host"      'cnt" = 1'
grep -q '^EMMC_HOST="fe310000.mmc"' "$F" && p PASS "EMMC_HOST=fe310000.mmc" || p FAIL "EMMC_HOST"
grep -q 'MIN_B=\$((20\*1024\*\*3))' "$F" && grep -q 'MAX_B=\$((40\*1024\*\*3))' "$F" && p PASS "window 20..40 GiB" || p FAIL "window"
grep -q 'fe2b0000' "$F" && p PASS "SD controller fe2b0000 excluded" || p FAIL "SD host exclusion"
# no device chosen by literal name/order anywhere
if grep -nE '/dev/mmcblk[0-9]|mmcblk[0-9]p' "$F" | grep -v '^\s*#'; then p FAIL "hard-coded mmcblk node"; else p PASS "no hard-coded mmcblk node"; fi
# DEV may only be assigned from find_emmc/wait_emmc (host-path based)
bad=$(grep -nE '^\s*(DEV|DEV2)=' "$F" | grep -vE 'find_emmc|wait_emmc|DEV=\$DEV2'); [ -z "$bad" ] && p PASS "DEV only from host-path lookup" || p FAIL "DEV assigned elsewhere: $bad"
exit $fail
