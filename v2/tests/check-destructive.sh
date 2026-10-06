#!/bin/bash
# Static safety review of the V2 recovery script and unit.
#  - every destructive command must be preceded (within WINDOW lines) by its OWN
#    'gwr_guard "$DEV[2]" || result ABORTED_TARGET_SAFETY_CHECK' with no target reassignment in between
#  - the guard must encode every required check
#  - forbidden patterns (hard-coded nodes, global label/UUID lookups, raw register/GPIO access) are absent
# usage: check-destructive.sh gwr-recovery.sh gwr-recovery.service
set -u
F=$1; U=${2:-}; WINDOW=4; fail=0; EXPECT=7
p(){ echo "$1: $2"; [ "$1" = FAIL ] && fail=1; return 0; }
out=$(awk -v W=$WINDOW '
  /^gwr_guard\(\)/ {inguard=1} inguard && /^}/ {inguard=0; next} inguard {next}
  /^[[:space:]]*#/ {next}
  /gwr_guard "\$DEV2?" *\|\| *result ABORTED_TARGET_SAFETY_CHECK/ {last=NR; used=0}
  /(^|[ ;])DEV2?=/ || /(^|[ ;])reprobe([ ;]|$)/ {last=0}
  /(^|[^a-z_])(blkdiscard|wipefs) / || /of="\$DEV"/ || /sfdisk --relocate/ {
     ok = (last>0 && NR-last<=W && !used); used=1
     printf "%s line %d: %s\n", (ok?"PASS":"FAIL"), NR, substr($0,1,100)
  }' "$F")
echo "$out"
echo "$out" | grep -q '^FAIL' && fail=1
n=$(echo "$out" | grep -c '^PASS')
[ "$n" -eq $EXPECT ] && p PASS "$n destructive commands, each with its own preceding guard" || p FAIL "$n guarded destructive commands (expected exactly $EXPECT)"
# no destructive command outside the recognised forms
x=$(grep -nE '(mkfs|sgdisk|parted|mmc (erase|sanitize|write)|of=/dev/|> */dev/(mmcblk|sd))' "$F" | grep -v '^\s*[0-9]*:\s*#')
[ -z "$x" ] && p PASS "no other write/format commands" || p FAIL "unexpected write command: $x"

G=$(awk '/^gwr_guard\(\)/,/^}/' "$F")
chkg(){ if grep -qF -- "$2" <<<"$G"; then p PASS "guard: $1"; else p FAIL "guard: $1"; fi; }
chkg "node name ^mmcblkN$"              '^mmcblk[0-9]+$'
chkg "rejects root disk"                 '"$dev" = "$ROOTDISK"'
chkg "rejects RECOVERYLOG disk"          '"$dev" = "$LOGDISK"'
chkg "rejects root source prefix"        '"$ROOTSRC" == "$dev"*'
chkg "requires removable=0"              'removable'
chkg "requires type MMC"                 '!= "MMC"'
chkg "requires mmcblk major 179"         '179:*'
chkg "requires host fe310000.mmc"        '*/$EMMC_HOST/*'
chkg "rejects SD hosts"                  '$SD_HOSTS_RE'
chkg "capacity lower bound"              '-ge $MIN_B'
chkg "capacity upper bound"              '-le $MAX_B'
chkg "exactly one device on host"        '"$cnt" = 1'
chkg "nothing mounted on target"         '/proc/mounts'
grep -q '^EMMC_HOST="fe310000.mmc"' "$F" && p PASS "EMMC_HOST=fe310000.mmc" || p FAIL "EMMC_HOST"
grep -q '^SD_HOSTS_RE="fe2b0000\\.mmc|fe2c0000\\.mmc"' "$F" && p PASS "SD hosts fe2b0000/fe2c0000" || p FAIL "SD hosts regex"
grep -q 'MIN_B=\$((20\*1024\*\*3)); MAX_B=\$((40\*1024\*\*3))' "$F" && p PASS "window 20..40 GiB" || p FAIL "window"
if grep -nE '/dev/mmcblk[0-9]|mmcblk[0-9]+p[0-9]|/sys/class/mmc_host/mmc[0-9]|"mmc1"' "$F" | grep -vE '^\s*[0-9]+:\s*#'; then p FAIL "hard-coded mmc node/host"; else p PASS "no hard-coded mmcblkN / mmcN"; fi
bad=$(grep -nE '^\s*(DEV|DEV2)=' "$F" | grep -vE 'find_emmc|wait_emmc|DEV=\$DEV2'); [ -z "$bad" ] && p PASS "DEV only from host-path lookup" || p FAIL "DEV assigned elsewhere: $bad"
if grep -nE 'blkid +(-[a-z]+ +)*-[LU]|findfs|/dev/disk/by-(label|uuid)|(^|[^_A-Z0-9])(LABEL|UUID)=' "$F" | grep -vE '^\s*[0-9]+:\s*#'; then p FAIL "global label/UUID lookup present"; else p PASS "no global label/UUID lookups"; fi
if grep -nE 'devmem|/dev/mem|/sys/class/gpio/|io -[48]|busybox devmem' "$F"; then p FAIL "raw register/sysfs-gpio access"; else p PASS "no raw register or sysfs-gpio access"; fi
grep -q 'GWR_TEST_MODE:-0}" = 1 \] && \[ -z "${INVOCATION_ID:-}" \]' "$F" && p PASS "test mode impossible under systemd (INVOCATION_ID)" || p FAIL "test-mode gate"
grep -q 'sfdisk --relocate gpt-bak-std "$DEV"' "$F" && p PASS "GPT relocation uses the loop-proven command" || p FAIL "GPT relocation command"
awk '/READBACK_VERIFY/{r=NR} /sfdisk --relocate/{s=NR} END{exit !(r && s && r<s)}' "$F" && p PASS "read-back SHA256 happens BEFORE GPT relocation" || p FAIL "read-back/relocate order"
grep -q 'terminal.done' "$F" && grep -q "grep -qE '^RESULT=EMMC_RECOVERED' \"\$MNT/STATE/terminal.done\"" "$F" && p PASS "terminal success blocks re-runs" || p FAIL "terminal state"
grep -qE 'for i in \$\(seq 1 "\$REBIND_ATTEMPTS"\)' "$F" && grep -q 'SOAK_END=' "$F" && p PASS "pre-enumeration loops bounded" || p FAIL "bounded loops"
grep -nE 'while (true|:)|for \(\(;;\)\)' "$F" && p FAIL "unbounded loop construct" || p PASS "no unbounded loop constructs"
if [ -n "$U" ]; then
  grep -v '^[[:space:]]*#' "$U" | grep -q 'network-pre' && p FAIL "unit orders against network-pre" || p PASS "unit: no network-pre ordering"
  grep -qE '^(Requires|After|Wants|BindsTo)=.*network' "$U" && p FAIL "unit depends on network" || p PASS "unit: no network dependency"
  grep -q '^Type=exec' "$U" && p PASS "unit: Type=exec" || p FAIL "unit: Type"
  grep -qE '^(Environment|EnvironmentFile)=' "$U" && p FAIL "unit sets environment" || p PASS "unit: no environment (no test hooks)"
  grep -q '^ExecStart=/usr/local/sbin/gwr-recovery.sh$' "$U" && p PASS "unit: ExecStart" || p FAIL "unit: ExecStart"
fi
exit $fail
