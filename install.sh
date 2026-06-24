#!/usr/bin/env bash
#
# Service Management System — one-command installer for a headless Linux server.
#
#   curl -fsSL https://davidpeele.github.io/sms-download-page/install.sh | sudo bash
#
# Works on 64-bit Ubuntu/Debian/Raspberry Pi OS (amd64 or arm64). Installs Docker
# if needed, drops a compose file under /opt/sms with a host-visible data dir, and
# starts SMS on port 8347. Re-running it updates to the latest image.
#
set -euo pipefail

IMAGE="davidpeele/service-management-system:latest"
APP_DIR="/opt/sms"
DATA_DIR="${APP_DIR}/data"
PORT=8347

say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mError:\033[0m %s\n\n' "$*" >&2; exit 1; }

# ── 1. Root + platform checks ────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "Please run as root (use: sudo bash) — it needs to install Docker and write to ${APP_DIR}."

case "$(uname -s)" in
  Linux) : ;;
  *) die "This installer is for Linux. On macOS/Windows use the desktop installer instead." ;;
esac

case "$(uname -m)" in
  x86_64|amd64)        ARCH="amd64" ;;
  aarch64|arm64)       ARCH="arm64" ;;
  armv7l|armhf|i386|i686)
    die "A 64-bit OS is required. This looks like 32-bit ($(uname -m)). On a Raspberry Pi, install the 64-bit Raspberry Pi OS." ;;
  *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac
say "Service Management System installer — Linux/${ARCH}"

# ── 2. Docker Engine + compose plugin ────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
  ok "Docker already installed ($(docker --version | awk '{print $3}' | tr -d ,))"
else
  say "Installing Docker Engine…"
  curl -fsSL https://get.docker.com | sh || die "Docker installation failed. Install Docker manually, then re-run this script."
  ok "Docker installed"
fi

systemctl enable --now docker >/dev/null 2>&1 || true

if ! docker compose version >/dev/null 2>&1; then
  say "Installing the Docker Compose plugin…"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq docker-compose-plugin \
      || die "Could not install docker-compose-plugin. Install it manually, then re-run."
  else
    die "Docker Compose plugin missing and apt not available — install 'docker compose' manually, then re-run."
  fi
fi
ok "Docker Compose ready ($(docker compose version --short 2>/dev/null || echo ok))"

# ── 3. Lay down the app directory + compose file ─────────────────────────────
say "Setting up ${APP_DIR}…"
mkdir -p "${DATA_DIR}/backups"
chown -R 1000:1000 "${DATA_DIR}"

# GID that owns the Docker socket — added to the (non-root) app user via group_add
# so the in-app "Update now" can reach the socket.
DOCKER_GID="$(stat -c %g /var/run/docker.sock 2>/dev/null || getent group docker 2>/dev/null | awk -F: '{print $3}')"

# The Docker socket is mounted so the in-app "Update now" can pull and recreate the
# container without SSH. Data + backups live on the host under ${DATA_DIR} so
# they're easy to back up and survive image updates.
cat > "${APP_DIR}/docker-compose.yml" <<EOF
name: sms

services:
  sms:
    image: ${IMAGE}
    container_name: sms_app
    ports:
      - "${PORT}:${PORT}"
    volumes:
      - ${DATA_DIR}:/app/data
      - /var/run/docker.sock:/var/run/docker.sock
    group_add:
      - "${DOCKER_GID}"
    restart: unless-stopped
    labels:
      - com.centurylinklabs.watchtower.enable=true
EOF
ok "Wrote ${APP_DIR}/docker-compose.yml"

# ── 4. Pull + start ──────────────────────────────────────────────────────────
say "Downloading the latest SMS image (${ARCH})…"
docker compose -f "${APP_DIR}/docker-compose.yml" pull
say "Starting SMS…"
docker compose -f "${APP_DIR}/docker-compose.yml" up -d

# ── 5. Wait for health + report the address ──────────────────────────────────
say "Waiting for SMS to come up…"
for i in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://localhost:${PORT}/login" 2>/dev/null; then break; fi
  sleep 2
done

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "${IP:-}" ] || IP="<this-server-ip>"

printf '\n\033[1;32m────────────────────────────────────────────────────────\033[0m\n'
cat <<EOF
 Service Management System is installed and running.

   Open it from any device on your network:

       http://${IP}:${PORT}

   On first run you'll enter your license key, then create
   your admin account.

 Useful commands:
   View logs:   docker logs -f sms_app
   Stop:        docker compose -f ${APP_DIR}/docker-compose.yml down
   Start:       docker compose -f ${APP_DIR}/docker-compose.yml up -d
   Update:      sudo bash -c 'cd ${APP_DIR} && docker compose pull && docker compose up -d'

   Data & backups: ${DATA_DIR}
EOF
printf '\033[1;32m────────────────────────────────────────────────────────\033[0m\n\n'
