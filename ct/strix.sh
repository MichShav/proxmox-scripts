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
info()  { echo -e "${BL}[INFO]${CL}  $*"; }
ok()    { echo -e "${GN}[OK]${CL}    $*"; }
warn()  { echo -e "${YW}[WARN]${CL}  $*"; }
err()   { echo -e "${RD}[ERROR]${CL} $*" >&2; exit 1; }

# ── Defaults ─────────────────────────────────────────────────

CT_ID=""             # leave blank = next available
HOSTNAME="strix"
DISK_SIZE="4"        # GB
RAM="512"            # MB
CPU="1"
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"      # must support vztmpl (always 'local' on default Proxmox)
STORAGE="local-lvm"           # container rootfs storage
UNPRIVILEGED=1
PORT=4567

INSTALL_URL="https://raw.githubusercontent.com/MichShav/proxmox-scripts/main/ct/strix-install.sh"

# ── Cleanup trap ─────────────────────────────────────────────

cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 && -n "${CT_ID:-}" ]]; then
    if pct list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$CT_ID"; then
      warn "Install failed — destroying container ${CT_ID}…"
      pct stop "$CT_ID" &>/dev/null || true
      pct destroy "$CT_ID" &>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

# ── Checks ───────────────────────────────────────────────────

[[ "$(id -u)" -ne 0 ]]       && err "Run this script as root on the Proxmox host."
command -v pct    &>/dev/null || err "pct not found — is this a Proxmox VE host?"
command -v pvesh  &>/dev/null || err "pvesh not found — is this a Proxmox VE host?"
command -v pveam  &>/dev/null || err "pveam not found — is this a Proxmox VE host?"

echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════╗"
echo "  ║   Strix LXC Installer for Proxmox   ║"
echo "  ╚══════════════════════════════════════╝"
echo -e "${CL}"

# ── Pick next free CT ID ─────────────────────────────────────

if [[ -z "$CT_ID" ]]; then
  CT_ID=$(pvesh get /cluster/nextid 2>/dev/null || true)
  if [[ -z "$CT_ID" ]]; then
    CT_ID=$(( $(pct list | awk 'NR>1{print $1}' | sort -n | tail -1) + 1 ))
  fi
fi
[[ -z "$CT_ID" ]] && err "Could not determine a free CT ID."
info "Using CT ID: ${CT_ID}"

# ── Find / download Debian 12 template ───────────────────────

if [[ -z "${OS_TEMPLATE:-}" ]]; then
  info "Looking for Debian 12 template on ${TEMPLATE_STORAGE}…"
  TEMPLATE_NAME=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null \
    | awk '/debian-12-standard/{print $1}' | tail -1 || true)

  if [[ -z "$TEMPLATE_NAME" ]]; then
    info "Downloading latest Debian 12 template…"
    pveam update &>/dev/null
    TEMPLATE_NAME=$(pveam available --section system \
      | awk '/debian-12-standard/{print $2}' | tail -1)
    [[ -z "$TEMPLATE_NAME" ]] && err "Could not find a Debian 12 template."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" \
      || err "Template download failed."
    TEMPLATE_NAME="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
  fi
  OS_TEMPLATE="$TEMPLATE_NAME"
fi
ok "Template: ${OS_TEMPLATE}"

# ── Create the LXC ───────────────────────────────────────────

info "Creating LXC container ${CT_ID} (${HOSTNAME})…"
if ! pct create "$CT_ID" "$OS_TEMPLATE" \
    --hostname     "$HOSTNAME" \
    --cores        "$CPU" \
    --memory       "$RAM" \
    --rootfs       "${STORAGE}:${DISK_SIZE}" \
    --net0         "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --nameserver   "1.1.1.1" \
    --unprivileged "$UNPRIVILEGED" \
    --features     "nesting=1,keyctl=1" \
    --onboot       1 \
    --description  "Strix - IP Camera Stream Finder
https://github.com/eduard256/Strix" 2>&1; then
  err "pct create failed. Check storage names and available disk space."
fi

# Verify it actually exists
pct list | awk 'NR>1{print $1}' | grep -qx "$CT_ID" \
  || err "Container ${CT_ID} not found after creation."
ok "Container ${CT_ID} created."

# ── Start and wait for running state ─────────────────────────

info "Starting container…"
pct start "$CT_ID"

for i in {1..15}; do
  if pct status "$CT_ID" 2>/dev/null | grep -q "status: running"; then
    ok "Container is running."
    break
  fi
  sleep 1
  [[ $i -eq 15 ]] && err "Container did not reach running state after 15s."
done

# ── Wait for network ─────────────────────────────────────────

info "Waiting for network…"
IP=""
for i in {1..20}; do
  IP=$(pct exec "$CT_ID" -- ip -4 addr show eth0 2>/dev/null \
    | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 || true)
  [[ -n "$IP" ]] && break
  sleep 2
done
[[ -z "$IP" ]] && err "No IP assigned to container after 40s — check DHCP on ${BRIDGE}."
ok "Container IP: ${IP}"

# ── Verify connectivity ───────────────────────────────────────

info "Testing connectivity…"
connected=false
for host in 1.1.1.1 8.8.8.8 9.9.9.9; do
  if pct exec "$CT_ID" -- ping -c1 -W2 "$host" &>/dev/null; then
    connected=true
    break
  fi
done
$connected || err "Container has an IP but cannot reach the internet. Check bridge/gateway config."
ok "Internet reachable."

# ── Run the install script inside the container ───────────────

info "Running Strix install inside container…"
lxc-attach -n "$CT_ID" -- bash -c \
  "apt-get update -qq && apt-get install -qq -y curl && bash <(curl -fsSL ${INSTALL_URL})" \
  || err "Install script failed. Run: journalctl -u strix -n 50 inside the container."

# ── Done ─────────────────────────────────────────────────────

echo ""
echo -e "${GN}${BOLD}  ✔ Strix installed successfully!${CL}"
echo -e "  ${BOLD}CT ID   :${CL} ${CT_ID}"
echo -e "  ${BOLD}Hostname:${CL} ${HOSTNAME}"
echo -e "  ${BOLD}Web UI  :${CL} ${BL}http://${IP}:${PORT}${CL}"
echo -e "  ${BOLD}Logs    :${CL} pct exec ${CT_ID} -- journalctl -u strix -f"
echo -e "  ${BOLD}Update  :${CL} pct exec ${CT_ID} -- strix-update"
echo ""
