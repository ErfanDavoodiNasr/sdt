#!/usr/bin/env bash
set -euo pipefail

readonly SDT_NAME="SDT - Server Dashboard Tool"
readonly LOCATION_API_URL="http://ip-api.com/json"
readonly COLOR_RESET='\033[0m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_RED='\033[31m'
readonly COLOR_GREEN='\033[32m'
readonly COLOR_CYAN='\033[36m'
readonly COLOR_YELLOW='\033[33m'
readonly ALERT_RAM_PCT="${SDT_ALERT_RAM_PCT:-85}"
readonly ALERT_DISK_PCT="${SDT_ALERT_DISK_PCT:-85}"
readonly ALERT_CPU_PCT="${SDT_ALERT_CPU_PCT:-85}"

log_info() { printf "%b[INFO]%b %s\n" "$COLOR_CYAN" "$COLOR_RESET" "$1"; }
log_ok() { printf "%b[OK]%b %s\n" "$COLOR_GREEN" "$COLOR_RESET" "$1"; }
log_warn() { printf "%b[WARN]%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "$1"; }
log_err() { printf "%b[ERROR]%b %s\n" "$COLOR_RED" "$COLOR_RESET" "$1" >&2; }

die() {
  log_err "$1"
  exit "${2:-1}"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run SDT as root."
}

ensure_cmd() {
  local cmd="$1" pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "$pkg" >/dev/null 2>&1 || die "Failed to install dependency package: $pkg"
  fi
}

ensure_deps() {
  dpkg -s ca-certificates >/dev/null 2>&1 || {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y ca-certificates >/dev/null 2>&1 || die "Failed to install dependency package: ca-certificates"
  }
  ensure_cmd curl curl
  ensure_cmd ping iputils-ping
}

run_step() {
  local msg="$1"
  shift
  log_info "$msg"
  "$@" || die "$msg failed."
}

wait_for_apt_lock() {
  local i
  for i in {1..180}; do
    if fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
      sleep 2
    else
      return 0
    fi
  done
  return 1
}

apt_maintenance() {
  export DEBIAN_FRONTEND=noninteractive
  wait_for_apt_lock || die "Timeout waiting for apt lock."
  run_step "Running apt update" apt update -y
  wait_for_apt_lock || die "Timeout waiting for apt lock."
  run_step "Running apt upgrade" apt upgrade -y
  log_ok "System packages are up to date."
}

get_os_name() {
  awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || echo "Unknown"
}

get_cpu_model() {
  awk -F: '/model name/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "Unknown"
}

get_cpu_cores() { nproc 2>/dev/null || echo "Unknown"; }
get_kernel() { uname -r 2>/dev/null || echo "Unknown"; }
get_uptime() { uptime -p 2>/dev/null || echo "Unknown"; }
get_ram_total() { free -h 2>/dev/null | awk '/^Mem:/{print $2}'; }
get_ram_used() { free -h 2>/dev/null | awk '/^Mem:/{print $3}'; }
get_ram_pct() { free 2>/dev/null | awk '/^Mem:/{ if ($2>0) printf "%d%%", ($3*100)/$2; else print "Unknown" }'; }
get_disk_total() { df -h / 2>/dev/null | awk 'NR==2{print $2}'; }
get_disk_used() { df -h / 2>/dev/null | awk 'NR==2{print $3}'; }
get_disk_pct() { df -h / 2>/dev/null | awk 'NR==2{print $5}'; }
get_load_avg_1m() { awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0"; }
get_cpu_alert_pct() {
  local load cores
  load="$(get_load_avg_1m)"
  cores="$(get_cpu_cores)"
  awk -v l="$load" -v c="$cores" 'BEGIN{ if (c+0 > 0) printf "%d", (l/c)*100; else print 0 }'
}
strip_pct() { echo "${1//%/}"; }

get_public_ipv4() {
  curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "Unavailable"
}

get_public_ipv6() {
  local external localv6
  external="$(curl -6fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
  if [[ -n "$external" ]]; then
    echo "$external"
    return
  fi

  localv6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  if [[ -z "$localv6" ]]; then
    localv6="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/:/{print; exit}' || true)"
  fi

  [[ -n "$localv6" ]] && echo "$localv6" || echo "Unavailable"
}

get_location() {
  local payload compact status country city
  payload="$(curl -fsS --max-time 5 "$LOCATION_API_URL" 2>/dev/null || true)"
  [[ -n "$payload" ]] || { echo "Unavailable"; return; }

  compact="$(tr -d '\n\r' <<<"$payload")"
  status="$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$compact" | head -n1)"
  country="$(sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$compact" | head -n1)"
  city="$(sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$compact" | head -n1)"

  [[ "$status" == "success" ]] || { echo "Unavailable"; return; }
  if [[ -n "$country" && -n "$city" ]]; then
    echo "$country, $city"
  elif [[ -n "$country" ]]; then
    echo "$country"
  elif [[ -n "$city" ]]; then
    echo "$city"
  else
    echo "Unavailable"
  fi
}

show_current_dns() {
  printf "%bCurrent DNS%b\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
  if [[ -f /etc/systemd/resolved.conf.d/99-sdt-dns.conf ]]; then
    local sdt_dns
    sdt_dns="$(awk -F= '/^DNS=/{print $2}' /etc/systemd/resolved.conf.d/99-sdt-dns.conf 2>/dev/null || true)"
    if [[ -n "$sdt_dns" ]]; then
      printf -- "- SDT configured: %s\n" "$sdt_dns"
    fi
  fi
  if command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved; then
    resolvectl dns 2>/dev/null | sed 's/^/- /' || true
  fi
  if [[ -f /etc/resolv.conf ]]; then
    awk '/^nameserver/{print "- " $2}' /etc/resolv.conf | head -n5
  fi
  echo
}

