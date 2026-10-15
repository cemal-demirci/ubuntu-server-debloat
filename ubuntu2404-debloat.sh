#!/usr/bin/env bash
# =============================================================================
#  Ubuntu Server 24.04 LTS debloat  |  https://cemal.cloud  |  GPL-3.0-or-later
#  Source: https://github.com/cemal-demirci/ubuntu-server-debloat
#
#  Removes : snapd (+ blocks reinstall), apport/whoopsie/popcon telemetry,
#            MOTD/apt ads, landscape sysinfo, pollinate, ModemManager,
#            udisks2, packagekit, plymouth, fwupd, lxd-installer, sosreport,
#            cloud-init / multipath / open-iscsi (only when not in use)
#  Tunes   : journald size cap, no apt Recommends, quiet needrestart
#  Keeps   : openssh, netplan, systemd-resolved, unattended-upgrades
#            (security updates), ubuntu-pro-client (ads silenced), kernel
#
#  Safety  : simulates every apt removal first and aborts if a protected
#            package (ssh, sudo, kernel, netplan, ...) would be removed.
#            Writes a backup + a ready-to-run restore.sh for each run.
#  Measures: packages, disk, running services, listening sockets, snap
#            mounts and memory before and after; saved as report.json.
#  Audit   : --audit scores bloat and basic security without changing anything.
#
#  Usage:
#    sudo ./ubuntu2404-debloat.sh --audit        # score the server, change nothing
#    sudo ./ubuntu2404-debloat.sh --dry-run      # show the plan and expected savings
#    sudo ./ubuntu2404-debloat.sh                # interactive confirm
#    sudo ./ubuntu2404-debloat.sh -y             # unattended
#
#  Options:
#        --audit            read-only bloat + security score, change nothing
#    -n, --dry-run          show what would change, change nothing
#    -y, --yes              do not ask for confirmation
#        --keep-snap        keep snapd
#        --keep-cloud-init  keep cloud-init even if it looks unused
#        --remove-cloud-init  remove cloud-init even on a detected cloud
#        --keep-fwupd       keep fwupd (firmware updates on bare metal)
#        --keep-recommends  do not disable apt Recommends
#        --remove-pro       also purge ubuntu-pro-client (no ESM/Livepatch)
#        --force            skip OS version and installed-snap checks
#    -h, --help             show this help
# =============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

VERSION="1.1.0"
AUDIT=0; DRY_RUN=0; ASSUME_YES=0; KEEP_SNAP=0; KEEP_CLOUD=0; FORCE_CLOUD=0
KEEP_FWUPD=0; KEEP_RECOMMENDS=0; REMOVE_PRO=0; FORCE=0

c_b='\033[1;34m'; c_g='\033[1;32m'; c_y='\033[1;33m'; c_r='\033[1;31m'; c_0='\033[0m'
step() { printf "\n${c_b}==>${c_0} %s\n" "$*"; }
info() { printf "    %s\n" "$*"; }
ok()   { printf "    ${c_g}+${c_0} %s\n" "$*"; }
warn() { printf "    ${c_y}!${c_0} %s\n" "$*" >&2; }
die()  { printf "${c_r}ERROR:${c_0} %s\n" "$*" >&2; exit 1; }
dry()  { printf "    ${c_y}[dry]${c_0} %s\n" "$*"; }
usage() { sed -n '/^#  Usage:/,/^# =====/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --audit)             AUDIT=1 ;;
    -n|--dry-run)        DRY_RUN=1 ;;
    -y|--yes)            ASSUME_YES=1 ;;
    --keep-snap)         KEEP_SNAP=1 ;;
    --keep-cloud-init)   KEEP_CLOUD=1 ;;
    --remove-cloud-init) FORCE_CLOUD=1 ;;
    --keep-fwupd)        KEEP_FWUPD=1 ;;
    --keep-recommends)   KEEP_RECOMMENDS=1 ;;
    --remove-pro)        REMOVE_PRO=1 ;;
    --force)             FORCE=1 ;;
    -h|--help)           usage ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "run as root (sudo)"
