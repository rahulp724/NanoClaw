#!/bin/bash
# Deploy updated nanoclaw-agent image to EC2 via ECR + SSM
# Usage: ./scripts/ec2-deploy.sh [instance-id]
set -euo pipefail

REGION="ap-southeast-1"
ACCOUNT="194428989522"
ECR_URI="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/nanoclaw-agent:latest"
INSTANCE_ID="${1:-}"
PROFILE="${AWS_DEFAULT_PROFILE:-uat-1}"

if [[ -z "$INSTANCE_ID" ]]; then
  INSTANCE_ID=$(AWS_DEFAULT_PROFILE=$PROFILE aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=nanoclaw" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text --region $REGION)
fi

echo "==> Building and pushing image to ECR..."
AWS_DEFAULT_PROFILE=$PROFILE aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin ${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com
docker build -t nanoclaw-agent:latest ./container
docker tag nanoclaw-agent:latest "$ECR_URI"
docker push "$ECR_URI"

echo "==> Pulling new image and restarting service on $INSTANCE_ID..."
AWS_DEFAULT_PROFILE=$PROFILE aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=[
    "aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin 194428989522.dkr.ecr.ap-southeast-1.amazonaws.com",
    "docker pull 194428989522.dkr.ecr.ap-southeast-1.amazonaws.com/nanoclaw-agent:latest",
    "docker tag 194428989522.dkr.ecr.ap-southeast-1.amazonaws.com/nanoclaw-agent:latest nanoclaw-agent:latest",
    "systemctl restart nanoclaw"
  ]' \
  --region $REGION \
  --query 'Command.CommandId' --output text

echo "==> Deploy triggered. Check logs: aws ssm start-session --target $INSTANCE_ID --region $REGION"