is_valid_ip() {
  local ip="$1"
  local ipv4_re='^((25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})$'
  local ipv6_re='^([0-9a-fA-F:]+:+)+[0-9a-fA-F]+$'
  [[ "$ip" =~ $ipv4_re || "$ip" =~ $ipv6_re ]]
}

dns_timestamp() { date +%Y%m%d%H%M%S; }

backup_dns_files() {
  local ts="$1"
  [[ -f /etc/resolv.conf ]] && cp -a /etc/resolv.conf "/etc/resolv.conf.sdt.bak.$ts"
  if [[ -f /etc/systemd/resolved.conf ]]; then
    cp -a /etc/systemd/resolved.conf "/etc/systemd/resolved.conf.sdt.bak.$ts"
  fi
  mkdir -p /etc/systemd/resolved.conf.d
  if [[ -f /etc/systemd/resolved.conf.d/99-sdt-dns.conf ]]; then
    cp -a /etc/systemd/resolved.conf.d/99-sdt-dns.conf "/etc/systemd/resolved.conf.d/99-sdt-dns.conf.sdt.bak.$ts"
  fi
}

use_systemd_resolved() {
  [[ -L /etc/resolv.conf ]] && readlink /etc/resolv.conf | grep -Eq 'systemd|stub-resolv' && return 0
  command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved
}

apply_dns_resolved() {
  local dns1="$1" dns2="$2"
  local active_iface=""
  mkdir -p /etc/systemd/resolved.conf.d
  {
    echo "[Resolve]"
    if [[ -n "$dns2" ]]; then
      echo "DNS=$dns1 $dns2"
    else
      echo "DNS=$dns1"
    fi
    echo "FallbackDNS="
  } > /etc/systemd/resolved.conf.d/99-sdt-dns.conf

  systemctl restart systemd-resolved || return 1
  active_iface="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}' || true)"
  if [[ -n "$active_iface" ]]; then
    resolvectl revert "$active_iface" >/dev/null 2>&1 || true
    if [[ -n "$dns2" ]]; then
      resolvectl dns "$active_iface" "$dns1" "$dns2" >/dev/null 2>&1 || return 1
    else
      resolvectl dns "$active_iface" "$dns1" >/dev/null 2>&1 || return 1
    fi
  fi
  resolvectl flush-caches >/dev/null 2>&1 || true
  return 0
}

apply_dns_resolv_conf() {
  local dns1="$1" dns2="$2"

  if grep -qiE 'NetworkManager|systemd-resolved|resolvconf' /etc/resolv.conf 2>/dev/null; then
    log_warn "/etc/resolv.conf appears managed by a service. Skipping direct write."
    return 1
  fi

  {
    echo "# Managed by SDT"
    echo "nameserver $dns1"
    [[ -n "$dns2" ]] && echo "nameserver $dns2"
  } > /etc/resolv.conf
}

verify_dns() {
  local dns1="$1" dns2="$2"
  local ok=1
  local active_iface=""
  active_iface="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}' || true)"

  if command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved; then
    if resolvectl status 2>/dev/null | grep -q "$dns1"; then
      ok=0
    fi
    [[ -n "$dns2" ]] && resolvectl status 2>/dev/null | grep -q "$dns2" && ok=0
    if [[ -n "$active_iface" ]]; then
      resolvectl dns "$active_iface" 2>/dev/null | grep -q "$dns1" && ok=0
      [[ -n "$dns2" ]] && resolvectl dns "$active_iface" 2>/dev/null | grep -q "$dns2" && ok=0
    fi
    grep -q "$dns1" /etc/systemd/resolved.conf.d/99-sdt-dns.conf 2>/dev/null && ok=0
    [[ -n "$dns2" ]] && grep -q "$dns2" /etc/systemd/resolved.conf.d/99-sdt-dns.conf 2>/dev/null && ok=0
  else
    if grep -q "nameserver $dns1" /etc/resolv.conf 2>/dev/null; then
      ok=0
    fi
    [[ -n "$dns2" ]] && grep -q "nameserver $dns2" /etc/resolv.conf 2>/dev/null && ok=0
  fi

  local i
  for i in {1..5}; do
    if getent hosts example.com >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  getent hosts example.com >/dev/null 2>&1 || return 1
  [[ $ok -eq 0 ]]
}

restore_dns_backup() {
  local latest
  latest="$(ls -1t /etc/resolv.conf.sdt.bak.* 2>/dev/null | head -n1 || true)"
  [[ -n "$latest" ]] || { log_err "No DNS backup found."; return 1; }

  cp -a "$latest" /etc/resolv.conf

  local latest_resolved_dropin
  latest_resolved_dropin="$(ls -1t /etc/systemd/resolved.conf.d/99-sdt-dns.conf.sdt.bak.* 2>/dev/null | head -n1 || true)"
  if [[ -n "$latest_resolved_dropin" ]]; then
    cp -a "$latest_resolved_dropin" /etc/systemd/resolved.conf.d/99-sdt-dns.conf
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved; then
    systemctl restart systemd-resolved || true
  fi

  if getent hosts example.com >/dev/null 2>&1; then
    log_ok "DNS restored from backup."
    return 0
  fi

  log_err "DNS restore completed but resolution test failed."
  return 1
}

