#!/usr/bin/env bash
# Cemal.cloud ubuntu-server-debloat | end-to-end test on a disposable Ubuntu 24.04 VM
#
#   1. --dry-run changes no package
#   2. a real run keeps ssh, networking, DNS, sudo and apt healthy
#   3. a second run changes nothing
#   4. the generated restore.sh scripts bring every purged package back
#
# Runs as root on a throw-away CI machine. Do not run this on a real server.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

FAILS=0
pass() { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS + 1)); }
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

# ---------------------------------------------------------------- 1. dry run
group "dry run"
./ubuntu2404-debloat.sh --dry-run
endgroup
check "dry run changed no package" test "$(pkglist)" == "$BEFORE"
check "dry run wrote no backup" test ! -d /var/backups/cemalcloud-debloat

# ---------------------------------------------------------------- 2. real run
group "debloat -y"
./ubuntu2404-debloat.sh -y
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
echo "system state: $(systemctl is-system-running 2>/dev/null || true)"

# ---------------------------------------------------------------- 3. second run
group "debloat -y (second run)"
OUT2="$(./ubuntu2404-debloat.sh -y 2>&1)"; echo "$OUT2"
endgroup
check "second run purges nothing" grep -q 'packages to purge (0)' <<<"$OUT2"
check "second run changed no package" test "$(pkglist)" == "$AFTER"

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
if [[ $FAILS -gt 0 ]]; then echo "$FAILS check(s) failed"; exit 1; fi
echo "All end-to-end checks passed"
