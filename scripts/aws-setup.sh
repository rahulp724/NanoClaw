#!/bin/bash
# NanoClaw — one-click AWS deployment for a new account
#
# Creates all AWS infrastructure, builds the Docker image, launches EC2,
# and waits for the bootstrap to complete. Re-running is safe (idempotent).
#
# Usage:
#   export VPC_ID=vpc-xxx SUBNET_ID=subnet-xxx
#   export ANTHROPIC_API_KEY=sk-ant-...
#   export SLACK_BOT_TOKEN=xoxb-... SLACK_APP_TOKEN=xapp-...
#   export SLACK_CHANNEL_ID=C0XXXXXXX GITHUB_REPO=your-org/your-fork
#   bash scripts/aws-setup.sh
set -euo pipefail

# ── colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR ]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── error trap ───────────────────────────────────────────────────────────────
CURRENT_STEP="init"
INSTANCE_ID=""
cleanup_on_err() {
  local code=$?
  [[ $code -eq 0 ]] && return
  echo -e "\n${RED}Failed at: ${CURRENT_STEP}${NC}" >&2
  if [[ -n "$INSTANCE_ID" ]]; then
    warn "Instance $INSTANCE_ID may be partially bootstrapped."
    warn "Connect: aws ssm start-session --target $INSTANCE_ID --region ${AWS_REGION:-ap-southeast-1}"
    warn "Logs:    sudo tail -f /var/log/nanoclaw-setup.log"
    warn "Terminate if needed: aws ec2 terminate-instances --instance-ids $INSTANCE_ID"
  fi
}
trap cleanup_on_err EXIT

# ── prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
CURRENT_STEP="prereqs"
missing=()
for cmd in aws docker jq; do
  command -v "$cmd" &>/dev/null || missing+=("$cmd")
done
[[ ${#missing[@]} -eq 0 ]] || err "Missing: ${missing[*]}. Install them and retry."
docker info &>/dev/null 2>&1 || err "Docker daemon is not running."
ok "aws, docker, jq — all present"

# ── input collection ─────────────────────────────────────────────────────────
step "Collecting configuration"
CURRENT_STEP="inputs"

prompt_var() {
  local var="$1" prompt="$2" default="${3:-}" secret="${4:-false}" optional="${5:-false}"
  local current="${!var:-}"
  if [[ -n "$current" ]]; then
    [[ "$secret" == "true" ]] && ok "$var = [already set]" || ok "$var = $current"
    return
  fi
  if [[ -n "$default" ]]; then
    read -r -p "  $prompt [$default]: " input
    printf -v "$var" '%s' "${input:-$default}"
  elif [[ "$secret" == "true" ]]; then
    read -rsp "  $prompt: " input; echo
    [[ -n "$input" ]] || err "$var is required"
    printf -v "$var" '%s' "$input"
  elif [[ "$optional" == "true" ]]; then
    read -r -p "  $prompt (optional, press Enter to skip): " input
    printf -v "$var" '%s' "$input"
  else
    read -r -p "  $prompt: " input
    [[ -n "$input" ]] || err "$var is required"
    printf -v "$var" '%s' "$input"
  fi
  [[ "$secret" == "true" ]] && ok "$var = [set]" || ok "$var = ${!var}"
}

prompt_var AWS_REGION          "AWS region"                  "ap-southeast-1"
prompt_var AWS_DEFAULT_PROFILE "AWS CLI profile"             "default"
export AWS_DEFAULT_PROFILE AWS_REGION

prompt_var VPC_ID              "VPC ID (vpc-xxxxx)"
prompt_var SUBNET_ID           "Private subnet ID (with NAT gateway)"
prompt_var ANTHROPIC_API_KEY   "Anthropic API key (sk-ant-...)" "" "true"
prompt_var SLACK_BOT_TOKEN     "Slack Bot Token (xoxb-...)"    "" "true"
prompt_var SLACK_APP_TOKEN     "Slack App Token (xapp-...)"    "" "true"
prompt_var SLACK_CHANNEL_ID    "Slack channel ID (e.g. C0ATKPXBVFY)"
prompt_var GITHUB_REPO         "GitHub repo (owner/repo)"
prompt_var INSTANCE_TYPE       "EC2 instance type"            "t3.medium"
prompt_var KEY_NAME            "EC2 key pair name" "" "false" "true"

# ── validation ────────────────────────────────────────────────────────────────
step "Validating inputs"
CURRENT_STEP="validation"

validate() {
  local val="$1" pattern="$2" label="$3"
  [[ "$val" =~ $pattern ]] || err "$label looks wrong: '$val'"
}
validate "$VPC_ID"           '^vpc-[a-f0-9]+$'                        "VPC_ID"
validate "$SUBNET_ID"        '^subnet-[a-f0-9]+$'                     "SUBNET_ID"
validate "$SLACK_BOT_TOKEN"  '^xoxb-'                                 "SLACK_BOT_TOKEN"
validate "$SLACK_APP_TOKEN"  '^xapp-'                                  "SLACK_APP_TOKEN"
validate "$SLACK_CHANNEL_ID" '^[A-Z0-9]{9,12}$'                       "SLACK_CHANNEL_ID"
validate "$GITHUB_REPO"      '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$'     "GITHUB_REPO"

# Verify subnet is in the given VPC
subnet_vpc=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[0].VpcId' --output text 2>/dev/null || echo "")
[[ "$subnet_vpc" == "$VPC_ID" ]] || \
  err "Subnet $SUBNET_ID is not in VPC $VPC_ID (found: $subnet_vpc)"
ok "Subnet is in the correct VPC"

# ── AWS identity ──────────────────────────────────────────────────────────────
step "Verifying AWS identity"
CURRENT_STEP="identity"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
ok "Account:   $ACCOUNT_ID"
ok "Principal: $CALLER_ARN"

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_URI="${ECR_REGISTRY}/nanoclaw-agent:latest"
ROLE_NAME="nanoclaw-ec2-role"
PROFILE_NAME="nanoclaw-ec2-profile"
GH_ROLE_NAME="nanoclaw-github-actions"
SG_NAME="nanoclaw-sg"
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

# ── IAM: instance role ────────────────────────────────────────────────────────
step "IAM — EC2 instance role"
CURRENT_STEP="iam-instance-role"

TRUST_EC2=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF
)

POLICY_EC2=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SSMCoreAccess",
      "Effect": "Allow",
      "Action": [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
        "ec2messages:AcknowledgeMessage",
        "ec2messages:DeleteMessage",
        "ec2messages:FailMessage",
        "ec2messages:GetEndpoint",
        "ec2messages:GetMessages",
        "ec2messages:SendReply"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "ECRPull",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/nanoclaw-agent"
    },
    {
      "Sid": "SSMParamRead",
      "Effect": "Allow",
      "Action": ["ssm:GetParameter", "ssm:GetParameters"],
      "Resource": "arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter/nanoclaw/*"
    }
  ]
}
EOF
)