change_dns_menu() {
  show_current_dns
  echo "Select DNS preset:"
  echo "1) Cloudflare (1.1.1.1, 1.0.0.1)"
  echo "2) Google (8.8.8.8, 8.8.4.4)"
  echo "3) Quad9 (9.9.9.9, 149.112.112.112)"
  echo "4) OpenDNS (208.67.222.222, 208.67.220.220)"
  echo "5) Custom"
  printf "Choose [1-5]: "

  local choice dns1 dns2
  IFS= read -r choice
  case "$choice" in
    1) dns1="1.1.1.1"; dns2="1.0.0.1" ;;
    2) dns1="8.8.8.8"; dns2="8.8.4.4" ;;
    3) dns1="9.9.9.9"; dns2="149.112.112.112" ;;
    4) dns1="208.67.222.222"; dns2="208.67.220.220" ;;
    5)
      printf "Enter primary DNS (IPv4/IPv6): "
      IFS= read -r dns1
      printf "Enter secondary DNS (optional): "
      IFS= read -r dns2
      ;;
    *) log_err "Invalid option."; return 1 ;;
  esac

  is_valid_ip "$dns1" || { log_err "Invalid primary DNS address."; return 1; }
  [[ -n "${dns2:-}" ]] && ! is_valid_ip "$dns2" && { log_err "Invalid secondary DNS address."; return 1; }

  local ts
  ts="$(dns_timestamp)"
  backup_dns_files "$ts"

  if use_systemd_resolved; then
    apply_dns_resolved "$dns1" "${dns2:-}" || { log_err "Failed to apply DNS via systemd-resolved."; return 1; }
  else
    apply_dns_resolv_conf "$dns1" "${dns2:-}" || { log_err "Failed to apply DNS via /etc/resolv.conf."; return 1; }
  fi

  if verify_dns "$dns1" "${dns2:-}"; then
    log_ok "DNS updated and verified."
    return 0
  fi

  log_err "DNS verification failed. Attempting rollback..."
  restore_dns_backup || true
  return 1
}

dns_settings_menu() {
  while true; do
    clear >/dev/null 2>&1 || true
    printf "%bDNS Settings%b\n\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
    show_current_dns
    echo "1) Change DNS Servers"
    echo "2) Restore Latest DNS Backup"
    echo "3) Back"
    printf "Choose an option [1-3]: "
    local c
    IFS= read -r c || return 0
    case "$c" in
      1) change_dns_menu || true; pause_enter ;;
      2) restore_dns_backup || true; pause_enter ;;
      3) return 0 ;;
      *) log_err "Invalid option."; sleep 1 ;;
    esac
  done
}

apt_backup_timestamp() { date +%Y%m%d%H%M%S; }

apt_backup_sources() {
  local ts="$1"
  local backup_dir="/var/backups/sdt/apt-$ts"
  mkdir -p "$backup_dir"

  [[ -f /etc/apt/sources.list ]] && cp -a /etc/apt/sources.list "$backup_dir/"
  [[ -d /etc/apt/sources.list.d ]] && cp -a /etc/apt/sources.list.d "$backup_dir/"

  echo "$backup_dir"
}

apt_restore_sources() {
  local backup_dir="$1"
  [[ -d "$backup_dir" ]] || return 1

  if [[ -f "$backup_dir/sources.list" ]]; then
    cp -a "$backup_dir/sources.list" /etc/apt/sources.list
  fi

  if [[ -d "$backup_dir/sources.list.d" ]]; then
    rm -rf /etc/apt/sources.list.d
    cp -a "$backup_dir/sources.list.d" /etc/apt/sources.list.d
  fi
}

get_distro_id() {
  awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

mirror_candidates() {
  local distro="$1"
  if [[ "$distro" == "ubuntu" ]]; then
    cat <<'EOL'
Official|http://archive.ubuntu.com/ubuntu
Mirror-Sweden|http://se.archive.ubuntu.com/ubuntu
Mirror-Germany|http://de.archive.ubuntu.com/ubuntu
Mirror-US|http://us.archive.ubuntu.com/ubuntu
Mirror-UK|http://gb.archive.ubuntu.com/ubuntu
Mirror-France|http://fr.archive.ubuntu.com/ubuntu
Mirror-Japan|http://jp.archive.ubuntu.com/ubuntu
Mirror-Singapore|http://sg.archive.ubuntu.com/ubuntu
EOL
  else
    cat <<'EOL'
Official|http://deb.debian.org/debian
Mirror-US|http://ftp.us.debian.org/debian
Mirror-UK|http://ftp.uk.debian.org/debian
Mirror-Germany|http://ftp.de.debian.org/debian
Mirror-France|http://ftp.fr.debian.org/debian
Mirror-Japan|http://ftp.jp.debian.org/debian
Mirror-Singapore|http://ftp.sg.debian.org/debian
EOL
  fi
}

get_current_apt_mirror() {
  local current=""

  if [[ -f /etc/apt/sources.list ]]; then
    current="$(awk '/^[[:space:]]*deb[[:space:]]+https?:\/\//{print $2; exit}' /etc/apt/sources.list 2>/dev/null || true)"
  fi

  if [[ -z "$current" ]]; then
    local f
    while IFS= read -r f; do
      current="$(awk '/^[[:space:]]*URIs:[[:space:]]*https?:\/\//{print $2; exit}' "$f" 2>/dev/null || true)"
      [[ -n "$current" ]] && break
    done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f -name '*.sources' 2>/dev/null)
  fi

  [[ -n "$current" ]] && echo "$current" || echo "Unknown"
}

