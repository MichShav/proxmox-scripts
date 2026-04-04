#!/usr/bin/env bash

# ============================================================
# Strix Install Script (runs inside Debian 12 LXC)
# https://github.com/MichShav/proxmox-scripts
# Source app: https://github.com/eduard256/Strix
#
# Installs Strix via Docker (the officially supported method).
# ============================================================

set -euo pipefail

YW="\033[33m" GN="\033[1;92m" RD="\033[01;31m" BL="\033[36m" CL="\033[m" BOLD="\033[1m"
info() { echo -e "${BL}[INFO]${CL}  $*"; }
ok()   { echo -e "${GN}[OK]${CL}    $*"; }
warn() { echo -e "${YW}[WARN]${CL}  $*"; }
err()  { echo -e "${RD}[ERROR]${CL} $*" >&2; exit 1; }

[[ "$(id -u)" -ne 0 ]] && err "Must run as root."

DOCKER_IMAGE="eduard256/strix:latest"
CONTAINER_NAME="strix"
STRIX_PORT=4567

# ── Wait for network ──────────────────────────────────────────

info "Waiting for network…"
for i in {1..30}; do
  [[ -n "$(hostname -I 2>/dev/null)" ]] && break
  sleep 1
done
[[ -z "$(hostname -I 2>/dev/null)" ]] && err "No network after 30s."
ok "Network: $(hostname -I | awk '{print $1}')"

# ── Test DNS resolution ──────────────────────────────────────

info "Testing DNS resolution…"
for i in {1..10}; do
  if getent hosts docker.com &>/dev/null 2>&1 || \
     ping -c1 -W2 1.1.1.1 &>/dev/null; then
    break
  fi
  sleep 2
  [[ $i -eq 10 ]] && err "DNS resolution failed. Check nameserver config."
done
ok "DNS working."

# Prevent slow boot from networkd-wait-online on future restarts
systemctl disable -q --now systemd-networkd-wait-online.service 2>/dev/null || true

# ── Update OS ────────────────────────────────────────────────

info "Updating OS…"
apt-get update -qq &>/dev/null
apt-get upgrade -qq -y &>/dev/null
ok "OS updated."

# ── Install Docker ────────────────────────────────────────────

if command -v docker &>/dev/null; then
  ok "Docker already installed."
else
  info "Installing Docker (this may take a minute)…"
  apt-get install -qq -y ca-certificates curl &>/dev/null

  # Install Docker using official convenience script
  curl -fsSL https://get.docker.com | sh &>/dev/null 2>&1 \
    || err "Docker install failed. Check disk space: df -h"

  # Wait for Docker daemon to be ready
  for i in {1..15}; do
    docker info &>/dev/null 2>&1 && break
    sleep 2
    [[ $i -eq 15 ]] && err "Docker daemon failed to start. Check: systemctl status docker"
  done
  ok "Docker installed and running."
fi

# ── Verify Docker is working ─────────────────────────────────

docker info &>/dev/null 2>&1 || err "Docker daemon is not running. Check: systemctl status docker"

# ── Check disk space before pulling ──────────────────────────

AVAIL_MB=$(df -m / | awk 'NR==2{print $4}')
if [[ "${AVAIL_MB:-0}" -lt 500 ]]; then
  warn "Low disk space: ${AVAIL_MB}MB available. Docker image needs ~200MB."
  warn "Consider resizing: pct resize <CT_ID> rootfs +4G"
fi

# ── Pull and run Strix ────────────────────────────────────────

info "Pulling Strix Docker image…"
if ! docker pull "$DOCKER_IMAGE"; then
  err "Failed to pull ${DOCKER_IMAGE}. Check internet connectivity."
fi
ok "Strix image pulled."

# Stop and remove existing container if present
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  info "Removing existing Strix container…"
  docker stop "$CONTAINER_NAME" &>/dev/null || true
  docker rm "$CONTAINER_NAME" &>/dev/null || true
fi

info "Starting Strix container…"
docker run -d \
  --name "$CONTAINER_NAME" \
  --network host \
  --restart unless-stopped \
  "$DOCKER_IMAGE" \
  || err "Failed to start Strix container."

# ── Verify Strix is responding ────────────────────────────────

info "Waiting for Strix to start…"
for i in {1..15}; do
  if curl -sf "http://localhost:${STRIX_PORT}" &>/dev/null || \
     curl -sf "http://localhost:${STRIX_PORT}/api/v1/health" &>/dev/null; then
    break
  fi
  sleep 2
  [[ $i -eq 15 ]] && warn "Strix not responding yet — container may still be starting."
done

# Quick check that the container is still running
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  ok "Strix container is running."
else
  docker logs "$CONTAINER_NAME" 2>&1 | tail -5
  err "Strix container exited. Check logs above."
fi

# ── Save version info ─────────────────────────────────────────

STRIX_VERSION=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
echo "$STRIX_VERSION" > /opt/strix_version.txt

# ── Create update helper ──────────────────────────────────────

info "Installing update helper…"
cat <<'UPDATESCRIPT' > /usr/local/bin/strix-update
#!/usr/bin/env bash
set -euo pipefail

IMAGE="eduard256/strix:latest"
NAME="strix"

echo "Pulling latest Strix image…"
docker pull "$IMAGE"

RUNNING_ID=$(docker inspect --format='{{.Image}}' "$NAME" 2>/dev/null || echo "")
LATEST_ID=$(docker inspect --format='{{.Id}}' "$IMAGE" 2>/dev/null || echo "")

if [[ "$RUNNING_ID" == "$LATEST_ID" && -n "$RUNNING_ID" ]]; then
  echo "Already running the latest version."
  exit 0
fi

echo "Updating Strix container…"
docker stop "$NAME" 2>/dev/null || true
docker rm "$NAME" 2>/dev/null || true
docker run -d \
  --name "$NAME" \
  --network host \
  --restart unless-stopped \
  "$IMAGE"

# Clean up old images
docker image prune -f &>/dev/null || true

echo "Strix updated successfully."
docker logs --tail 5 "$NAME"
UPDATESCRIPT
chmod +x /usr/local/bin/strix-update
ok "Update helper installed. Run: strix-update"

# ── Enable Docker on boot ─────────────────────────────────────

systemctl enable docker &>/dev/null || true

# ── Cleanup ───────────────────────────────────────────────────

info "Cleaning up…"
apt-get autoremove -qq -y &>/dev/null
apt-get autoclean -qq &>/dev/null
ok "Done."

# ── Summary ───────────────────────────────────────────────────

IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GN}${BOLD}  ✔ Strix is running!${CL}"
echo -e "  ${BOLD}Web UI :${CL} ${BL}http://${IP}:${STRIX_PORT}${CL}"
echo -e "  ${BOLD}Logs   :${CL} docker logs -f strix"
echo -e "  ${BOLD}Update :${CL} strix-update"
echo -e "  ${BOLD}Stop   :${CL} docker stop strix"
echo -e "  ${BOLD}Start  :${CL} docker start strix"
echo ""
