#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:-}"

REPO_SSH="${REPO_SSH:-git@github.com:Mygod/slipstream-rust.git}"
REPO_HTTPS="${REPO_HTTPS:-https://github.com/Mygod/slipstream-rust.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/slipstream-rust}"

TCP_LISTEN_PORT="$2"
RESOLVER_ADDR="$3"
DOMAIN="$4"
RESOLV_NAMESERVER_IP="$5"

CERT_SUBJ="${CERT_SUBJ:-/CN=${DOMAIN}}"
CERT_DAYS="${CERT_DAYS:-365}"
CARGO_PROFILE="${CARGO_PROFILE:-release}"

DNS_LISTEN_PORT="${DNS_LISTEN_PORT:-53}"
TARGET_ADDRESS="${TARGET_ADDRESS:-127.0.0.1:22}"
INSTALL_TINYPROXY="${INSTALL_TINYPROXY:-0}"
TINYPROXY_PORT="${TINYPROXY_PORT:-8888}"
TINYPROXY_LISTEN="${TINYPROXY_LISTEN:-127.0.0.1}"

DISABLE_SYSTEMD_RESOLVED="${DISABLE_SYSTEMD_RESOLVED:-1}"
WRITE_RESOLV_CONF="${WRITE_RESOLV_CONF:-1}"

log()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m" >&2; }
die()  { echo -e "\033[1;31m[-] $*\033[0m" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root (sudo)."
  fi
}

install_deps_common() {
  export DEBIAN_FRONTEND=noninteractive
  log "Installing OS dependencies (apt)..."
  apt-get update -y
  apt-get install -y --no-install-recommends \
    git ca-certificates curl openssl \
    build-essential cmake make pkg-config libssl-dev
}

install_rustup() {
  if ! have_cmd rustup; then
    log "Installing rustup..."
    curl -fsSL https://sh.rustup.rs | sh -s -- -y
  fi
  # shellcheck disable=SC1091
  source "${HOME}/.cargo/env"
  log "Setting Rust toolchain to stable..."
  rustup default stable
}

clone_or_update_repo() {
  log "Cloning/updating repo in ${INSTALL_DIR}..."
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    warn "Repo exists; pulling latest..."
    git -C "${INSTALL_DIR}" pull --ff-only
  else
    mkdir -p "$(dirname "${INSTALL_DIR}")"
    if git clone "${REPO_SSH}" "${INSTALL_DIR}"; then
      :
    else
      warn "SSH clone failed; trying HTTPS..."
      git clone "${REPO_HTTPS}" "${INSTALL_DIR}"
    fi
  fi

  log "Initializing submodules..."
  git -C "${INSTALL_DIR}" submodule update --init --recursive
}

build_binaries() {
  log "Building slipstream-client and slipstream-server (cargo, profile=${CARGO_PROFILE})..."
  if [[ "${CARGO_PROFILE}" == "release" ]]; then
    (cd "${INSTALL_DIR}" && cargo build -p slipstream-client -p slipstream-server --release)
  else
    (cd "${INSTALL_DIR}" && cargo build -p slipstream-client -p slipstream-server)
  fi
}

gen_cert() {
  log "Generating self-signed cert/key in ${INSTALL_DIR} (cert.pem, key.pem)..."
  cd "${INSTALL_DIR}"
  if [[ -f cert.pem || -f key.pem ]]; then
    warn "cert.pem/key.pem already exist; skipping."
    return
  fi

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout key.pem \
    -out cert.pem \
    -days "${CERT_DAYS}" \
    -subj "${CERT_SUBJ}"
}

maybe_adjust_dns() {
  if [[ "${DISABLE_SYSTEMD_RESOLVED}" == "1" ]]; then
    log "Disabling systemd-resolved (opt-in enabled)..."
    systemctl stop systemd-resolved || true
    systemctl disable systemd-resolved || true
  else
    warn "Not disabling systemd-resolved (set DISABLE_SYSTEMD_RESOLVED=1 to do it)."
  fi

  if [[ "${WRITE_RESOLV_CONF}" == "1" ]]; then
    [[ -n "${RESOLV_NAMESERVER_IP}" ]] || die "WRITE_RESOLV_CONF=1 needs RESOLV_NAMESERVER_IP=<ip>"
    log "Writing /etc/resolv.conf (opt-in enabled) -> nameserver ${RESOLV_NAMESERVER_IP}"
    cat > /etc/resolv.conf <<EOF
nameserver ${RESOLV_NAMESERVER_IP}
options edns0 trust-ad
EOF
  else
    warn "Not touching /etc/resolv.conf (set WRITE_RESOLV_CONF=1 to do it)."
  fi
}

install_tinyproxy_if_needed() {
  if [[ "${INSTALL_TINYPROXY}" != "1" ]]; then
    return
  fi
  log "Installing + configuring tinyproxy..."
  apt-get install -y tinyproxy
  sed -i "s/^#\?Port .*/Port ${TINYPROXY_PORT}/" /etc/tinyproxy/tinyproxy.conf
  sed -i "s/^#\?Listen .*/Listen ${TINYPROXY_LISTEN}/" /etc/tinyproxy/tinyproxy.conf
  systemctl restart tinyproxy
  systemctl enable tinyproxy
  TARGET_ADDRESS="127.0.0.1:${TINYPROXY_PORT}"
  log "tinyproxy ready; TARGET_ADDRESS set to ${TARGET_ADDRESS}"
}

find_bin() {
  local name="$1"
  local p="${INSTALL_DIR}/target/${CARGO_PROFILE}/${name}"
  if [[ -x "${p}" ]]; then
    echo "${p}"
    return
  fi
  # fallback search
  find "${INSTALL_DIR}/target" -maxdepth 3 -type f -name "${name}" -perm -111 | head -n 1
}

main() {
  need_root

  [[ "${ROLE}" == "client" || "${ROLE}" == "server" ]] 

  install_deps_common
  install_rustup
  clone_or_update_repo
  build_binaries
  gen_cert

  if [[ "${ROLE}" == "server" ]]; then
    install_tinyproxy_if_needed
  fi

  maybe_adjust_dns

  local client_bin server_bin
  client_bin="$(find_bin slipstream-client || true)"
  server_bin="$(find_bin slipstream-server || true)"

  [[ -x "${client_bin}" ]] || die "Could not find built slipstream-client"
  [[ -x "${server_bin}" ]] || die "Could not find built slipstream-server"

  log "Install complete."
  echo

  if [[ "${ROLE}" == "client" ]]; then
    echo "Run client:"
    echo "  ${client_bin} --tcp-listen-port ${TCP_LISTEN_PORT} --resolver ${RESOLVER_ADDR} --domain ${DOMAIN}"
    echo
    echo "Your tunnel/ssh example:"
    echo "  ssh -L 0.0.0.0:1080:localhost:${TCP_LISTEN_PORT} root@<CLIENT_IP>"
    echo "  ssh -p ${TCP_LISTEN_PORT} user@127.0.0.1"
  else
    echo "Run server:"
    echo "  ${server_bin} --dns-listen-port ${DNS_LISTEN_PORT} --target-address ${TARGET_ADDRESS} --domain ${DOMAIN} --cert ${INSTALL_DIR}/cert.pem --key ${INSTALL_DIR}/key.pem"
    echo
    echo "Note: binding to DNS port 53 requires root (or CAP_NET_BIND_SERVICE)."
  fi
}

main "$@"