mirror_host_from_url() {
  local url="$1"
  sed -E 's#^[a-z]+://([^/]+)/?.*#\1#' <<<"$url"
}

measure_mirror() {
  local name="$1" url="$2" host method="ping" score details
  host="$(mirror_host_from_url "$url")"

  local ping_out
  ping_out="$(ping -c 2 -W 1 "$host" 2>/dev/null || true)"
  if grep -q 'packet loss' <<<"$ping_out" && grep -q 'min/avg' <<<"$ping_out"; then
    local loss avg
    loss="$(awk -F',' '/packet loss/{gsub(/ /,"",$3); gsub(/%packetloss/,"",$3); print $3}' <<<"$ping_out" | head -n1)"
    avg="$(awk -F'=' '/min\/avg/{split($2,a,"/"); print a[2]}' <<<"$ping_out" | awk '{print $1}' | head -n1)"
    [[ -z "$avg" ]] && avg="9999"
    [[ -z "$loss" ]] && loss="100"
    score="$(awk -v a="$avg" -v l="$loss" 'BEGIN{printf "%.3f", (a+0) + (l+0)*100 }')"
    details="avg=${avg}ms loss=${loss}%"
  else
    method="curl"
    local tconn
    tconn="$(curl -o /dev/null -sS --connect-timeout 3 -w '%{time_connect}' "$url" 2>/dev/null || echo 9.999)"
    score="$(awk -v t="$tconn" 'BEGIN{printf "%.3f", (t+0)*1000 }')"
    details="connect=${tconn}s"
  fi

  printf "%s|%s|%s|%s|%s\n" "$score" "$name" "$url" "$method" "$details"
}

apply_mirror_url() {
  local distro="$1" new_url="$2"
  local f
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if [[ "$distro" == "ubuntu" ]]; then
      sed -E -i \
        -e "s#https?://([a-z0-9.-]+\.)?archive\.ubuntu\.com/ubuntu#${new_url}#g" \
        "$f"
    else
      sed -E -i \
        -e "s#https?://deb\.debian\.org/debian#${new_url}#g" \
        -e "s#https?://security\.debian\.org/debian-security#${new_url%/}/debian-security#g" \
        -e "s#https?://deb\.debian\.org/debian-security#${new_url%/}/debian-security#g" \
        -e "s#https?://ftp\.[a-z.]+/debian#${new_url}#g" \
        "$f"
    fi
  done < <(find /etc/apt -maxdepth 2 -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null)
}

apt_update_ok() {
  local log_file="$1"
  wait_for_apt_lock || return 1
  if ! apt update -y >"$log_file" 2>&1; then
    return 1
  fi
  if grep -Eq 'Failed to fetch|Some index files failed' "$log_file"; then
    return 1
  fi
  return 0
}