if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  ok "Role $ROLE_NAME already exists"
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_EC2" \
    --description "NanoClaw EC2 instance role" \
    --no-cli-pager
  ok "Created role: $ROLE_NAME"
fi

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "nanoclaw-ec2-policy" \
  --policy-document "$POLICY_EC2" \
  --no-cli-pager
ok "Inline policy updated"

if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" &>/dev/null; then
  ok "Instance profile $PROFILE_NAME already exists"
else
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" --no-cli-pager
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME"
  ok "Created instance profile: $PROFILE_NAME"
  log "Waiting 15s for IAM propagation..."
  sleep 15
fi

# ── IAM: GitHub Actions OIDC ──────────────────────────────────────────────────
step "IAM — GitHub Actions OIDC role"
CURRENT_STEP="iam-github-actions"

if aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" &>/dev/null; then
  ok "GitHub OIDC provider already exists"
else
  aws iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" \
                      "1c58a3a8518e8759bf075b76b750d4f2df264fcd" \
    --no-cli-pager
  ok "Created GitHub OIDC provider"
fi

TRUST_GH=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "${OIDC_PROVIDER_ARN}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:${GITHUB_REPO}:*"
      },
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF
)

POLICY_GH=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "ECRPush",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${ACCOUNT_ID}:repository/nanoclaw-agent"
    },
    {
      "Sid": "SSMSendCommand",
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": [
        "arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:instance/*",
        "arn:aws:ssm:${AWS_REGION}::document/AWS-RunShellScript"
      ]
    },
    {
      "Sid": "SSMGetCommandInvocation",
      "Effect": "Allow",
      "Action": "ssm:GetCommandInvocation",
      "Resource": "*"
    }
  ]
}
EOF
)

if aws iam get-role --role-name "$GH_ROLE_NAME" &>/dev/null; then
  ok "Role $GH_ROLE_NAME already exists — updating trust + policy"
  aws iam update-assume-role-policy \
    --role-name "$GH_ROLE_NAME" \
    --policy-document "$TRUST_GH" \
    --no-cli-pager
