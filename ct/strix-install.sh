#!/usr/bin/env bash

# ============================================================
# Strix Install Script (runs inside Debian 12 LXC)
# https://github.com/MichShav/proxmox-scripts
# ============================================================

set -euo pipefail

YW="\033[33m" GN="\033[1;92m" RD="\033[01;31m" BL="\033[36m" CL="\033[m" BOLD="\033[1m"
info() { echo -e "${BL}[INFO]${CL}  $*"; }
ok()   { echo -e "${GN}[OK]${CL}    $*"; }
err()  { echo -e "${RD}[ERROR]${CL} $*" >&2; exit 1; }

[[ "$(id -u)" -ne 0 ]] && err "Must run as root."

# ── Wait for network ──────────────────────────────────────────

info "Waiting for network…"
for i in {1..20}; do
  [[ -n "$(hostname -I 2>/dev/null)" ]] && break
  sleep 1
done
[[ -z "$(hostname -I 2>/dev/null)" ]] && err "No network after 20s."
ok "Network: $(hostname -I | awk '{print $1}')"

# Prevent slow boot from networkd-wait-online on future restarts
systemctl disable -q --now systemd-networkd-wait-online.service 2>/dev/null || true

# ── Update OS ────────────────────────────────────────────────

info "Updating OS…"
apt-get update -qq &>/dev/null
apt-get upgrade -qq -y &>/dev/null
ok "OS updated."

# ── Install dependencies ──────────────────────────────────────

info "Installing dependencies (ffmpeg, curl, tar)…"
apt-get install -qq -y curl ca-certificates ffmpeg tar &>/dev/null
ok "Dependencies installed."

# ── Get latest Strix release ──────────────────────────────────

info "Fetching latest Strix release…"
RELEASE=$(curl -fsSL https://api.github.com/repos/eduard256/Strix/releases \
  | awk -F'"' '/tag_name/{tag=$4} /browser_download_url/{print tag; exit}')
[[ -z "$RELEASE" ]] && err "Could not determine latest Strix release."
ok "Latest release: ${RELEASE}"

# ── Detect architecture ───────────────────────────────────────

ARCH=$(dpkg --print-architecture)
case "$ARCH" in
  amd64) ARCH_STR="x86_64" ;;
  arm64) ARCH_STR="arm64" ;;
  *)     err "Unsupported architecture: ${ARCH}" ;;
esac

# ── Download & install binary ─────────────────────────────────

info "Downloading Strix ${RELEASE} (${ARCH})…"
DOWNLOAD_URL="https://github.com/eduard256/Strix/releases/download/${RELEASE}/Strix_${RELEASE#v}_linux_${ARCH_STR}.tar.gz"
curl -fsSL "$DOWNLOAD_URL" -o /tmp/strix.tar.gz \
  || err "Download failed. Check: ${DOWNLOAD_URL}"

tar -xzf /tmp/strix.tar.gz -C /tmp
mv /tmp/strix /usr/local/bin/strix
chmod +x /usr/local/bin/strix
rm -f /tmp/strix.tar.gz
echo "$RELEASE" > /opt/strix_version.txt
ok "Strix binary installed at /usr/local/bin/strix"

# ── Create config ─────────────────────────────────────────────

info "Creating config…"
mkdir -p /opt/strix
cat <<'EOF' > /opt/strix/strix.yaml
api:
  listen: ":4567"
EOF
ok "Config written to /opt/strix/strix.yaml"

# ── Create systemd service ────────────────────────────────────

info "Creating systemd service…"
cat <<'EOF' > /etc/systemd/system/strix.service
[Unit]
Description=Strix - IP Camera Stream Finder
Documentation=https://github.com/eduard256/Strix
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/strix
ExecStart=/usr/local/bin/strix
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q strix
systemctl start strix
ok "Strix service enabled and started."

# ── Update script ─────────────────────────────────────────────

info "Installing update helper to /usr/local/bin/strix-update…"
cat <<'UPDATESCRIPT' > /usr/local/bin/strix-update
#!/usr/bin/env bash
set -euo pipefail
CURRENT=$(cat /opt/strix_version.txt 2>/dev/null || echo "unknown")
RELEASE=$(curl -fsSL https://api.github.com/repos/eduard256/Strix/releases \
  | awk -F'"' '/tag_name/{tag=$4} /browser_download_url/{print tag; exit}')
if [[ "$RELEASE" == "$CURRENT" ]]; then
  echo "Already up to date: ${CURRENT}"
  exit 0
fi
echo "Updating Strix: ${CURRENT} → ${RELEASE}"
ARCH=$(dpkg --print-architecture)
[[ "$ARCH" == "amd64" ]] && ARCH_STR="x86_64" || ARCH_STR="arm64"
systemctl stop strix
curl -fsSL "https://github.com/eduard256/Strix/releases/download/${RELEASE}/Strix_${RELEASE#v}_linux_${ARCH_STR}.tar.gz" \
  | tar -xzf - -C /tmp
mv /tmp/strix /usr/local/bin/strix
chmod +x /usr/local/bin/strix
echo "$RELEASE" > /opt/strix_version.txt
systemctl start strix
echo "Updated to ${RELEASE} successfully."
UPDATESCRIPT
chmod +x /usr/local/bin/strix-update
ok "Update helper installed. Run: strix-update"

# ── Cleanup ───────────────────────────────────────────────────

info "Cleaning up…"
apt-get autoremove -qq -y &>/dev/null
apt-get autoclean -qq &>/dev/null
ok "Done."

# ── Summary ───────────────────────────────────────────────────

IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GN}${BOLD}  ✔ Strix is running!${CL}"
echo -e "  ${BOLD}Web UI :${CL} ${BL}http://${IP}:4567${CL}"
echo -e "  ${BOLD}Logs   :${CL} journalctl -u strix -f"
echo -e "  ${BOLD}Update :${CL} strix-update"
echo -e "  ${BOLD}Config :${CL} /opt/strix/strix.yaml"
echo ""