change_apt_mirror_menu() {
  local distro
  distro="$(get_distro_id)"
  [[ "$distro" == "ubuntu" || "$distro" == "debian" ]] || { log_err "Unsupported distro for mirror manager: $distro"; return 1; }

  local current_mirror
  current_mirror="$(get_current_apt_mirror)"
  printf "%bCurrent APT mirror:%b %s\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET" "$current_mirror"

  mapfile -t candidates < <(mirror_candidates "$distro")
  local row ranked=()
  log_info "Measuring mirror latency..."
  for row in "${candidates[@]}"; do
    local name url
    name="${row%%|*}"
    url="${row#*|}"
    ranked+=("$(measure_mirror "$name" "$url")")
  done

  mapfile -t ranked < <(printf "%s\n" "${ranked[@]}" | sort -t'|' -k1,1n)

  printf "%bMirror Ranking (fastest first)%b\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
  printf "%-4s %-16s %-45s %-8s %s\n" "#" "Name" "URL" "Method" "Stats"
  local i=1
  for row in "${ranked[@]}"; do
    IFS='|' read -r _score name url method details <<<"$row"
    printf "%-4s %-16s %-45s %-8s %s\n" "$i" "$name" "$url" "$method" "$details"
    i=$((i + 1))
  done
  echo "b) Back"
  echo "c) Custom mirror URL"
  printf "Select mirror: "

  local choice selected_url
  IFS= read -r choice
  if [[ "$choice" == "b" || "$choice" == "B" ]]; then
    log_info "Returning to main menu."
    return 0
  elif [[ "$choice" == "c" || "$choice" == "C" ]]; then
    printf "Enter custom mirror URL (e.g. http://mirror.example.com/ubuntu): "
    IFS= read -r selected_url
    [[ "$selected_url" =~ ^https?:// ]] || { log_err "Invalid URL."; return 1; }
    if [[ "$distro" == "ubuntu" && ! "$selected_url" =~ /ubuntu/?$ ]]; then
      log_err "For Ubuntu, mirror URL must end with /ubuntu"
      return 1
    fi
    if [[ "$distro" == "debian" && ! "$selected_url" =~ /debian/?$ ]]; then
      log_err "For Debian, mirror URL must end with /debian"
      return 1
    fi
  else
    [[ "$choice" =~ ^[0-9]+$ ]] || { log_err "Invalid choice."; return 1; }
    local idx=$((choice - 1))
    [[ $idx -ge 0 && $idx -lt ${#ranked[@]} ]] || { log_err "Choice out of range."; return 1; }
    selected_url="$(cut -d'|' -f3 <<<"${ranked[$idx]}")"
  fi

  local ts backup_dir
  ts="$(apt_backup_timestamp)"
  backup_dir="$(apt_backup_sources "$ts")"
  log_info "APT sources backed up to $backup_dir"

  apply_mirror_url "$distro" "$selected_url"

  if apt_update_ok /tmp/sdt-apt-update.log; then
    log_ok "Mirror applied and apt update succeeded."
    return 0
  fi

  log_err "apt update failed after mirror change. Rolling back..."
  apt_restore_sources "$backup_dir" || { log_err "Rollback failed."; return 1; }

  if apt_update_ok /tmp/sdt-apt-update-rollback.log; then
    log_ok "Rollback complete. Previous APT sources restored."
    return 1
  fi

  log_err "Rollback attempted but apt update still failing. Check /tmp/sdt-apt-update-rollback.log"
  return 1
}

show_dashboard() {
  local os kernel up cpu cores ram_total ram_used ram_pct disk_total disk_used disk_pct ipv4 ipv6 location
  local ram_num disk_num cpu_alert_pct
  os="$(get_os_name)"
  kernel="$(get_kernel)"
  up="$(get_uptime)"
  cpu="$(get_cpu_model)"
  cores="$(get_cpu_cores)"
  ram_total="$(get_ram_total)"
  ram_used="$(get_ram_used)"
  ram_pct="$(get_ram_pct)"
  disk_total="$(get_disk_total)"
  disk_used="$(get_disk_used)"
  disk_pct="$(get_disk_pct)"
  ram_num="$(strip_pct "${ram_pct:-0}")"
  disk_num="$(strip_pct "${disk_pct:-0}")"
  cpu_alert_pct="$(get_cpu_alert_pct)"
  ipv4="$(get_public_ipv4)"
  ipv6="$(get_public_ipv6)"
  location="$(get_location)"

  clear >/dev/null 2>&1 || true
  printf "%b=== %s ===%b\n\n" "$COLOR_BOLD" "$SDT_NAME" "$COLOR_RESET"

  printf "%bSYSTEM INFORMATION%b\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
  printf "%b- OS:%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${os:-Unknown}"
  printf "%b- Kernel:%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${kernel:-Unknown}"
  printf "%b- Uptime:%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${up:-Unknown}"
  printf "%b- CPU model:%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${cpu:-Unknown}"
  printf "%b- CPU cores:%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${cores:-Unknown}"
  printf "%b- RAM:%b %s/%s %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${ram_used:-Unknown}" "${ram_total:-Unknown}" "${ram_pct:-Unknown}"
  printf "%b- Disk:%b %s/%s %s\n\n" "$COLOR_YELLOW" "$COLOR_RESET" "${disk_used:-Unknown}" "${disk_total:-Unknown}" "${disk_pct:-Unknown}"

  printf "%bSYSTEM ALERTS%b\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
  if [[ "${ram_num:-0}" =~ ^[0-9]+$ ]] && (( ram_num >= ALERT_RAM_PCT )); then
    printf "%b- WARN:%b High RAM usage (%s >= %s%%)\n" "$COLOR_RED" "$COLOR_RESET" "${ram_pct:-Unknown}" "$ALERT_RAM_PCT"
  else
    printf "%b- OK:%b RAM usage normal (%s)\n" "$COLOR_GREEN" "$COLOR_RESET" "${ram_pct:-Unknown}"
  fi

  if [[ "${disk_num:-0}" =~ ^[0-9]+$ ]] && (( disk_num >= ALERT_DISK_PCT )); then
    printf "%b- WARN:%b High Disk usage (%s >= %s%%)\n" "$COLOR_RED" "$COLOR_RESET" "${disk_pct:-Unknown}" "$ALERT_DISK_PCT"
  else
    printf "%b- OK:%b Disk usage normal (%s)\n" "$COLOR_GREEN" "$COLOR_RESET" "${disk_pct:-Unknown}"
  fi

  if [[ "${cpu_alert_pct:-0}" =~ ^[0-9]+$ ]] && (( cpu_alert_pct >= ALERT_CPU_PCT )); then
    printf "%b- WARN:%b High CPU load (approx %s%% >= %s%%)\n\n" "$COLOR_RED" "$COLOR_RESET" "$cpu_alert_pct" "$ALERT_CPU_PCT"
  else
    printf "%b- OK:%b CPU load normal (approx %s%%)\n\n" "$COLOR_GREEN" "$COLOR_RESET" "$cpu_alert_pct"
  fi

  printf "%bNETWORK INFORMATION%b\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
  printf "%b- Public IPv4:%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${ipv4:-Unavailable}"
  printf "%b- Public IPv6:%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${ipv6:-Unavailable}"
  printf "%b- Location (Country, City):%b %s\n\n" "$COLOR_YELLOW" "$COLOR_RESET" "${location:-Unavailable}"

  printf "%bPROCESS MONITOR%b\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
  printf "%b- Top CPU processes%b\n" "$COLOR_YELLOW" "$COLOR_RESET"
  if command -v ps >/dev/null 2>&1; then
    ps -eo pid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -n 6 | sed 's/^/  /'
  else
    echo "  ps command not found"
  fi
  printf "\n%b- Top Memory processes%b\n" "$COLOR_YELLOW" "$COLOR_RESET"
  if command -v ps >/dev/null 2>&1; then
    ps -eo pid,comm,%cpu,%mem --sort=-%mem 2>/dev/null | head -n 6 | sed 's/^/  /'
  else
    echo "  ps command not found"
  fi
  printf "\n"
}

pause_enter() {
  printf "Press Enter to continue..."
  read -r _
}

get_sshd_config_value() {
  local key="$1"
  local val=""

  if command -v sshd >/dev/null 2>&1; then
    val="$(sshd -T 2>/dev/null | awk -v k="$key" '$1==k {print $2; exit}' || true)"
  fi

  if [[ -z "$val" && -f /etc/ssh/sshd_config ]]; then
    val="$(awk -v k="$key" 'tolower($1)==tolower(k){print $2}' /etc/ssh/sshd_config | tail -n1 || true)"
  fi

  [[ -n "$val" ]] && echo "$val" || echo "unknown"
}

show_fail2ban_status() {
  printf "%b[Fail2ban]%b\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
  if ! dpkg -s fail2ban >/dev/null 2>&1; then
    echo "- fail2ban not installed"
    return
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "- Package installed (systemctl unavailable)"
    return
  fi

  local state
  state="$(systemctl is-active fail2ban 2>/dev/null || true)"
  echo "- Service state: ${state:-unknown}"
  if command -v fail2ban-client >/dev/null 2>&1; then
    local jails
    jails="$(fail2ban-client status 2>/dev/null | awk -F: '/Jail list/{gsub(/^ +/,"",$2); print $2}' || true)"
    [[ -n "$jails" ]] && echo "- Active jails: $jails" || echo "- Active jails: none/unknown"
  fi
}

install_fail2ban() {
  export DEBIAN_FRONTEND=noninteractive
  wait_for_apt_lock || { log_err "Timeout waiting for apt lock."; return 1; }
  log_info "Installing fail2ban..."
  if apt-get update -y >/dev/null 2>&1 && apt-get install -y fail2ban >/dev/null 2>&1; then
    systemctl enable --now fail2ban >/dev/null 2>&1 || true
    log_ok "fail2ban installed."
    return 0
  fi
  log_err "Failed to install fail2ban."
  return 1
}

show_ssh_hardening_checks() {
  printf "%b[Root SSH Hardening]%b\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
  local permit_root password_auth pubkey_auth
  permit_root="$(get_sshd_config_value permitrootlogin)"
  password_auth="$(get_sshd_config_value passwordauthentication)"
  pubkey_auth="$(get_sshd_config_value pubkeyauthentication)"

  echo "- PermitRootLogin: $permit_root"
  echo "- PasswordAuthentication: $password_auth"
  echo "- PubkeyAuthentication: $pubkey_auth"

  if [[ "$permit_root" == "no" || "$permit_root" == "prohibit-password" ]]; then
    echo "- Root login policy: hardened"
  else
    echo "- Root login policy: review recommended"
  fi
}

show_open_ports_summary() {
  printf "%b[Open Ports]%b\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
  if ! command -v ss >/dev/null 2>&1; then
    echo "- ss command not found"
    return
  fi

  local lines
  lines="$(ss -tulnH 2>/dev/null | awk '{print $1, $5}' | sed 's/\\[//g; s/\\]//g' | head -n 20 || true)"
  if [[ -z "$lines" ]]; then
    echo "- No listening TCP/UDP ports detected"
  else
    echo "$lines" | awk '{printf "- %s %s\n", $1, $2}'
  fi
}

show_unattended_upgrades_status() {
  printf "%b[Unattended Upgrades]%b\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
  if dpkg -s unattended-upgrades >/dev/null 2>&1; then
    echo "- Package: installed"
  else
    echo "- Package: not installed"
    return
  fi

  local auto_file="/etc/apt/apt.conf.d/20auto-upgrades"
  if [[ -f "$auto_file" ]]; then
    local apt_periodic unattended
    apt_periodic="$(awk -F'\"' '/APT::Periodic::Update-Package-Lists/{print $2}' "$auto_file" | tail -n1)"
    unattended="$(awk -F'\"' '/APT::Periodic::Unattended-Upgrade/{print $2}' "$auto_file" | tail -n1)"
    echo "- Update package lists: ${apt_periodic:-unknown}"
    echo "- Unattended upgrade: ${unattended:-unknown}"
  else
    echo "- Auto-upgrades config file not found"
  fi
}

install_unattended_upgrades() {
  export DEBIAN_FRONTEND=noninteractive
  wait_for_apt_lock || { log_err "Timeout waiting for apt lock."; return 1; }
  log_info "Installing unattended-upgrades..."
  if apt-get update -y >/dev/null 2>&1 && apt-get install -y unattended-upgrades >/dev/null 2>&1; then
    dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
    log_ok "unattended-upgrades installed."
    return 0
  fi
  log_err "Failed to install unattended-upgrades."
  return 1
}

security_quick_checks_menu() {
  while true; do
    clear >/dev/null 2>&1 || true
    printf "%bSecurity Quick Checks%b\n\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
    show_fail2ban_status
    echo
    show_ssh_hardening_checks
    echo
    show_open_ports_summary
    echo
    show_unattended_upgrades_status
    echo

    local fail2ban_missing unattended_missing
    fail2ban_missing=0
    unattended_missing=0
    dpkg -s fail2ban >/dev/null 2>&1 || fail2ban_missing=1
    dpkg -s unattended-upgrades >/dev/null 2>&1 || unattended_missing=1

    if (( fail2ban_missing == 1 || unattended_missing == 1 )); then
      local idx=1
      local opt_fail2ban=0 opt_unattended=0 opt_back=0
      if (( fail2ban_missing == 1 )); then
        echo "${idx}) Install Fail2ban"
        opt_fail2ban=$idx
        idx=$((idx + 1))
      fi
      if (( unattended_missing == 1 )); then
        echo "${idx}) Install Unattended Upgrades"
        opt_unattended=$idx
        idx=$((idx + 1))
      fi
      echo "${idx}) Back"
      opt_back=$idx
      printf "Choose an option [1-%s]: " "$opt_back"
      local c
      IFS= read -r c || return 0
      [[ "$c" =~ ^[0-9]+$ ]] || { log_err "Invalid option."; sleep 1; continue; }
      if (( opt_fail2ban > 0 )) && [[ "$c" -eq "$opt_fail2ban" ]]; then
        install_fail2ban || true
        pause_enter
      elif (( opt_unattended > 0 )) && [[ "$c" -eq "$opt_unattended" ]]; then
        install_unattended_upgrades || true
        pause_enter
      elif [[ "$c" -eq "$opt_back" ]]; then
        return 0
      else
        log_err "Invalid option."
        sleep 1
      fi
    else
      echo "1) Back"
      printf "Choose an option [1]: "
      local c
      IFS= read -r c || return 0
      case "$c" in
        1) return 0 ;;
        *) log_err "Invalid option."; sleep 1 ;;
      esac
    fi
  done
}

network_ping_test() {
  local target
  printf "Enter host/IP to ping [default: 1.1.1.1]: "
  IFS= read -r target
  target="${target:-1.1.1.1}"
  printf "%b[Ping Test]%b %s\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET" "$target"
  if ping -c 4 -W 1 "$target" >/tmp/sdt-ping.log 2>&1; then
    tail -n 3 /tmp/sdt-ping.log
  else
    log_err "Ping failed for $target"
    tail -n 3 /tmp/sdt-ping.log || true
  fi
}

network_dns_lookup_test() {
  local host
  printf "Enter domain to resolve [default: example.com]: "
  IFS= read -r host
  host="${host:-example.com}"
  printf "%b[DNS Lookup]%b %s\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET" "$host"
  if getent hosts "$host" >/tmp/sdt-dns-lookup.log 2>&1; then
    cat /tmp/sdt-dns-lookup.log
  else
    log_err "DNS lookup failed for $host"
    cat /tmp/sdt-dns-lookup.log || true
  fi
}

network_route_test() {
  local target
  printf "Enter target IP for route test [default: 1.1.1.1]: "
  IFS= read -r target
  target="${target:-1.1.1.1}"
  printf "%b[Route Test]%b %s\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET" "$target"
  if ip route get "$target" >/tmp/sdt-route.log 2>&1; then
    cat /tmp/sdt-route.log
  else
    log_err "Route test failed for $target"
    cat /tmp/sdt-route.log || true
  fi
}

network_latency_test() {
  local url
  printf "Enter URL for latency test [default: https://api.ipify.org]: "
  IFS= read -r url
  url="${url:-https://api.ipify.org}"
  printf "%b[Latency Test]%b %s\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET" "$url"
  local result
  result="$(curl -o /dev/null -sS --connect-timeout 5 -w 'connect=%{time_connect}s total=%{time_total}s code=%{http_code}\n' "$url" 2>/tmp/sdt-latency.err || true)"
  if [[ -n "$result" ]]; then
    echo "$result"
  else
    log_err "Latency test failed for $url"
    cat /tmp/sdt-latency.err || true
  fi
}

network_diagnostics_menu() {
  while true; do
    clear >/dev/null 2>&1 || true
    printf "%bNetwork Diagnostics%b\n\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
    echo "1) Ping Test"
    echo "2) DNS Lookup Test"
    echo "3) Route Test"
    echo "4) Latency Test"
    echo "5) Back"
    printf "Choose an option [1-5]: "

    local c
    IFS= read -r c || return 0
    case "$c" in
      1) network_ping_test; pause_enter ;;
      2) network_dns_lookup_test; pause_enter ;;
      3) network_route_test; pause_enter ;;
      4) network_latency_test; pause_enter ;;
      5) return 0 ;;
      *) log_err "Invalid option."; sleep 1 ;;
    esac
  done
}