[[ $KEEP_CLOUD -eq 1 && $FORCE_CLOUD -eq 1 ]] && die "--keep-cloud-init and --remove-cloud-init conflict"

MODE_LABEL=""; [[ $DRY_RUN -eq 1 ]] && MODE_LABEL="  (DRY RUN)"; [[ $AUDIT -eq 1 ]] && MODE_LABEL="  (AUDIT, read-only)"
printf "${c_b}Cemal.cloud${c_0} | Ubuntu 24.04 debloat v%s%s\n" "$VERSION" "$MODE_LABEL"

# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
  [[ $FORCE -eq 1 ]] || die "built for Ubuntu 24.04, found ${PRETTY_NAME:-unknown}. Use --force to continue anyway."
  warn "not Ubuntu 24.04 (${PRETTY_NAME:-unknown}), continuing because of --force"
fi

[[ -r /proc/self/status && -e /dev/fd/0 ]] || die "/proc or /dev/fd is not available. Run this on a booted system, not a bare chroot."

is_installed() { [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" == ii* ]]; }
in_list() { local x="$1" i; shift; for i in "$@"; do [[ "$i" == "$x" ]] && return 0; done; return 1; }
has_systemd()  { [[ -d /run/systemd/system ]]; }

# ----------------------------------------------------------------------------
# Measurements (before / after)
# ----------------------------------------------------------------------------
m_pkgs()       { dpkg-query -W -f='${db:Status-Abbrev}\n' 2>/dev/null | grep -c '^ii' || true; }
m_disk()       { df -B1 --output=used / 2>/dev/null | tail -n1 | tr -dc '0-9'; }
m_services()   { if has_systemd; then systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | grep -c . || true; else echo 0; fi; }
m_listen()     { if command -v ss >/dev/null; then ss -H -tuln 2>/dev/null | grep -c . || true; else echo 0; fi; }
m_snapmounts() { findmnt -rn -t squashfs -o TARGET 2>/dev/null | grep -c '^/snap/' || true; }
m_mem()        { awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "%d", (t - a) * 1024}' /proc/meminfo; }
declare -A M=()
measure() {  # $1 = before|after
  M[$1_pkgs]="$(m_pkgs)";         M[$1_disk]="$(m_disk)"
  M[$1_services]="$(m_services)"; M[$1_listen]="$(m_listen)"
  M[$1_snaps]="$(m_snapmounts)";  M[$1_mem]="$(m_mem)"
}
# human readable bytes, keeps the sign
hb() { awk -v b="$1" 'BEGIN { s = (b < 0) ? "-" : ""; if (b < 0) b = -b; split("B KB MB GB TB", u, " "); i = 1
       while (b >= 1024 && i < 5) { b /= 1024; i++ }
       printf (i == 1 ? "%s%d %s" : "%s%.1f %s"), s, b, u[i] }'; }
row() {  # label before after kind(count|bytes)
  local label="$1" b="$2" a="$3" kind="$4" d=$(( $3 - $2 ))
  if [[ "$kind" == bytes ]]; then
    printf "    %-22s %10s -> %-10s (%s)\n" "$label" "$(hb "$b")" "$(hb "$a")" "$(hb "$d")"
  else
    printf "    %-22s %10s -> %-10s (%+d)\n" "$label" "$b" "$a" "$d"
  fi
}

# ----------------------------------------------------------------------------
# Audit (read-only)
# ----------------------------------------------------------------------------
A_OK=0; A_WARN=0
a_ok()   { printf "    ${c_g}OK  ${c_0}  %s\n" "$*"; A_OK=$((A_OK + 1)); }
a_warn() { printf "    ${c_y}WARN${c_0}  %s\n" "$*"; A_WARN=$((A_WARN + 1)); }
a_info() { printf "    INFO  %s\n" "$*"; }

run_audit() {
  local p list running cid sshcfg prl pwa exposed
  step "Bloat"
  if is_installed snapd; then
    a_warn "snapd installed ($(snap list 2>/dev/null | awk 'NR > 1' | grep -c . || true) snaps, $(m_snapmounts) loop mounts)"
  else a_ok "no snapd"; fi

  list=""
  for p in apport whoopsie popularity-contest ubuntu-report; do is_installed "$p" && list+=" $p"; done
  if [[ -n "$list" ]]; then a_warn "telemetry / crash reporting installed:$list"; else a_ok "no telemetry packages"; fi

  if grep -qs '^ENABLED=1' /etc/default/motd-news || { has_systemd && systemctl is-enabled --quiet motd-news.timer 2>/dev/null; }; then
    a_warn "login message fetches ads (motd-news)"
  else a_ok "login message ads off"; fi

  running=""
  if has_systemd; then
    # SubState=running: a removed oneshot unit can stay "active (exited)" until reboot
    for p in ModemManager udisks2 fwupd snapd; do
      [[ "$(systemctl show -p SubState --value "$p" 2>/dev/null)" == running ]] && running+=" $p"
    done
  fi
  if [[ -n "$running" ]]; then a_warn "desktop-era services running:$running"; else a_ok "no desktop-era services running"; fi

  if is_installed cloud-init; then
    cid="$(cloud-id 2>/dev/null | head -n1 || true)"; cid="${cid:-unknown}"
    if [[ "$cid" =~ ^(none|nocloud|unknown|disabled|not\ started|not\ running)$ ]]; then
      a_warn "cloud-init installed but no cloud datasource ($cid)"
    else a_ok "cloud-init in use ($cid)"; fi
  fi

  local jbytes
  jbytes="$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[BKMGT]' | head -n1 || true)"
  if [[ "$jbytes" =~ G$ ]] && awk -v v="${jbytes%G}" 'BEGIN { exit !(v > 1) }'; then
    a_warn "journal uses $jbytes (no size cap)"
  elif [[ -n "$jbytes" ]]; then a_ok "journal size $jbytes"; fi

  step "Security"
  if is_installed unattended-upgrades && apt-config dump 2>/dev/null | grep -q 'APT::Periodic::Unattended-Upgrade "1"'; then
    a_ok "automatic security updates on"
  else a_warn "automatic security updates off"; fi

  if [[ -f /var/run/reboot-required ]]; then a_warn "reboot required (pending kernel or library update)"
  else a_ok "no reboot pending"; fi

  if command -v sshd >/dev/null && sshcfg="$(sshd -T 2>/dev/null)"; then
    prl="$(awk '$1 == "permitrootlogin" {print $2}' <<<"$sshcfg")"
    pwa="$(awk '$1 == "passwordauthentication" {print $2}' <<<"$sshcfg")"
    if [[ "$prl" == yes ]]; then a_warn "SSH allows root login with a password (PermitRootLogin yes)"
    else a_ok "SSH root login: ${prl:-unknown}"; fi
    if [[ "$pwa" == yes ]]; then a_warn "SSH accepts passwords (PasswordAuthentication yes); keys only is safer"
    else a_ok "SSH password logins off"; fi
  fi

  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    a_ok "firewall: ufw active"
  elif command -v nft >/dev/null && nft list ruleset 2>/dev/null | grep -q 'hook input'; then
    a_ok "firewall: nftables input rules present"
  else
    a_warn "no host firewall rules on input (ufw inactive, no nftables input chain)"
  fi

  if command -v ss >/dev/null; then
    exposed="$(ss -H -tulpn 2>/dev/null | awk '
      { local = $5; proc = $7
        if (local ~ /^(127\.|\[::1\]|::1)/ || local ~ /%lo:/) next
        n = split(local, a, ":"); port = a[n]
        name = proc; sub(/^users:\(\("/, "", name); sub(/".*/, "", name); if (name == "") name = "?"
        print $1 "/" port " " name }' | sort -u | xargs)"
    if [[ -n "$exposed" ]]; then a_info "reachable from the network: $exposed"; else a_info "nothing listens on the network"; fi
  fi

  echo
  printf "    ${c_b}Score:${c_0} %d of %d checks OK" "$A_OK" "$((A_OK + A_WARN))"
  [[ $A_WARN -gt 0 ]] && printf ", %d to look at" "$A_WARN"
  printf "\n    Nothing was changed. Run with --dry-run to see what the debloat would do.\n"
}

# Packages that must never be removed as a side effect.
PROTECTED=( openssh-server openssh-client sudo apt dpkg systemd systemd-sysv systemd-resolved
  netplan.io ubuntu-keyring ca-certificates iproute2 login passwd util-linux mount bash coreutils
  systemd-timesyncd udev dbus kmod initramfs-tools cryptsetup-initramfs
  lvm2 cryptsetup mdadm grub-pc grub-efi-amd64 grub-efi-amd64-signed grub-efi-arm64 shim-signed
  unattended-upgrades software-properties-common linux-generic linux-virtual linux-image-generic linux-image-virtual
  linux-kvm linux-aws linux-azure linux-gcp linux-oracle "linux-image-$(uname -r)" )

# Admin tools that are often installed only as a dependency of something this
# script removes (jq <- fwupd, bc <- landscape-common, eject <- udisks2).
# Marked manual before purging so autoremove keeps them.
KEEP_TOOLS=( jq bc eject curl wget less nano vim-tiny rsync tmux htop git
  python3 python3-yaml secureboot-db )

# $1 = output of "apt-get -s ...". Prints protected packages it would remove.
# Fails closed: returns 2 if $1 is not a complete apt simulation, so a broken
# apt run can never be mistaken for "nothing protected is affected".
check_sim() {
  local out="$1" list pkg bad=()
  grep -qE '^[0-9]+ upgraded, [0-9]+ newly installed, [0-9]+ to remove' <<<"$out" || return 2
  list="$(awk '/^(Remv|Purg) / {print $2}' <<<"$out")"
  while read -r pkg; do
    [[ -n "$pkg" ]] && in_list "$pkg" "${PROTECTED[@]}" && bad+=( "$pkg" )
  done <<<"$list"
  if [[ ${#bad[@]} -gt 0 ]]; then printf '%s\n' "${bad[@]}"; fi
  return 0
}

if [[ $AUDIT -eq 1 ]]; then
  run_audit
  exit 0
fi

# ----------------------------------------------------------------------------
# 1. Build the removal plan
# ----------------------------------------------------------------------------
step "Building plan"

CANDIDATES=(
  # telemetry / crash reporting
  apport apport-symptoms apport-core-dump-handler python3-apport whoopsie
  popularity-contest ubuntu-report
  # MOTD / phone-home
  landscape-common update-notifier-common pollinate
  # desktop-ish daemons that a server does not need
  modemmanager udisks2 packagekit packagekit-tools plymouth plymouth-theme-ubuntu-text
  bolt kerneloops lxd-installer lxd-agent-loader sosreport
)
[[ $KEEP_FWUPD -eq 0 ]] && CANDIDATES+=( fwupd fwupd-signed )
[[ $REMOVE_PRO -eq 1 ]] && CANDIDATES+=( ubuntu-pro-client ubuntu-pro-client-l10n ubuntu-advantage-tools )

# packagekit is used by Cockpit; keep it there
if is_installed cockpit-packagekit; then
  info "cockpit-packagekit present, keeping packagekit"
  _tmp=(); for p in "${CANDIDATES[@]}"; do [[ "$p" == packagekit* ]] || _tmp+=( "$p" ); done
  CANDIDATES=( "${_tmp[@]}" )
fi

# --- cloud-init: remove only when the machine is not using a real cloud datasource
if is_installed cloud-init; then
  cid="$(cloud-id 2>/dev/null | head -n1 || true)"; cid="${cid:-unknown}"
  if [[ $KEEP_CLOUD -eq 1 ]]; then
    info "cloud-init kept (--keep-cloud-init)"
  elif [[ $FORCE_CLOUD -eq 1 || "$cid" =~ ^(none|nocloud|unknown|disabled|not\ started|not\ running)$ || -e /etc/cloud/cloud-init.disabled ]]; then
    info "cloud-init datasource: $cid -> will be removed (network config in /etc/netplan stays)"
    CANDIDATES+=( cloud-init )
  else
    info "cloud-init datasource: $cid -> kept (use --remove-cloud-init to override)"
  fi
fi

# --- multipath: only if no multipath maps exist
if is_installed multipath-tools; then
  if command -v multipath >/dev/null && [[ -n "$(multipath -l 2>/dev/null || true)" ]]; then
    info "multipath maps in use -> multipath-tools kept"
  else
    CANDIDATES+=( multipath-tools )
  fi
fi

# --- open-iscsi: only if no active sessions
if is_installed open-iscsi; then
  if iscsiadm -m session >/dev/null 2>&1; then
    info "active iSCSI sessions -> open-iscsi kept"
  else
    CANDIDATES+=( open-iscsi )
  fi
fi

# --- snapd
SNAP_REMOVE=0
if [[ $KEEP_SNAP -eq 0 ]] && is_installed snapd; then
  user_snaps=""
  if command -v snap >/dev/null && has_systemd; then
    user_snaps="$(snap list 2>/dev/null | awk 'NR>1 && $1 !~ /^(core[0-9]*|snapd|bare|lxd)$/ {print $1}' | xargs || true)"
  fi
  if [[ -n "$user_snaps" && $FORCE -eq 0 ]]; then
    warn "snaps in use: $user_snaps -> snapd kept (use --force to remove them too)"
  else
    SNAP_REMOVE=1
    CANDIDATES+=( snapd )
  fi
fi

REMOVE=(); EXTRA=()
for p in "${CANDIDATES[@]}"; do
  [[ -n "$p" ]] && is_installed "$p" && REMOVE+=( "$p" )
done

# Drop any candidate whose removal would drag a protected package with it
# (e.g. packagekit -> software-properties-common on stock 24.04).
SAFE=()
for p in "${REMOVE[@]}"; do
  sim_p="$(apt-get -s purge "$p" 2>&1 || true)"
  if ! off="$(check_sim "$sim_p")"; then
    info "keeping $p (apt could not simulate its removal)"
  elif [[ -n "$off" ]]; then
    info "keeping $p (removing it would also remove: $(echo "$off" | xargs))"
  else
    SAFE+=( "$p" )
  fi
done
REMOVE=( "${SAFE[@]}" )

info "packages to purge (${#REMOVE[@]}): ${REMOVE[*]:-none}"

# ----------------------------------------------------------------------------
# 2. Simulate and check against the protected list
# ----------------------------------------------------------------------------
# Removing a package can drag a metapackage (ubuntu-server, ubuntu-minimal)
# with it. That is fine, but then its other dependencies become "auto" and
# apt autoremove would take them too. Pin them as manual first.
META_DEPS=()
for meta in ubuntu-server ubuntu-server-minimal ubuntu-minimal ubuntu-standard ubuntu-cloud-minimal; do
  is_installed "$meta" || continue
  deps="$(apt-cache depends --installed --no-pre-depends --no-suggests --no-conflicts \
            --no-breaks --no-replaces --no-enhances "$meta" 2>/dev/null \
          | awk '$1 ~ /^(Depends|Recommends):$/ && $2 !~ /^</ {print $2}' | sort -u || true)"
  while read -r dep; do
    [[ -z "$dep" ]] && continue
    if [[ ${#REMOVE[@]} -gt 0 ]] && in_list "$dep" "${REMOVE[@]}"; then continue; fi
    is_installed "$dep" && META_DEPS+=( "$dep" )
  done <<<"$deps"
done


if [[ ${#REMOVE[@]} -gt 0 ]]; then
  sim="$(apt-get -s purge "${REMOVE[@]}" 2>&1)" || die "apt simulation failed: $sim"
  offending="$(check_sim "$sim")" || die "could not parse the apt simulation. Aborting, nothing changed."
  [[ -z "$offending" ]] || die "plan would remove protected packages: $offending. Aborting, nothing changed."
  while read -r pkg; do
    [[ -n "$pkg" ]] && ! in_list "$pkg" "${REMOVE[@]}" && EXTRA+=( "$pkg" )
  done <<<"$(awk '/^Purg / {print $2}' <<<"$sim")"
  [[ ${#EXTRA[@]} -gt 0 ]] && info "also removed as dependents: ${EXTRA[*]}"
fi
ok "simulation passed, no protected package affected"

# ----------------------------------------------------------------------------
# 3. Confirm
# ----------------------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/cemalcloud-debloat/$TS"

if [[ $DRY_RUN -eq 1 ]]; then
  step "Dry run summary"
  [[ ${#REMOVE[@]} -gt 0 ]] && dry "apt-get purge ${REMOVE[*]}"
  [[ $SNAP_REMOVE -eq 1 ]] && dry "remove all snaps, purge snapd, pin snapd to never install"
  dry "silence MOTD ads (motd-news, esm, help-text), apt news"
  dry "journald cap 500M, needrestart list-only$([[ $KEEP_RECOMMENDS -eq 0 ]] && echo ', apt Recommends off')"
  dry "pin ${#META_DEPS[@]} metapackage deps + installed admin tools (${KEEP_TOOLS[*]}) as manual"
  dry "backup + restore.sh -> $BACKUP"
  est=0
  if [[ ${#REMOVE[@]} -gt 0 ]]; then
    est="$(dpkg-query -W -f='${Installed-Size}\n' "${REMOVE[@]}" "${EXTRA[@]}" 2>/dev/null | awk '{s += $1} END {printf "%d", s * 1024}' || true)"
  fi
  snapb=0; [[ $SNAP_REMOVE -eq 1 ]] && snapb="$(du -sb /var/lib/snapd/snaps 2>/dev/null | awk '{print $1}' || true)"
  step "Expected savings"
  info "packages to purge     : ${#REMOVE[@]} (+${#EXTRA[@]} dependents), about $(hb "$est") installed size"
  [[ $SNAP_REMOVE -eq 1 ]] && info "snap images           : $(hb "${snapb:-0}"), $(m_snapmounts) loop mounts"
  info "measured for real (disk, services, sockets, memory) when you run it without --dry-run"
  exit 0
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  [[ -t 0 ]] || die "no terminal for confirmation, re-run with -y"
  read -r -p "    Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { info "aborted"; exit 0; }
fi

mkdir -p "$BACKUP"
exec > >(tee -a "$BACKUP/debloat.log") 2>&1

# ----------------------------------------------------------------------------
# 4. Backup + restore script skeleton
# ----------------------------------------------------------------------------
step "Backup -> $BACKUP"
dpkg --get-selections > "$BACKUP/dpkg-selections.txt"
apt-mark showmanual   > "$BACKUP/apt-manual.txt"
cp -a /etc/update-motd.d "$BACKUP/update-motd.d" 2>/dev/null || true
[[ $SNAP_REMOVE -eq 1 ]] && command -v snap >/dev/null && snap list > "$BACKUP/snap-list.txt" 2>/dev/null || true

RESTORE="$BACKUP/restore.sh"
R_CFG=()   # config reversals, run first
R_PKGS=()  # packages to reinstall, run last
write_restore() {
  {
    echo '#!/usr/bin/env bash'
    echo "# Cemal.cloud | restore for debloat run $TS"
    echo 'set -uo pipefail'
    echo '[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }'
    printf '%s\n' "${R_CFG[@]}"
    if [[ ${#R_PKGS[@]} -gt 0 ]]; then
      echo 'apt-get -o DPkg::Lock::Timeout=300 update'
      echo "apt-get install -y -o DPkg::Lock::Timeout=300 ${R_PKGS[*]}"
    fi
    [[ -s "$BACKUP/snap-list.txt" ]] && echo "echo 'Snaps that were removed: see $BACKUP/snap-list.txt'"
    echo 'echo "restore finished, reboot recommended"'
  } > "$RESTORE"
  chmod +x "$RESTORE"
}
trap write_restore EXIT
ok "backup written"
measure before

# ----------------------------------------------------------------------------
# 5. Snaps
# ----------------------------------------------------------------------------
if [[ $SNAP_REMOVE -eq 1 ]]; then
  step "Removing snaps"
  if command -v snap >/dev/null && has_systemd; then
    # apps first, then bases, snapd last
    for pass in 1 2 3; do
      snaps=()
      while read -r s; do [[ -n "$s" ]] && snaps+=( "$s" ); done <<<"$(snap list 2>/dev/null | awk 'NR>1 {print $1}' || true)"
      [[ ${#snaps[@]} -eq 0 ]] && break
      for s in "${snaps[@]}"; do
        if [[ $pass -lt 3 && "$s" =~ ^(core[0-9]*|snapd|bare)$ ]]; then continue; fi
        snap remove --purge "$s" >/dev/null 2>&1 && ok "snap $s removed" || true
      done
    done
  fi
  has_systemd && systemctl disable --now snapd.socket snapd.service snapd.seeded.service >/dev/null 2>&1 || true
fi

# ----------------------------------------------------------------------------
# 6. Purge packages
# ----------------------------------------------------------------------------
if [[ ${#REMOVE[@]} -gt 0 ]]; then
  step "Purging packages"
  # Keep metapackage deps and protected packages out of autoremove's reach.
  HOLD_MANUAL=()
  for p in "${PROTECTED[@]}" "${KEEP_TOOLS[@]}"; do is_installed "$p" && HOLD_MANUAL+=( "$p" ); done
  apt-mark manual "${META_DEPS[@]}" "${HOLD_MANUAL[@]}" >/dev/null
  apt-get -o DPkg::Lock::Timeout=300 purge -y -q "${REMOVE[@]}"
  R_PKGS+=( "${REMOVE[@]}" "${EXTRA[@]}" )
  ok "purged: ${REMOVE[*]}"

  # autoremove only if it does not touch anything protected
  sim="$(apt-get -s autoremove --purge 2>&1 || true)"
  if offending="$(check_sim "$sim")" && [[ -z "$offending" ]]; then
    apt-get -o DPkg::Lock::Timeout=300 autoremove --purge -y -q
    ok "orphaned dependencies removed"
  else
    warn "autoremove skipped (would remove: ${offending:-unverifiable plan})"
  fi
fi

if [[ $SNAP_REMOVE -eq 1 ]]; then
  rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /root/snap
  for home in /home/*; do [[ -d "$home/snap" ]] && rm -rf "${home:?}/snap"; done
  cat > /etc/apt/preferences.d/cemalcloud-nosnap.pref <<'EOF'
# Cemal.cloud debloat: never install snapd
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
  R_CFG+=( 'rm -f /etc/apt/preferences.d/cemalcloud-nosnap.pref' )
  ok "snapd blocked via apt pin"
fi

# ----------------------------------------------------------------------------
# 7. MOTD and apt ads
# ----------------------------------------------------------------------------
step "Silencing MOTD and apt advertising"
if [[ -f /etc/default/motd-news ]]; then
  sed -i 's/^ENABLED=1/ENABLED=0/' /etc/default/motd-news
  R_CFG+=( "sed -i 's/^ENABLED=0/ENABLED=1/' /etc/default/motd-news" )
fi
if has_systemd; then
  systemctl disable --now motd-news.timer >/dev/null 2>&1 && R_CFG+=( 'systemctl enable --now motd-news.timer || true' ) || true
fi
for f in 10-help-text 50-motd-news 88-esm-announce 91-contract-ua-esm-status 91-release-upgrade 95-hwe-eol; do
  if [[ -x "/etc/update-motd.d/$f" ]]; then
    chmod -x "/etc/update-motd.d/$f"
    R_CFG+=( "chmod +x /etc/update-motd.d/$f" )
    info "motd: $f off"
  fi
done
if command -v pro >/dev/null; then
  pro config set apt_news=false >/dev/null 2>&1 && R_CFG+=( 'pro config set apt_news=true || true' ) || true
fi
# ESM "you could get more updates" lines in apt output
if [[ -f /etc/apt/apt.conf.d/20apt-esm-hook.conf ]]; then
  dpkg-divert --quiet --local --rename --divert /etc/apt/apt.conf.d/20apt-esm-hook.conf.disabled \
    --add /etc/apt/apt.conf.d/20apt-esm-hook.conf
  R_CFG+=( 'dpkg-divert --quiet --local --rename --remove /etc/apt/apt.conf.d/20apt-esm-hook.conf' )
fi
ok "ads silenced"

# ----------------------------------------------------------------------------
# 8. System tuning
# ----------------------------------------------------------------------------
step "System tuning"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/90-cemalcloud.conf <<'EOF'
# Cemal.cloud debloat: keep the journal small
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=1month
EOF
R_CFG+=( 'rm -f /etc/systemd/journald.conf.d/90-cemalcloud.conf' )
has_systemd && systemctl restart systemd-journald >/dev/null 2>&1 || true
ok "journald capped at 500M"

if [[ $KEEP_RECOMMENDS -eq 0 ]]; then
  cat > /etc/apt/apt.conf.d/99-cemalcloud-norecommends <<'EOF'
// Cemal.cloud debloat: do not pull in recommended/suggested packages
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF
  R_CFG+=( 'rm -f /etc/apt/apt.conf.d/99-cemalcloud-norecommends' )
  ok "apt Recommends/Suggests off"
fi

if [[ -d /etc/needrestart ]]; then
  mkdir -p /etc/needrestart/conf.d
  # list affected services instead of the interactive dialog on every apt run
  echo "\$nrconf{restart} = 'l';" > /etc/needrestart/conf.d/90-cemalcloud.conf
  R_CFG+=( 'rm -f /etc/needrestart/conf.d/90-cemalcloud.conf' )
  ok "needrestart: list only, no prompts"
fi

apt-get clean
has_systemd && systemctl daemon-reload >/dev/null 2>&1 || true
sleep 3   # let stopped services settle before measuring
measure after

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
step "Measured impact (before -> after)"
row "installed packages" "${M[before_pkgs]}"     "${M[after_pkgs]}"     count
row "disk used"          "${M[before_disk]}"     "${M[after_disk]}"     bytes
row "running services"   "${M[before_services]}" "${M[after_services]}" count
row "listening sockets"  "${M[before_listen]}"   "${M[after_listen]}"   count
row "snap loop mounts"   "${M[before_snaps]}"    "${M[after_snaps]}"    count
row "memory in use"      "${M[before_mem]}"      "${M[after_mem]}"      bytes
info "(memory is a snapshot and moves on its own; the rest is exact)"
cat > "$BACKUP/report.json" <<EOF
{
  "version": "$VERSION",
  "time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "os": "${PRETTY_NAME:-unknown}",
  "removed": "${REMOVE[*]:-}",
  "packages":          { "before": ${M[before_pkgs]:-0}, "after": ${M[after_pkgs]:-0} },
  "disk_used_bytes":   { "before": ${M[before_disk]:-0}, "after": ${M[after_disk]:-0} },
  "running_services":  { "before": ${M[before_services]:-0}, "after": ${M[after_services]:-0} },
  "listening_sockets": { "before": ${M[before_listen]:-0}, "after": ${M[after_listen]:-0} },
  "snap_mounts":       { "before": ${M[before_snaps]:-0}, "after": ${M[after_snaps]:-0} },
  "memory_used_bytes": { "before": ${M[before_mem]:-0}, "after": ${M[after_mem]:-0} }
}
EOF

step "Done"
info "removed      : ${REMOVE[*]:-nothing}"
info "backup       : $BACKUP  (report.json has the numbers above)"
info "roll back    : sudo $RESTORE"
info "reboot recommended"
