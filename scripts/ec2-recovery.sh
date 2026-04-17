#!/bin/bash
set -euo pipefail
exec >> /var/log/nanoclaw-setup.log 2>&1
echo "=== RECOVERY v2: $(date) ==="

REGION="ap-southeast-1"
ACCOUNT="194428989522"
APP_DIR="/opt/nanoclaw"
export HOME=/root
export PATH="/root/.local/bin:/usr/local/bin:/usr/bin:/bin"

# Clone repo if missing
if [ ! -d "$APP_DIR" ]; then
  git clone https://github.com/rahulp724/NanoClaw.git "$APP_DIR"
fi
cd "$APP_DIR"

# Build
npm ci
npm run build
echo "BUILD_OK"

# Install Docker Compose standalone binary (required by OneCLI)
if ! command -v docker-compose &>/dev/null; then
  curl -SL https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-linux-x86_64 \
    -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
fi

# Install OneCLI bound to Docker bridge gateway so containers can reach it
export ONECLI_BIND_HOST=172.17.0.1
curl -fsSL onecli.sh/install | sh
sleep 25
docker update --restart always onecli onecli-postgres-1 2>/dev/null || true
echo "ONECLI_OK"

# OneCLI CLI
curl -fsSL onecli.sh/cli/install | sh
ONECLI_URL="http://127.0.0.1:10254"
onecli config set api-host "$ONECLI_URL"
sleep 3

ANTHROPIC_KEY=$(aws ssm get-parameter --name /nanoclaw/ANTHROPIC_API_KEY \
  --with-decryption --query Parameter.Value --output text --region $REGION)
onecli secrets create --name Anthropic --type anthropic \
  --value "$ANTHROPIC_KEY" --host-pattern api.anthropic.com
echo "CREDENTIALS_OK"

SLACK_BOT=$(aws ssm get-parameter --name /nanoclaw/SLACK_BOT_TOKEN \
  --with-decryption --query Parameter.Value --output text --region $REGION)
SLACK_APP=$(aws ssm get-parameter --name /nanoclaw/SLACK_APP_TOKEN \
  --with-decryption --query Parameter.Value --output text --region $REGION)

cat > "$APP_DIR/.env" << ENVEOF
ONECLI_URL=http://172.17.0.1:10254
SLACK_BOT_TOKEN=${SLACK_BOT}
SLACK_APP_TOKEN=${SLACK_APP}
CONTAINER_IMAGE=nanoclaw-agent:latest
TZ=Asia/Calcutta
ENVEOF

mkdir -p "$APP_DIR/data/env" "$APP_DIR/logs"
cp "$APP_DIR/.env" "$APP_DIR/data/env/env"

npx tsx setup/index.ts --step mounts -- --empty
npx tsx setup/index.ts --step register -- \
  --jid "slack:C0ATKPXBVFY" --name "nanoclaw-sre" --folder "slack_main" \
  --trigger "@nanoclaw" --channel slack --no-trigger-required --is-main
echo "REGISTRATION_OK"

NODE_PATH=$(which node)
cat > /etc/systemd/system/nanoclaw.service << SVCEOF
[Unit]
Description=NanoClaw Slack Agent
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
Environment=PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${NODE_PATH} ${APP_DIR}/dist/index.js
Restart=always
RestartSec=10
StandardOutput=append:${APP_DIR}/logs/nanoclaw.log
StandardError=append:${APP_DIR}/logs/nanoclaw.error.log

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable nanoclaw
systemctl start nanoclaw
sleep 5
systemctl is-active nanoclaw && echo "=== BOOTSTRAP_COMPLETE ==="