cleanup_autoremove() {
  export DEBIAN_FRONTEND=noninteractive
  wait_for_apt_lock || { log_err "Timeout waiting for apt lock."; return 1; }
  log_info "Running apt autoremove -y"
  if apt autoremove -y; then
    log_ok "apt autoremove completed."
  else
    log_err "apt autoremove failed."
    return 1
  fi
}

cleanup_apt_clean() {
  log_info "Running apt clean"
  if apt clean; then
    log_ok "apt clean completed."
  else
    log_err "apt clean failed."
    return 1
  fi
}

cleanup_old_kernel_check() {
  printf "%b[Old Kernel Check]%b\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
  local running version count
  running="$(uname -r 2>/dev/null || echo unknown)"
  version="$(dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii/{print $2}' | sed 's/^linux-image-//' || true)"
  count="$(printf "%s\n" "$version" | sed '/^$/d' | wc -l | tr -d ' ')"

  echo "- Running kernel: $running"
  echo "- Installed kernel images: ${count:-0}"
  if [[ -n "$version" ]]; then
    echo "- Installed versions:"
    printf "%s\n" "$version" | sed '/^$/d' | sed 's/^/  - /'
  fi

  if [[ "${count:-0}" =~ ^[0-9]+$ ]] && (( count > 2 )); then
    log_warn "Multiple kernel images installed. Review removable old kernels carefully."
  else
    log_ok "No obvious old-kernel buildup detected."
  fi
}

