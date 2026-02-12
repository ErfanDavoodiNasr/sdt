#!/usr/bin/env bash
set -euo pipefail

readonly SDT_NAME="SDT - Server Dashboard Tool"
readonly COLOR_RESET='\033[0m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_RED='\033[31m'
readonly COLOR_GREEN='\033[32m'
readonly COLOR_CYAN='\033[36m'
readonly COLOR_YELLOW='\033[33m'
readonly LOCATION_API_URL="http://ip-api.com/json"

error() {
  printf "%b[ERROR]%b %s\n" "$COLOR_RED" "$COLOR_RESET" "$1" >&2
}

info() {
  printf "%b[INFO]%b %s\n" "$COLOR_CYAN" "$COLOR_RESET" "$1"
}

success() {
  printf "%b[OK]%b %s\n" "$COLOR_GREEN" "$COLOR_RESET" "$1"
}

run_or_fail() {
  local description="$1"
  shift
  info "$description"
  if ! "$@"; then
    error "$description failed."
    exit 1
  fi
}

ensure_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "SDT must run as root to perform apt update/upgrade."
    exit 1
  fi
}

ensure_dep() {
  local dep="$1"
  if ! command -v "$dep" >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      info "Installing missing dependency: $dep"
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null
      apt-get install -y "$dep" >/dev/null
    else
      error "Missing dependency: $dep"
      exit 1
    fi
  fi
}

apt_maintenance() {
  export DEBIAN_FRONTEND=noninteractive
  run_or_fail "Running apt update" apt update -y
  run_or_fail "Running apt upgrade" apt upgrade -y
  success "System packages are up to date."
}

get_os_pretty_name() {
  if [[ -r /etc/os-release ]]; then
    awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release
  else
    echo "Unknown"
  fi
}

get_cpu_model() {
  awk -F: '/model name/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "Unknown"
}

get_cpu_cores() {
  nproc 2>/dev/null || echo "Unknown"
}

get_ram_total() {
  free -h 2>/dev/null | awk '/^Mem:/{print $2}'
}

get_ram_used() {
  free -h 2>/dev/null | awk '/^Mem:/{print $3}'
}

get_ram_percent() {
  free 2>/dev/null | awk '/^Mem:/ { if ($2 > 0) printf "%d%%", ($3*100)/$2; else print "Unknown" }'
}

get_root_disk_total() {
  df -h / 2>/dev/null | awk 'NR==2{print $2}'
}

get_root_disk_used() {
  df -h / 2>/dev/null | awk 'NR==2{print $3}'
}

get_root_disk_percent() {
  df -h / 2>/dev/null | awk 'NR==2{print $5}'
}

get_ram_usage_line() {
  local used total pct
  used="$(get_ram_used)"
  total="$(get_ram_total)"
  pct="$(get_ram_percent)"
  echo "${used:-Unknown}/${total:-Unknown} ${pct:-Unknown}"
}

get_disk_usage_line() {
  local used total pct
  used="$(get_root_disk_used)"
  total="$(get_root_disk_total)"
  pct="$(get_root_disk_percent)"
  echo "${used:-Unknown}/${total:-Unknown} ${pct:-Unknown}"
}

get_public_ipv4() {
  curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "Unavailable"
}

get_public_ipv6() {
  local external_v6=""
  external_v6="$(curl -6fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
  if [[ -n "$external_v6" ]]; then
    echo "$external_v6"
    return
  fi

  # Fallback: use first global IPv6 assigned to local interfaces.
  local local_v6=""
  if command -v ip >/dev/null 2>&1; then
    local_v6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | head -n1)"
  fi

  if [[ -z "$local_v6" ]]; then
    local_v6="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/:/{print; exit}')"
  fi

  if [[ -n "$local_v6" ]]; then
    echo "$local_v6"
  else
    echo "Unavailable"
  fi
}

parse_json_field() {
  local json="$1"
  local key="$2"
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" <<<"$json" | head -n1
}

get_location() {
  local payload
  if ! payload="$(curl -fsS --max-time 5 "$LOCATION_API_URL" 2>/dev/null || true)"; then
    echo "Unavailable"
    return
  fi

  if [[ -z "$payload" ]]; then
    echo "Unavailable"
    return
  fi

  local status country city
  local compact_payload
  compact_payload="$(tr -d '\n\r' <<<"$payload")"
  status="$(parse_json_field "$compact_payload" "status")"
  country="$(parse_json_field "$compact_payload" "country")"
  city="$(parse_json_field "$compact_payload" "city")"

  if [[ "$status" != "success" ]]; then
    echo "Unavailable"
    return
  fi

  if [[ -z "$country" && -z "$city" ]]; then
    echo "Unavailable"
    return
  fi

  if [[ -z "$city" ]]; then
    echo "$country"
  elif [[ -z "$country" ]]; then
    echo "$city"
  else
    echo "$country, $city"
  fi
}

show_dashboard() {
  local os_name kernel uptime_text cpu_model cpu_cores ram_usage_line disk_usage_line ipv4 ipv6 location
  os_name="$(get_os_pretty_name)"
  kernel="$(uname -r 2>/dev/null || echo Unknown)"
  uptime_text="$(uptime -p 2>/dev/null || echo Unknown)"
  cpu_model="$(get_cpu_model)"
  cpu_cores="$(get_cpu_cores)"
  ram_usage_line="$(get_ram_usage_line)"
  disk_usage_line="$(get_disk_usage_line)"
  ipv4="$(get_public_ipv4)"
  ipv6="$(get_public_ipv6)"
  location="$(get_location)"

  clear || true
  printf "%b=== %s ===%b\n\n" "$COLOR_BOLD" "$SDT_NAME" "$COLOR_RESET"

  printf "%bSYSTEM INFORMATION%b\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
  printf "%b- OS:%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${os_name:-Unknown}"
  printf "%b- Kernel:%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${kernel:-Unknown}"
  printf "%b- Uptime:%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${uptime_text:-Unknown}"
  printf "%b- CPU model:%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${cpu_model:-Unknown}"
  printf "%b- CPU cores:%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${cpu_cores:-Unknown}"
  printf "%b- RAM usage:%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${ram_usage_line:-Unknown}"
  printf "%b- Disk usage (/):%b %s\n\n" "$COLOR_YELLOW" "$COLOR_RESET" "${disk_usage_line:-Unknown}"

  printf "%bNETWORK INFORMATION%b\n" "$COLOR_BOLD$COLOR_CYAN" "$COLOR_RESET"
  printf "%b- Public IPv4:%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${ipv4:-Unavailable}"
  printf "%b- Public IPv6:%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "${ipv6:-Unavailable}"
  printf "%b- Location (Country, City):%b %s\n\n" "$COLOR_YELLOW" "$COLOR_RESET" "${location:-Unavailable}"
}

menu_loop() {
  while true; do
    show_dashboard
    printf "1) Update and upgrade server\n"
    printf "2) Exit\n"
    printf "Choose an option [1-2]: "

    local choice=""
    if ! IFS= read -r choice; then
      echo
      exit 0
    fi

    case "$choice" in
      1)
        apt_maintenance
        sleep 1
        ;;
      2)
        success "Goodbye."
        exit 0
        ;;
      *)
        error "Invalid option: $choice"
        sleep 1
        ;;
    esac
  done
}

main() {
  ensure_root
  ensure_dep curl
  menu_loop
}

main "$@"
