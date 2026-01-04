#!/bin/bash
# Resilient user-data: log errors, keep going, keep app alive via systemd

LOG_FILE="/var/log/aws-learning-demo-userdata.log"
exec > >(tee -a "$LOG_FILE" | logger -t aws-learning-demo-userdata -s 2>/dev/console) 2>&1

log() { echo "[$(date -Is)] $*"; }
run() { log "RUN: $*"; "$@" && log "OK: $*" || log "ERROR ($?): $*"; }

APP_NAME="aws-learning-demo"
REPO_URL="https://github.com/AravindReddyGuda/AWS_Learning_Demo.git"
APP_DIR="/opt/AWS_Learning_Demo"
APP_USER="nodeapp"
NODE_MAJOR="20"

log "=== Starting user-data for ${APP_NAME} ==="

# 1) Base packages
run sudo apt-get update -y
run sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
run sudo apt-get install -y curl git ca-certificates

# 2) Node.js 20
run bash -lc "curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | sudo -E bash -"
run sudo apt-get install -y nodejs
run node -v
run npm -v

# 3) Service user
if id "$APP_USER" >/dev/null 2>&1; then
  log "User $APP_USER already exists"
else
  run sudo useradd -m -s /bin/bash "$APP_USER"
fi

# 4) Clone/update repo
run sudo mkdir -p /opt

if [ -d "${APP_DIR}/.git" ]; then
  log "Repo exists; pulling latest"
  run sudo git -C "$APP_DIR" fetch --all --prune
  run sudo git -C "$APP_DIR" reset --hard origin/main
else
  log "Cloning repo"
  run sudo git clone "$REPO_URL" "$APP_DIR"
fi

run sudo chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"

# 5) Ensure package.json exists (so npm start works)
if [ ! -f "${APP_DIR}/package.json" ]; then
  log "package.json not found; creating one for npm start"
  run sudo -u "$APP_USER" tee "${APP_DIR}/package.json" >/dev/null <<'EOF'
{
  "name": "aws-learning-demo",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "main": "index.js",
  "scripts": {
    "start": "node index.js"
  },
  "dependencies": {
    "express": "^4.19.2"
  }
}
EOF
fi

# 6) Install node modules
if [ -f "${APP_DIR}/package-lock.json" ]; then
  run sudo -u "$APP_USER" bash -lc "cd '$APP_DIR' && npm ci --omit=dev"
else
  run sudo -u "$APP_USER" bash -lc "cd '$APP_DIR' && npm install --omit=dev"
fi

# 7) systemd service using npm start + aggressive restart
run sudo tee "/etc/systemd/system/${APP_NAME}.service" >/dev/null <<EOF
[Unit]
Description=AWS Learning Demo (Node.js)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}

Environment=NODE_ENV=production
Environment=PORT=3000

ExecStart=/usr/bin/npm start --silent

Restart=always
RestartSec=2
StartLimitIntervalSec=0

StandardOutput=journal
StandardError=journal
TimeoutStopSec=10
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF

run sudo systemctl daemon-reload
run sudo systemctl enable "${APP_NAME}"
run sudo systemctl restart "${APP_NAME}"
run sudo systemctl --no-pager status "${APP_NAME}" || true

log "=== Done. User-data log: ${LOG_FILE} ==="
log "App logs: journalctl -u ${APP_NAME} -f"
