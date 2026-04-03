#!/usr/bin/env bash

# ============================================================
# Strix LXC Installer for Proxmox VE
# https://github.com/MichShav/proxmox-scripts
# Source app: https://github.com/eduard256/Strix
# ============================================================

set -euo pipefail

# ── Colours & helpers ────────────────────────────────────────

YW="\033[33m" GN="\033[1;92m" RD="\033[01;31m"
BL="\033[36m" CL="\033[m"    BOLD="\033[1m"
info()  { echo -e "${BL}[INFO]${CL}  $*"; }
ok()    { echo -e "${GN}[OK]${CL}    $*"; }
warn()  { echo -e "${YW}[WARN]${CL}  $*"; }
err()   { echo -e "${RD}[ERROR]${CL} $*" >&2; exit 1; }

# ── App defaults ─────────────────────────────────────────────

APP="Strix"
HOSTNAME="strix"
DISK_SIZE="4"
RAM="512"
CPU="1"
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
STORAGE="local-lvm"
NET="dhcp"
GW=""
UNPRIVILEGED=1
PORT=4567

INSTALL_URL="https://raw.githubusercontent.com/MichShav/proxmox-scripts/main/ct/strix-install.sh"

# ── Cleanup trap ─────────────────────────────────────────────

cleanup() {
  local rc=$?
  if [[ $rc -ne 0 && -n "${CT_ID:-}" ]]; then
    if pct list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$CT_ID"; then
      warn "Install failed — destroying container ${CT_ID}…"
      pct stop "$CT_ID" &>/dev/null || true
      pct destroy "$CT_ID" &>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

# ── Host checks ───────────────────────────────────────────────

[[ "$(id -u)" -ne 0 ]]          && err "Run as root on the Proxmox host."
command -v pct      &>/dev/null  || err "pct not found — is this a Proxmox VE host?"
command -v pvesh    &>/dev/null  || err "pvesh not found — is this a Proxmox VE host?"
command -v pveam    &>/dev/null  || err "pveam not found."
command -v whiptail &>/dev/null  || err "whiptail not found."
command -v lxc-attach &>/dev/null || err "lxc-attach not found — install lxc: apt-get install lxc"

# ── Header ────────────────────────────────────────────────────

clear
echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════╗"
echo "  ║   Strix LXC Installer for Proxmox   ║"
echo "  ╚══════════════════════════════════════╝"
echo -e "${CL}"

# ── Next available CT ID ──────────────────────────────────────

CT_ID=$(pvesh get /cluster/nextid 2>/dev/null || true)
[[ -z "$CT_ID" ]] && \
  CT_ID=$(( $(pct list | awk 'NR>1{print $1}' | sort -n | tail -1) + 1 ))
[[ -z "$CT_ID" ]] && err "Could not determine a free CT ID."

# ── Setup mode ────────────────────────────────────────────────

MODE=$(whiptail --backtitle "Strix LXC Installer" \
  --title "Setup Mode" \
  --menu "\nChoose how to proceed:" 13 55 2 \
  "1" "Default  — install with recommended settings" \
  "2" "Advanced — customise each setting" \
  3>&1 1>&2 2>&3) || err "Cancelled."

if [[ "$MODE" == "2" ]]; then

  # ── CT ID ──────────────────────────────────────────────────
  CT_ID=$(whiptail --backtitle "Strix LXC Installer" \
    --title "Container ID" \
    --inputbox "Container ID:" 8 40 "$CT_ID" \
    3>&1 1>&2 2>&3) || err "Cancelled."
  [[ "$CT_ID" =~ ^[0-9]+$ ]] || err "CT ID must be a number."

  # Check ID is not already in use cluster-wide
  if pvesh get /cluster/resources --type vm 2>/dev/null \
      | grep -qE "\"vmid\":\s*${CT_ID}[^0-9]"; then
    err "CT ID ${CT_ID} is already in use on this cluster."
  fi

  # ── Hostname ───────────────────────────────────────────────
  HOSTNAME=$(whiptail --backtitle "Strix LXC Installer" \
    --title "Hostname" \
    --inputbox "Container hostname:" 8 40 "$HOSTNAME" \
    3>&1 1>&2 2>&3) || err "Cancelled."

  # ── Disk ───────────────────────────────────────────────────
  DISK_SIZE=$(whiptail --backtitle "Strix LXC Installer" \
    --title "Disk Size" \
    --inputbox "Disk size in GB:" 8 40 "$DISK_SIZE" \
    3>&1 1>&2 2>&3) || err "Cancelled."
  [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] || err "Disk size must be a number."

  # ── CPU ────────────────────────────────────────────────────
  CPU=$(whiptail --backtitle "Strix LXC Installer" \
    --title "CPU Cores" \
    --inputbox "Number of CPU cores:" 8 40 "$CPU" \
    3>&1 1>&2 2>&3) || err "Cancelled."
  [[ "$CPU" =~ ^[0-9]+$ ]] || err "CPU cores must be a number."

  # ── RAM ────────────────────────────────────────────────────
  RAM=$(whiptail --backtitle "Strix LXC Installer" \
    --title "RAM" \
    --inputbox "RAM in MB:" 8 40 "$RAM" \
    3>&1 1>&2 2>&3) || err "Cancelled."
  [[ "$RAM" =~ ^[0-9]+$ ]] || err "RAM must be a number."

  # ── Container storage ──────────────────────────────────────
  # List active storages that support container rootfs (lvmthin, lvm, dir, nfs, cifs)
  mapfile -t _STOR_LINES < <(pvesm status --content rootdir 2>/dev/null \
    | awk 'NR>1 && $3=="active" {printf "%s\t%d GB free\n", $1, int($6/1024/1024/1024)}' \
    | sort)

  if [[ ${#_STOR_LINES[@]} -eq 0 ]]; then
    warn "No rootfs-capable storage detected, keeping default: ${STORAGE}"
  elif [[ ${#_STOR_LINES[@]} -eq 1 ]]; then
    STORAGE=$(echo "${_STOR_LINES[0]}" | cut -f1)
  else
    _STOR_OPTS=()
    for _line in "${_STOR_LINES[@]}"; do
      _name=$(echo "$_line" | cut -f1)
      _free=$(echo "$_line" | cut -f2)
      _STOR_OPTS+=("$_name" "$_free")
    done
    STORAGE=$(whiptail --backtitle "Strix LXC Installer" \
      --title "Container Storage" \
      --menu "Select storage for container rootfs:" 15 55 6 \
      "${_STOR_OPTS[@]}" \
      3>&1 1>&2 2>&3) || err "Cancelled."
  fi

  # ── Network bridge ─────────────────────────────────────────
  mapfile -t _BRIDGES < <(find /sys/class/net/*/bridge -maxdepth 0 2>/dev/null \
    | sed 's|/sys/class/net/||;s|/bridge||' | sort)

  if [[ ${#_BRIDGES[@]} -gt 1 ]]; then
    _BR_OPTS=()
    for _br in "${_BRIDGES[@]}"; do
      _BR_OPTS+=("$_br" "")
    done
    BRIDGE=$(whiptail --backtitle "Strix LXC Installer" \
      --title "Network Bridge" \
      --menu "Select bridge interface:" 15 45 6 \
      "${_BR_OPTS[@]}" \
      3>&1 1>&2 2>&3) || err "Cancelled."
  fi

  # ── IPv4 ───────────────────────────────────────────────────
  if whiptail --backtitle "Strix LXC Installer" \
    --title "IPv4 Configuration" \
    --yesno "Use DHCP for IPv4?" 8 45; then
    NET="dhcp"
    GW=""
  else
    NET=$(whiptail --backtitle "Strix LXC Installer" \
      --title "Static IPv4" \
      --inputbox "IP address with CIDR prefix:\n(e.g. 192.168.1.100/24)" 9 50 "" \
      3>&1 1>&2 2>&3) || err "Cancelled."
    GW=$(whiptail --backtitle "Strix LXC Installer" \
      --title "Gateway" \
      --inputbox "Gateway IP address:" 8 50 "" \
      3>&1 1>&2 2>&3) || err "Cancelled."
  fi

fi  # end advanced

# ── Confirm ───────────────────────────────────────────────────

NET_DISPLAY="$NET"
[[ "$NET" != "dhcp" ]] && NET_DISPLAY="${NET} via ${GW:-<no gateway>}"

whiptail --backtitle "Strix LXC Installer" \
  --title "Confirm Settings" \
  --yesno \
"  Container ID : ${CT_ID}
  Hostname     : ${HOSTNAME}
  CPU          : ${CPU} core(s)
  RAM          : ${RAM} MB
  Disk         : ${DISK_SIZE} GB on ${STORAGE}
  Bridge       : ${BRIDGE}
  IPv4         : ${NET_DISPLAY}
  Port         : ${PORT}

  Proceed?" \
  19 55 || err "Cancelled."

# ── Find / download Debian 12 template ───────────────────────

info "Looking for Debian 12 template on ${TEMPLATE_STORAGE}…"
TEMPLATE_NAME=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null \
  | awk '/debian-12-standard/{print $1}' | tail -1 || true)

if [[ -z "$TEMPLATE_NAME" ]]; then
  info "Downloading latest Debian 12 template…"
  pveam update &>/dev/null
  TEMPLATE_DL=$(pveam available --section system \
    | awk '/debian-12-standard/{print $2}' | tail -1)
  [[ -z "$TEMPLATE_DL" ]] && err "Could not find a Debian 12 template."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_DL" \
    || err "Template download failed."
  TEMPLATE_NAME="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_DL}"
fi
ok "Template: ${TEMPLATE_NAME}"

# ── Build net0 option ─────────────────────────────────────────

NET0="name=eth0,bridge=${BRIDGE},ip=${NET}"
[[ -n "${GW:-}" ]] && NET0="${NET0},gw=${GW}"

# ── Create the LXC ───────────────────────────────────────────

info "Creating LXC container ${CT_ID} (${HOSTNAME})…"
if ! pct create "$CT_ID" "$TEMPLATE_NAME" \
    --hostname     "$HOSTNAME" \
    --cores        "$CPU" \
    --memory       "$RAM" \
    --rootfs       "${STORAGE}:${DISK_SIZE}" \
    --net0         "$NET0" \
    --nameserver   "1.1.1.1" \
    --unprivileged "$UNPRIVILEGED" \
    --features     "nesting=1,keyctl=1" \
    --onboot       1 \
    --description  "Strix - IP Camera Stream Finder
https://github.com/eduard256/Strix"; then
  err "pct create failed — check storage names and available disk space."
fi

pct list | awk 'NR>1{print $1}' | grep -qx "$CT_ID" \
  || err "Container ${CT_ID} not found after creation."
ok "Container ${CT_ID} created."

# ── Start & wait for running ──────────────────────────────────

info "Starting container…"
pct start "$CT_ID"

for i in {1..20}; do
  pct status "$CT_ID" 2>/dev/null | grep -q "status: running" && break
  sleep 1
  [[ $i -eq 20 ]] && err "Container did not reach running state after 20s."
done
ok "Container running."

# ── Wait for IP ───────────────────────────────────────────────

info "Waiting for network…"
IP=""
for i in {1..30}; do
  IP=$(pct exec "$CT_ID" -- ip -4 addr show eth0 2>/dev/null \
    | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 || true)
  [[ -n "$IP" ]] && break
  sleep 2
done
[[ -z "$IP" ]] && err "No IP assigned after 60s — check DHCP on bridge ${BRIDGE}."
ok "Container IP: ${IP}"

# ── Connectivity test ─────────────────────────────────────────

info "Testing internet connectivity…"
CONNECTED=false
for host in 1.1.1.1 8.8.8.8 9.9.9.9; do
  pct exec "$CT_ID" -- ping -c1 -W2 "$host" &>/dev/null && { CONNECTED=true; break; }
done
$CONNECTED || err "Container has an IP but cannot reach the internet. Check bridge/gateway config."
ok "Internet reachable."

# ── Run install inside container ──────────────────────────────

info "Running Strix install inside container…"
lxc-attach -n "$CT_ID" -- bash -c \
  "apt-get update -qq && apt-get install -qq -y curl && bash <(curl -fsSL ${INSTALL_URL})" \
  || err "Install failed. Run: pct exec ${CT_ID} -- journalctl -u strix -n 50"

# ── Done ─────────────────────────────────────────────────────

echo ""
echo -e "${GN}${BOLD}  ✔ Strix installed successfully!${CL}"
echo -e "  ${BOLD}CT ID   :${CL} ${CT_ID}"
echo -e "  ${BOLD}Hostname:${CL} ${HOSTNAME}"
echo -e "  ${BOLD}Web UI  :${CL} ${BL}http://${IP}:${PORT}${CL}"
echo -e "  ${BOLD}Logs    :${CL} pct exec ${CT_ID} -- journalctl -u strix -f"
echo -e "  ${BOLD}Update  :${CL} pct exec ${CT_ID} -- strix-update"
echo ""