else
  aws iam create-role \
    --role-name "$GH_ROLE_NAME" \
    --assume-role-policy-document "$TRUST_GH" \
    --description "NanoClaw CI/CD via GitHub Actions OIDC" \
    --no-cli-pager
  ok "Created role: $GH_ROLE_NAME"
fi

aws iam put-role-policy \
  --role-name "$GH_ROLE_NAME" \
  --policy-name "nanoclaw-github-actions-policy" \
  --policy-document "$POLICY_GH" \
  --no-cli-pager
ok "GitHub Actions role policy updated"

# ── ECR repository ────────────────────────────────────────────────────────────
step "ECR repository"
CURRENT_STEP="ecr"

if aws ecr describe-repositories --repository-names nanoclaw-agent \
    --region "$AWS_REGION" &>/dev/null; then
  ok "ECR repository nanoclaw-agent already exists"
else
  aws ecr create-repository \
    --repository-name nanoclaw-agent \
    --image-scanning-configuration scanOnPush=true \
    --region "$AWS_REGION" \
    --no-cli-pager
  ok "Created ECR repository: nanoclaw-agent"
fi

# ── Security group ────────────────────────────────────────────────────────────
step "Security group"
CURRENT_STEP="security-group"

SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [[ "$SG_ID" != "None" && -n "$SG_ID" ]]; then
  ok "Security group $SG_ID already exists"
else
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "NanoClaw EC2 — SSM only, no inbound" \
    --vpc-id "$VPC_ID" \
    --region "$AWS_REGION" \
    --query 'GroupId' --output text)
  # Remove any default inbound rules (vary by VPC config)
  aws ec2 revoke-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol all --port -1 --cidr 0.0.0.0/0 \
    --region "$AWS_REGION" 2>/dev/null || true
  aws ec2 create-tags \
    --resources "$SG_ID" \
    --tags Key=Name,Value=nanoclaw-sg \
    --region "$AWS_REGION"
  ok "Created security group: $SG_ID (no inbound rules)"
fi

# ── SSM parameters ────────────────────────────────────────────────────────────
step "SSM SecureString parameters"
CURRENT_STEP="ssm-params"

put_ssm() {
  aws ssm put-parameter \
    --name "$1" --value "$2" \
    --type SecureString --overwrite \
    --region "$AWS_REGION" --no-cli-pager &>/dev/null
  ok "SSM: $1"
}
put_ssm "/nanoclaw/ANTHROPIC_API_KEY" "$ANTHROPIC_API_KEY"
put_ssm "/nanoclaw/SLACK_BOT_TOKEN"   "$SLACK_BOT_TOKEN"
put_ssm "/nanoclaw/SLACK_APP_TOKEN"   "$SLACK_APP_TOKEN"

# ── Docker build + push ───────────────────────────────────────────────────────
step "Building and pushing Docker image (linux/amd64)"
CURRENT_STEP="docker-build"

aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

docker build \
  --platform linux/amd64 \
  -t "nanoclaw-agent:latest" \
  "$REPO_ROOT/container"

docker tag "nanoclaw-agent:latest" "$ECR_URI"
docker push "$ECR_URI"
ok "Image pushed: $ECR_URI"

# ── EC2 launch ────────────────────────────────────────────────────────────────
step "Launching EC2 instance"
CURRENT_STEP="ec2-launch"

# Check for existing instance
EXISTING=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=nanoclaw" \
            "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [[ "$EXISTING" != "None" && -n "$EXISTING" ]]; then
  INSTANCE_ID="$EXISTING"
  ok "Instance already exists: $INSTANCE_ID"
else
  # Latest Amazon Linux 2023 x86_64 AMI
  AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" \
              "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text --region "$AWS_REGION")
  log "Using AMI: $AMI_ID"

  # Generate userdata from template — substitute account, region, channel, repo
  USERDATA=$(sed \
    -e "s|ACCOUNT=\"194428989522\"|ACCOUNT=\"${ACCOUNT_ID}\"|g" \
    -e "s|REGION=\"ap-southeast-1\"|REGION=\"${AWS_REGION}\"|g" \
    -e "s|slack:C0ATKPXBVFY|slack:${SLACK_CHANNEL_ID}|g" \
    -e "s|https://github.com/rahulp724/NanoClaw.git|https://github.com/${GITHUB_REPO}.git|g" \
    "$SCRIPT_DIR/ec2-userdata.sh")

  # Build launch command arguments
  LAUNCH_ARGS=(
    --image-id "$AMI_ID"
    --instance-type "$INSTANCE_TYPE"
    --iam-instance-profile "Name=$PROFILE_NAME"
    --security-group-ids "$SG_ID"
    --subnet-id "$SUBNET_ID"
    --user-data "$USERDATA"
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=nanoclaw}]"
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled"
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}"
    --region "$AWS_REGION"
    --query 'Instances[0].InstanceId'
    --output text
    --no-cli-pager
  )
  [[ -n "$KEY_NAME" ]] && LAUNCH_ARGS+=(--key-name "$KEY_NAME")

  INSTANCE_ID=$(aws ec2 run-instances "${LAUNCH_ARGS[@]}")
  ok "Launched: $INSTANCE_ID"
