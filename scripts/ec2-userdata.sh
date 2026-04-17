#!/bin/bash
# EC2 bootstrap script for NanoClaw (Amazon Linux 2023)
# Runs once on first boot via EC2 user-data
set -euo pipefail
exec > >(tee /var/log/nanoclaw-setup.log) 2>&1
echo "=== NanoClaw Bootstrap: $(date) ==="

REGION="ap-southeast-1"
ACCOUNT="194428989522"
ECR_IMAGE="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/nanoclaw-agent:latest"
REPO_URL="https://github.com/rahulp724/NanoClaw.git"
APP_DIR="/opt/nanoclaw"
export HOME=/root

# 1. System packages
dnf update -y
curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
dnf install -y nodejs git docker

# 2. Docker
systemctl enable docker
systemctl start docker
sleep 5

# 3. Pull agent image from ECR and tag locally (avoids ECR auth expiry at runtime)
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin ${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com
docker pull "$ECR_IMAGE"
docker tag "$ECR_IMAGE" nanoclaw-agent:latest

# 4. Clone repo and build
git clone $REPO_URL $APP_DIR
cd $APP_DIR
npm ci
npm run build

# 5. Install OneCLI (credential proxy — runs as Docker containers)
curl -fsSL onecli.sh/install | sh
sleep 20  # wait for containers to become healthy

# Persist OneCLI containers across reboots via Docker restart policy
docker update --restart always onecli onecli-postgres-1 2>/dev/null || true

# 6. Install OneCLI CLI
curl -fsSL onecli.sh/cli/install | sh
export PATH="/root/.local/bin:$PATH"

# 7. Configure OneCLI and load Anthropic key from SSM
ONECLI_URL="http://127.0.0.1:10254"
onecli config set api-host $ONECLI_URL
sleep 3

ANTHROPIC_KEY=$(aws ssm get-parameter --name "/nanoclaw/ANTHROPIC_API_KEY" --with-decryption \
  --query "Parameter.Value" --output text --region $REGION)
onecli secrets create --name Anthropic --type anthropic \
  --value "$ANTHROPIC_KEY" --host-pattern api.anthropic.com

# 8. Fetch Slack tokens from SSM
SLACK_BOT=$(aws ssm get-parameter --name "/nanoclaw/SLACK_BOT_TOKEN" --with-decryption \
  --query "Parameter.Value" --output text --region $REGION)
SLACK_APP=$(aws ssm get-parameter --name "/nanoclaw/SLACK_APP_TOKEN" --with-decryption \
  --query "Parameter.Value" --output text --region $REGION)

# 9. Write .env
mkdir -p $APP_DIR/logs $APP_DIR/data/env
cat > $APP_DIR/.env << ENVEOF
ONECLI_URL=${ONECLI_URL}
SLACK_BOT_TOKEN=${SLACK_BOT}
SLACK_APP_TOKEN=${SLACK_APP}
CONTAINER_IMAGE=nanoclaw-agent:latest
TZ=Asia/Calcutta
ENVEOF
cp $APP_DIR/.env $APP_DIR/data/env/env

# 10. Mount allowlist and Slack channel registration
cd $APP_DIR
npx tsx setup/index.ts --step mounts -- --empty
npx tsx setup/index.ts --step register -- \
  --jid "slack:C0ATKPXBVFY" \
  --name "nanoclaw-sre" \
  --folder "slack_main" \
  --trigger "@nanoclaw" \
  --channel slack \
  --no-trigger-required \
  --is-main

# 11. Systemd service
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

echo "=== NanoClaw Bootstrap Complete: $(date) ==="
