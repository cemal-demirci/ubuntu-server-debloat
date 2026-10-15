#!/usr/bin/env bash
# Cemal.cloud ubuntu-server-debloat | end-to-end test on a disposable Ubuntu 24.04 VM
#
#   0. --audit changes nothing and prints a score
#   1. --dry-run changes no package and prints the expected savings
#   2. a real run keeps ssh, networking, DNS, sudo and apt healthy and
#      writes a report.json with measured before / after numbers
#   3. a second run changes nothing, the audit score did not get worse
#   4. the generated restore.sh scripts bring every purged package back
#
# Runs as root on a throw-away CI machine. Do not run this on a real server.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

FAILS=0; PASSES=0
pass() { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASSES=$((PASSES + 1)); }
fail() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS + 1)); [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=e2e::$*"; return 0; }
check() { local msg="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$msg"; else fail "$msg"; fi; }
group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }
installed() { [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" == ii* ]]; }
pkglist() { dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' | awk '$1 == "ii" {print $2}' | sort; }

[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
. /etc/os-release; echo "OS: $PRETTY_NAME, kernel $(uname -r)"

BEFORE="$(pkglist)"
echo "installed packages before: $(grep -c . <<<"$BEFORE")"
MUST=()
for p in openssh-server openssh-client sudo apt netplan.io systemd-resolved unattended-upgrades; do
  installed "$p" && MUST+=( "$p" )
done
SSH_ACTIVE=0; systemctl is-active --quiet ssh && SSH_ACTIVE=1

warns() { grep -c 'WARN' <<<"$1" || true; }

# ---------------------------------------------------------------- 0. audit
group "audit (before)"
AUD1="$(./ubuntu2404-debloat.sh --audit 2>&1)"; echo "$AUD1"
endgroup
check "audit changed no package" test "$(pkglist)" == "$BEFORE"
check "audit wrote no backup" test ! -d /var/backups/cemalcloud-debloat
check "audit prints a score" grep -q 'Score:' <<<"$AUD1"
check "audit lists what is reachable from the network" grep -qE 'INFO +(reachable from the network|nothing listens)' <<<"$AUD1"
W1="$(warns "$AUD1")"; echo "audit warnings before: $W1"

# ---------------------------------------------------------------- 1. dry run
group "dry run"
DRY="$(./ubuntu2404-debloat.sh --dry-run 2>&1)"; echo "$DRY"
endgroup
check "dry run changed no package" test "$(pkglist)" == "$BEFORE"
check "dry run wrote no backup" test ! -d /var/backups/cemalcloud-debloat
check "dry run shows expected savings" grep -q 'installed size' <<<"$DRY"

# ---------------------------------------------------------------- 2. real run
group "debloat -y"
OUT1="$(./ubuntu2404-debloat.sh -y 2>&1)"; echo "$OUT1"
endgroup
AFTER="$(pkglist)"
echo "installed packages after: $(grep -c . <<<"$AFTER")"
for p in "${MUST[@]}"; do check "$p still installed" installed "$p"; done
check "apt-get check is clean" apt-get check
check "DNS resolves (systemd-resolved)" getent hosts github.com
check "HTTPS works" curl -fsS -o /dev/null https://github.com
check "sudo works" sudo -n true
[[ $SSH_ACTIVE -eq 1 ]] && check "ssh service still active" systemctl is-active --quiet ssh
check "autoremove has nothing left that is protected" bash -c '! apt-get -s autoremove | grep -E "^Remv (openssh|sudo|netplan|systemd-resolved|linux-image)"'
check "journald limit installed" test -f /etc/systemd/journald.conf.d/90-cemalcloud.conf
RUNS=( /var/backups/cemalcloud-debloat/*/ )
check "backup + restore.sh written" test -x "${RUNS[0]}restore.sh"
REPORT="${RUNS[0]}report.json"
check "report.json written and valid" jq -e . "$REPORT"
check "summary shows measured impact" grep -q 'Measured impact' <<<"$OUT1"
r() { jq -r "$1" "$REPORT" 2>/dev/null || echo 0; }
P_B="$(r .packages.before)"; P_A="$(r .packages.after)"
D_B="$(r .disk_used_bytes.before)"; D_A="$(r .disk_used_bytes.after)"
S_B="$(r .running_services.before)"; S_A="$(r .running_services.after)"
L_B="$(r .listening_sockets.before)"; L_A="$(r .listening_sockets.after)"
N_B="$(r .snap_mounts.before)"; N_A="$(r .snap_mounts.after)"
echo "report: packages $P_B -> $P_A, disk $D_B -> $D_A, services $S_B -> $S_A, sockets $L_B -> $L_A, snap mounts $N_B -> $N_A"
check "report: package count matches dpkg" test "$P_A" -eq "$(grep -c . <<<"$AFTER")"
check "report: fewer packages" test "$P_A" -lt "$P_B"
check "report: less disk used" test "$D_A" -lt "$D_B"
check "report: not more running services" test "$S_A" -le "$S_B"
installed snapd || check "report: no snap loop mounts left" test "$N_A" -eq 0
SAVED_MB=$(( (D_B - D_A) / 1048576 ))
echo "system state: $(systemctl is-system-running 2>/dev/null || true)"

# ---------------------------------------------------------------- 3. second run
group "debloat -y (second run)"
OUT2="$(./ubuntu2404-debloat.sh -y 2>&1)"; echo "$OUT2"
endgroup
check "second run purges nothing" grep -q 'packages to purge (0)' <<<"$OUT2"
check "second run changed no package" test "$(pkglist)" == "$AFTER"

group "audit (after)"
AUD2="$(./ubuntu2404-debloat.sh --audit 2>&1)"; echo "$AUD2"
endgroup
W2="$(warns "$AUD2")"; echo "audit warnings after: $W2"
check "audit after debloat: fewer warnings ($W1 -> $W2)" test "$W2" -lt "$W1"
check "audit after debloat: no snapd, no telemetry" bash -c '! grep -qE "WARN.*(snapd installed|telemetry)" <<<"$1"' _ "$AUD2"

# ---------------------------------------------------------------- 4. restore
PURGED="$(grep -h '^apt-get install -y' /var/backups/cemalcloud-debloat/*/restore.sh | sed 's/^apt-get install -y -o DPkg::Lock::Timeout=300 //' | tr ' ' '\n' | sort -u | grep . || true)"
echo "purged by the first run: $(xargs <<<"$PURGED")"
group "restore (newest run first)"
for d in $(ls -d /var/backups/cemalcloud-debloat/*/ | sort -r); do "${d}restore.sh"; done
endgroup
while read -r p; do
  [[ -z "$p" ]] && continue
  check "restored $p" installed "$p"
done <<<"$PURGED"
check "snapd pin removed" test ! -f /etc/apt/preferences.d/cemalcloud-nosnap.pref
check "journald limit removed" test ! -f /etc/systemd/journald.conf.d/90-cemalcloud.conf
check "apt-get check is clean after restore" apt-get check

echo
if [[ $FAILS -gt 0 ]]; then echo "$FAILS check(s) failed, $PASSES passed"; exit 1; fi
echo "All end-to-end checks passed"
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "::notice title=Ubuntu end-to-end::$PASSES checks passed on $PRETTY_NAME (kernel $(uname -r)). Packages $P_B -> $P_A, disk freed ${SAVED_MB} MB, running services $S_B -> $S_A, listening sockets $L_B -> $L_A, snap mounts $N_B -> $N_A. Audit warnings $W1 -> $W2. Purged and restored: $(xargs <<<"$PURGED"). SSH, sudo, DNS, HTTPS and apt stayed healthy; second run changed nothing."
fi