fi

# ── Recovery script in SSM ────────────────────────────────────────────────────
step "Storing recovery script in SSM"
CURRENT_STEP="ssm-recovery"

RECOVERY=$(sed \
  -e "s|ACCOUNT=\"194428989522\"|ACCOUNT=\"${ACCOUNT_ID}\"|g" \
  -e "s|REGION=\"ap-southeast-1\"|REGION=\"${AWS_REGION}\"|g" \
  -e "s|slack:C0ATKPXBVFY|slack:${SLACK_CHANNEL_ID}|g" \
  -e "s|https://github.com/rahulp724/NanoClaw.git|https://github.com/${GITHUB_REPO}.git|g" \
  "$SCRIPT_DIR/ec2-recovery.sh")

aws ssm put-parameter \
  --name "/nanoclaw/recovery-script" \
  --value "$RECOVERY" \
  --type String --overwrite \
  --region "$AWS_REGION" --no-cli-pager &>/dev/null
ok "Recovery script stored at /nanoclaw/recovery-script"

# ── Bootstrap polling ─────────────────────────────────────────────────────────
step "Waiting for EC2 bootstrap (~8-12 minutes)"
CURRENT_STEP="bootstrap-wait"

# Step 1: wait for SSM agent
log "Waiting for SSM agent to register..."
ssm_ready=false
for i in $(seq 1 30); do
  status=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "Missing")
  if [[ "$status" == "Online" ]]; then
    ssm_ready=true
    ok "SSM agent online"
    break
  fi
  log "  [$i/30] SSM status: $status — waiting 20s..."
  sleep 20
done
$ssm_ready || { warn "SSM never came online. Check instance and retry."; exit 1; }

# Step 2: poll bootstrap log
log "Polling bootstrap log (up to 20 min)..."
for i in $(seq 1 40); do
  CMD_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["tail -5 /var/log/nanoclaw-setup.log 2>/dev/null || echo LOG_PENDING"]' \
    --query 'Command.CommandId' --output text \
    --region "$AWS_REGION" --no-cli-pager 2>/dev/null || echo "")

  [[ -z "$CMD_ID" ]] && { sleep 15; continue; }
  sleep 5

  OUT=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

  last_line=$(echo "$OUT" | tail -1 | tr -d '\r')
  log "  [$i/40] $last_line"

  if echo "$OUT" | grep -q "Bootstrap Complete"; then
    ok "Bootstrap complete!"
    break
  fi
  sleep 25
done

# ── Final summary ─────────────────────────────────────────────────────────────
OIDC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${GH_ROLE_NAME}"

echo
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  NanoClaw setup complete!${NC}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo -e "${BOLD}Instance:${NC}      $INSTANCE_ID"
echo -e "${BOLD}Region:${NC}        $AWS_REGION"
echo -e "${BOLD}ECR Registry:${NC}  $ECR_REGISTRY"
echo
echo -e "${BOLD}${CYAN}── GitHub Actions: add these Repository Variables ──${NC}"
echo "   (Settings → Secrets and variables → Actions → Variables tab)"
echo
printf "   %-20s = %s\n" "AWS_REGION"    "$AWS_REGION"
printf "   %-20s = %s\n" "ECR_REGISTRY"  "$ECR_REGISTRY"
printf "   %-20s = %s\n" "INSTANCE_ID"   "$INSTANCE_ID"
printf "   %-20s = %s\n" "OIDC_ROLE_ARN" "$OIDC_ROLE_ARN"
echo
echo -e "${BOLD}${CYAN}── Connect to instance ──${NC}"
echo "   aws ssm start-session --target $INSTANCE_ID --region $AWS_REGION"
echo
echo -e "${BOLD}${CYAN}── Check service ──${NC}"
echo "   sudo systemctl status nanoclaw"
echo "   sudo journalctl -fu nanoclaw"
echo
echo -e "${BOLD}${CYAN}── Test: send a message in #$(echo "$SLACK_CHANNEL_ID" | tr '[:upper:]' '[:lower:]') on Slack ──${NC}"
echo