package_cleanup_menu() {
  while true; do
    clear >/dev/null 2>&1 || true
    printf "%bPackage Cleanup Tools%b\n\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
    echo "1) apt autoremove (safe)"
    echo "2) apt clean (safe)"
    echo "3) Old kernel check"
    echo "4) Back"
    printf "Choose an option [1-4]: "

    local c
    IFS= read -r c || return 0
    case "$c" in
      1) cleanup_autoremove || true; pause_enter ;;
      2) cleanup_apt_clean || true; pause_enter ;;
      3) cleanup_old_kernel_check; pause_enter ;;
      4) return 0 ;;
      *) log_err "Invalid option."; sleep 1 ;;
    esac
  done
}

show_log_file() {
  local log_path="$1"
  local lines="${2:-50}"
  local filter="${3:-}"

  if [[ ! -f "$log_path" ]]; then
    log_warn "Log file not found: $log_path"
    return 1
  fi

  if [[ -n "$filter" ]]; then
    printf "%b[Filtered Tail]%b %s (filter: %s)\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET" "$log_path" "$filter"
    tail -n "$lines" "$log_path" 2>/dev/null | grep -i -- "$filter" || echo "- No matching lines found."
  else
    printf "%b[Tail]%b %s\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET" "$log_path"
    tail -n "$lines" "$log_path" 2>/dev/null
  fi
}

