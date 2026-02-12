#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_REPO_URL="https://github.com/your-user/sdt.git"
readonly INSTALL_TARGET="/usr/local/bin/sdt"
readonly WORK_DIR_BASE="/tmp/sdt-install"

log() {
  printf "[SDT Installer] %s\n" "$1"
}

fail() {
  printf "[SDT Installer][ERROR] %s\n" "$1" >&2
  exit 1
}

ensure_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Run installer as root (or with sudo)."
  fi
}

ensure_apt_dep() {
  local dep="$1"
  if ! command -v "$dep" >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "$dep"
  fi
}

fetch_repo() {
  local repo_url="$1"
  local work_dir="$2"

  rm -rf "$work_dir"
  mkdir -p "$work_dir"

  if [[ -d "$repo_url" ]]; then
    log "Using local repository path: $repo_url"
    cp -a "$repo_url" "$work_dir/repo"
  elif command -v git >/dev/null 2>&1; then
    log "Downloading SDT via git clone"
    git clone --depth 1 "$repo_url" "$work_dir/repo"
  else
    log "git not found; downloading tarball via curl"
    local tarball_url="${repo_url%.git}/archive/refs/heads/main.tar.gz"
    curl -fsSL "$tarball_url" -o "$work_dir/sdt.tar.gz"
    mkdir -p "$work_dir/repo"
    tar -xzf "$work_dir/sdt.tar.gz" -C "$work_dir/repo" --strip-components=1
  fi
}

install_binary() {
  local repo_dir="$1"
  local source_script=""

  if [[ -f "$repo_dir/sdt.sh" ]]; then
    source_script="$repo_dir/sdt.sh"
  elif [[ -f "$repo_dir/bin/sdt" ]]; then
    source_script="$repo_dir/bin/sdt"
  else
    fail "Could not find sdt script in repository."
  fi

  install -m 0755 "$source_script" "$INSTALL_TARGET"
  mkdir -p /etc/sdt
}

install_alias() {
  local alias_file="/etc/profile.d/sdt-alias.sh"
  cat > "$alias_file" <<'EOF'
#!/usr/bin/env sh
alias sdt='/usr/local/bin/sdt'
EOF
  chmod 0644 "$alias_file"
}

main() {
  ensure_root
  ensure_apt_dep curl
  ensure_apt_dep ca-certificates

  local repo_url="${SDT_REPO_URL:-$DEFAULT_REPO_URL}"
  local work_dir="$WORK_DIR_BASE.$$"

  log "Installing from: $repo_url"
  fetch_repo "$repo_url" "$work_dir"
  install_binary "$work_dir/repo"
  install_alias

  rm -rf "$work_dir"

  log "Installation complete."
  log "Run SDT with: sdt"

  if [[ "${SDT_AUTO_RUN:-1}" == "1" ]]; then
    exec "$INSTALL_TARGET"
  fi
}

main "$@"
