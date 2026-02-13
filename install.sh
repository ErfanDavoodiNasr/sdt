#!/usr/bin/env bash
set -euo pipefail

readonly INSTALL_PATH="/usr/local/bin/sdt"
readonly DEFAULT_RAW_BASE="https://raw.githubusercontent.com/your-user/sdt/main"
readonly TMP_FILE="/tmp/sdt.sh.$$"

log() { printf "[SDT Installer] %s\n" "$1"; }
err() { printf "[SDT Installer][ERROR] %s\n" "$1" >&2; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "Run as root (or sudo)."; exit 1; }
}

ensure_dep() {
  local dep="$1"
  if ! command -v "$dep" >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "$dep"
  fi
}

install_from_local() {
  local local_script="${SDT_LOCAL_SCRIPT:-}"
  [[ -n "$local_script" && -f "$local_script" ]] || return 1

  install -m 0755 "$local_script" "$INSTALL_PATH"
  return 0
}

install_from_raw() {
  local raw_base="${SDT_RAW_BASE:-$DEFAULT_RAW_BASE}"
  local raw_url="${raw_base%/}/sdt.sh"

  curl -fsSL "$raw_url" -o "$TMP_FILE"
  chmod +x "$TMP_FILE"
  install -m 0755 "$TMP_FILE" "$INSTALL_PATH"
  rm -f "$TMP_FILE"
}

main() {
  require_root
  ensure_dep curl
  ensure_dep ca-certificates

  if install_from_local; then
    log "Installed SDT from local script path."
  else
    log "Downloading SDT script..."
    install_from_raw
    log "Installed SDT from remote raw URL."
  fi

  log "Installation complete: $INSTALL_PATH"
  if [[ "${SDT_AUTO_RUN:-1}" == "1" ]]; then
    exec "$INSTALL_PATH"
  else
    log "Run SDT with: sdt"
  fi
}

main "$@"