log_viewer_menu() {
  while true; do
    clear >/dev/null 2>&1 || true
    printf "%bLog Viewer%b\n\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
    echo "1) syslog (/var/log/syslog)"
    echo "2) auth.log (/var/log/auth.log)"
    echo "3) nginx access.log (/var/log/nginx/access.log)"
    echo "4) nginx error.log (/var/log/nginx/error.log)"
    echo "5) Back"
    printf "Choose a log [1-5]: "

    local c path lines filter
    IFS= read -r c || return 0
    case "$c" in
      1) path="/var/log/syslog" ;;
      2) path="/var/log/auth.log" ;;
      3) path="/var/log/nginx/access.log" ;;
      4) path="/var/log/nginx/error.log" ;;
      5) return 0 ;;
      *) log_err "Invalid option."; sleep 1; continue ;;
    esac

    printf "Lines to show [default: 50]: "
    IFS= read -r lines
    lines="${lines:-50}"
    [[ "$lines" =~ ^[0-9]+$ ]] || lines="50"

    printf "Filter keyword (optional): "
    IFS= read -r filter

    show_log_file "$path" "$lines" "$filter" || true
    pause_enter
  done
}

disk_explorer_menu() {
  while true; do
    clear >/dev/null 2>&1 || true
    printf "%bDisk Explorer%b\n\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
    echo "1) Top directories in / (depth 1)"
    echo "2) Top directories in custom path"
    echo "3) Top files in / (largest)"
    echo "4) Top files in custom path"
    echo "5) Back"
    printf "Choose an option [1-5]: "

    local c target
    IFS= read -r c || return 0
    case "$c" in
      1)
        printf "%b[Top Directories]%b /\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
        (set +o pipefail; du -x -h --max-depth=1 / 2>/dev/null | sort -hr | head -n 15) || true
        pause_enter
        ;;
      2)
        printf "Enter directory path [default: /var]: "
        IFS= read -r target
        target="${target:-/var}"
        if [[ ! -d "$target" ]]; then
          log_err "Directory not found: $target"
        else
          printf "%b[Top Directories]%b %s\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET" "$target"
          (set +o pipefail; du -x -h --max-depth=1 "$target" 2>/dev/null | sort -hr | head -n 15) || true
        fi
        pause_enter
        ;;
      3)
        printf "%b[Top Files]%b /\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
        (set +o pipefail; find / -xdev -type f -printf '%s\t%p\n' 2>/dev/null | sort -nr | head -n 20 | awk '{printf "- %.2f MB  %s\n", $1/1048576, $2}') || true
        pause_enter
        ;;
      4)
        printf "Enter directory path [default: /var]: "
        IFS= read -r target
        target="${target:-/var}"
        if [[ ! -d "$target" ]]; then
          log_err "Directory not found: $target"
        else
          printf "%b[Top Files]%b %s\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET" "$target"
          (set +o pipefail; find "$target" -xdev -type f -printf '%s\t%p\n' 2>/dev/null | sort -nr | head -n 20 | awk '{printf "- %.2f MB  %s\n", $1/1048576, $2}') || true
        fi
        pause_enter
        ;;
      5) return 0 ;;
      *) log_err "Invalid option."; sleep 1 ;;
    esac
  done
}

menu_loop() {
  while true; do
    show_dashboard
    echo "1) Update and Upgrade System"
    echo "2) DNS Settings"
    echo "3) APT Mirror Settings"
    echo "4) Security Quick Checks"
    echo "5) Network Diagnostics"
    echo "6) Disk Explorer"
    echo "7) Package Cleanup Tools"
    echo "8) Log Viewer"
    echo "9) Exit"
    printf "Choose an option [1-9] (auto-refresh in 60s): "

    local c
    if ! IFS= read -r -t 60 c; then
      continue
    fi
    case "$c" in
      1) apt_maintenance || true; pause_enter ;;
      2) dns_settings_menu || true ;;
      3) change_apt_mirror_menu || true; pause_enter ;;
      4) security_quick_checks_menu ;;
      5) network_diagnostics_menu ;;
      6) disk_explorer_menu ;;
      7) package_cleanup_menu ;;
      8) log_viewer_menu ;;
      9) log_ok "Goodbye."; exit 0 ;;
      *) log_err "Invalid option."; sleep 1 ;;
    esac
  done
}

main() {
  require_root
  ensure_deps
  menu_loop
}

main "$@"
