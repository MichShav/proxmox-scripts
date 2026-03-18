#!/usr/bin/env bash

# ============================================================
# Strix LXC Installer for Proxmox VE
# https://github.com/MichShav/proxmox-scripts
# Source app: https://github.com/eduard256/Strix
# ============================================================

set -euo pipefail

# ── Colours ─────────────────────────────────────────────────

YW="\033[33m" GN="\033[1;92m" RD="\033[01;31m"
BL="\033[36m" CL="\033[m"    BOLD="\033[1m"
info()    { echo -e "${BL}[INFO]${CL}  $*"; }
ok()      { echo -e "${GN}[OK]${CL}    $*"; }
warn()    { echo -e "${YW}[WARN]${CL}  $*"; }
err()     { echo -e "${RD}[ERROR]${CL} $*" >&2; exit 1; }

# ── Defaults (edit if you want different values) ─────────────

CT_ID=""                     # leave blank = next available
HOSTNAME="strix"
DISK_SIZE="4"                # GB
RAM="512"                    # MB
CPU="1"
BRIDGE="vmbr0"
OS_TEMPLATE=""               # leave blank = auto-download latest Debian 12
STORAGE="local-lvm"          # change to your preferred storage
UNPRIVILEGED=1
PORT=4567

INSTALL_URL="https://raw.githubusercontent.com/MichShav/proxmox-scripts/main/ct/strix-install.sh"

# ── Checks ───────────────────────────────────────────────────

[[ "$(id -u)" -ne 0 ]] && err "Run this script as root on the Proxmox host."
command -v pct &>/dev/null   || err "pct not found — is this a Proxmox VE host?"
command -v pvesh &>/dev/null || err "pvesh not found — is this a Proxmox VE host?"

echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════╗"
echo "  ║   Strix LXC Installer for Proxmox    ║"
echo "  ╚══════════════════════════════════════╝"
echo -e "${CL}"

# ── Pick next free CT ID ─────────────────────────────────────

if [[ -z "$CT_ID" ]]; then
  CT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "")
  [[ -z "$CT_ID" ]] && CT_ID=$(( $(pct list | awk 'NR>1 {print $1}' | sort -n | tail -1) + 1 ))
fi
info "Using CT ID: ${CT_ID}"

# ── Find / download Debian 12 template ──────────────────────

if [[ -z "$OS_TEMPLATE" ]]; then
  info "Looking for Debian 12 template…"
  OS_TEMPLATE=$(pveam list "$STORAGE" 2>/dev/null \
    | awk '/debian-12/{print $1}' | tail -1 || true)

  if [[ -z "$OS_TEMPLATE" ]]; then
    info "Downloading latest Debian 12 template…"
    pveam update &>/dev/null
    TEMPLATE_NAME=$(pveam available --section system \
      | awk '/debian-12-standard/{print $2}' | tail -1)
    [[ -z "$TEMPLATE_NAME" ]] && err "Could not find a Debian 12 template to download."
    pveam download "$STORAGE" "$TEMPLATE_NAME" &>/dev/null
    OS_TEMPLATE="${STORAGE}:vztmpl/${TEMPLATE_NAME}"
  fi
fi
ok "Template: ${OS_TEMPLATE}"

# ── Create the LXC ───────────────────────────────────────────

info "Creating LXC container ${CT_ID} (${HOSTNAME})…"
pct create "$CT_ID" "$OS_TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CPU" \
  --memory "$RAM" \
  --rootfs "${STORAGE}:${DISK_SIZE}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged "$UNPRIVILEGED" \
  --features "nesting=1" \
  --start 1 \
  --onboot 1 \
  --description "Strix - IP Camera Stream Finder
https://github.com/eduard256/Strix" \
  &>/dev/null
ok "Container created and started."

# ── Wait for network ─────────────────────────────────────────

info "Waiting for container network…"
for i in $(seq 1 20); do
  IP=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
  [[ -n "$IP" ]] && break
  sleep 2
done
[[ -z "$IP" ]] && warn "Could not detect IP automatically — check your DHCP."

# ── Run the install script inside the container ──────────────

info "Running Strix install inside container…"
pct exec "$CT_ID" -- bash -c \
  "apt-get install -qq -y curl &>/dev/null && bash <(curl -fsSL ${INSTALL_URL})"

# ── Done ─────────────────────────────────────────────────────

echo ""
echo -e "${GN}${BOLD}  ✔ Strix installed successfully!${CL}"
echo -e "  ${BOLD}CT ID   :${CL} ${CT_ID}"
echo -e "  ${BOLD}Hostname:${CL} ${HOSTNAME}"
[[ -n "$IP" ]] && echo -e "  ${BOLD}Web UI  :${CL} ${BL}http://${IP}:${PORT}${CL}"
echo ""
warn "If you don't see the IP above, check: pct exec ${CT_ID} -- hostname -I"
echo ""
