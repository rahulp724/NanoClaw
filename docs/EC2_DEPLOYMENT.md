# EC2 Deployment Guide

Deploy NanoClaw to a new AWS account in one step. Total hands-on time: ~15 minutes. Bootstrap completes automatically in the background (~10 minutes).

## Architecture

```
Slack ──(Socket Mode)──► EC2 (private subnet)
                              │
                         ┌────▼────────────────┐
                         │  nanoclaw (systemd) │
                         │  ├── OneCLI proxy   │  ──► api.anthropic.com
                         │  └── Docker         │
                         └────────────────────-┘
                              │
                         NAT Gateway ──► Internet
                              │
                    ECR (Docker image)
                    SSM Parameter Store (secrets)
                    SSM Session Manager (shell access)
```

No inbound ports. All access via AWS SSM Session Manager (outbound HTTPS).

---

## Prerequisites

**Local tools:**
- `aws` CLI v2 (`aws --version`)
- `docker` with daemon running (`docker info`)
- `jq` (`jq --version`)

**AWS account:**
- IAM user/role with permissions to create: IAM roles, EC2, ECR, SSM parameters, security groups
- An existing VPC with a **private subnet that has a NAT gateway** (the instance needs outbound internet, but no inbound)

**Slack app:** Bot Token (`xoxb-...`), App Token (`xapp-...`), Socket Mode enabled.  
See [SLACK_SETUP.md](../SLACK_SETUP.md) if you need to create one.

**GitHub:** A fork of this repository (for CI/CD).

---

## Quick Start

### 1. Set environment variables

```bash
export AWS_DEFAULT_PROFILE=your-aws-profile   # or omit for default
export AWS_REGION=ap-southeast-1

export VPC_ID=vpc-xxxxxxxxxxxxxxxxx
export SUBNET_ID=subnet-xxxxxxxxxxxxxxxxx      # private subnet with NAT

export ANTHROPIC_API_KEY=sk-ant-api03-...
export SLACK_BOT_TOKEN=xoxb-...
export SLACK_APP_TOKEN=xapp-...
export SLACK_CHANNEL_ID=C0XXXXXXXXX            # right-click channel → Copy link → last segment
export GITHUB_REPO=your-org/your-fork
```

### 2. Run the setup script

```bash
bash scripts/aws-setup.sh
```

The script will prompt for any missing values. It's safe to re-run — all operations are idempotent.

### 3. Configure GitHub Actions

After the script completes, it prints four values to add as **GitHub Repository Variables**:

```
Settings → Secrets and variables → Actions → Variables tab → New repository variable
```

| Variable | Value (from script output) |
|----------|---------------------------|
| `AWS_REGION` | e.g. `ap-southeast-1` |
| `ECR_REGISTRY` | e.g. `123456789.dkr.ecr.ap-southeast-1.amazonaws.com` |
| `INSTANCE_ID` | e.g. `i-0abc123def456789` |
| `OIDC_ROLE_ARN` | e.g. `arn:aws:iam::123456789:role/nanoclaw-github-actions` |

No AWS secrets are needed — authentication is via OIDC (no long-lived credentials stored in GitHub).

### 4. Update `deploy.yml`

Replace the hardcoded `env:` block and `role-to-assume` with GitHub Actions variables:

```yaml
# .github/workflows/deploy.yml
env:
  AWS_REGION:     ${{ vars.AWS_REGION }}
  ECR_REPOSITORY: nanoclaw-agent
  ECR_REGISTRY:   ${{ vars.ECR_REGISTRY }}
  INSTANCE_ID:    ${{ vars.INSTANCE_ID }}

# In the "Configure AWS credentials" step:
role-to-assume: ${{ vars.OIDC_ROLE_ARN }}

# In the SSM deploy commands, replace hardcoded registry with:
${{ env.ECR_REGISTRY }}
```

### 5. Test

Send a message in your Slack channel. The bot should respond within ~10 seconds.

---

## What the Setup Script Creates

### IAM: EC2 Instance Role (`nanoclaw-ec2-role`)

| Permission | Scope |
|------------|-------|
| SSM Session Manager + Run Command | `*` (required by SSM) |
| ECR `GetAuthorizationToken` | `*` (required by ECR) |
| ECR image pull (`BatchGetImage`, `GetDownloadUrlForLayer`, etc.) | `nanoclaw-agent` repository only |
| SSM Parameter Store read | `/nanoclaw/*` path only |

### IAM: GitHub Actions Role (`nanoclaw-github-actions`)

OIDC trust policy scoped to your specific GitHub repository. No stored AWS credentials in GitHub.

| Permission | Scope |
|------------|-------|
| ECR `GetAuthorizationToken` | `*` |
| ECR push (all upload actions) | `nanoclaw-agent` repository only |
| `ssm:SendCommand` | `nanoclaw-agent` instance tag + `AWS-RunShellScript` document |
| `ssm:GetCommandInvocation` | `*` (cannot be scoped — AWS limitation) |

### ECR Repository (`nanoclaw-agent`)

Image scanning enabled on push.

### Security Group (`nanoclaw-sg`)

Zero inbound rules. Outbound: all traffic. SSM uses outbound HTTPS — no inbound ports needed.

### SSM Parameters (SecureString)

- `/nanoclaw/ANTHROPIC_API_KEY`
- `/nanoclaw/SLACK_BOT_TOKEN`
- `/nanoclaw/SLACK_APP_TOKEN`
- `/nanoclaw/recovery-script` (String, for disaster recovery)

### EC2 Instance

- Amazon Linux 2023, latest AMI (auto-detected at launch time)
- Instance type: `t3.medium` (configurable via `INSTANCE_TYPE`)
- 30 GB gp3 volume
- IMDSv2 enforced (`HttpTokens=required`)
- Private subnet — no public IP
- Bootstrapped via UserData (see below)

---

## Bootstrap Process

The UserData script runs once on first boot and takes ~10 minutes. Progress is logged to `/var/log/nanoclaw-setup.log`.

| Phase | What happens |
|-------|--------------|
| 1. System | `dnf update`, Node.js 22 (nodesource), Docker, Git |
| 2. Docker Compose | Downloads standalone v2.24.5 binary (not in AL2023 repos) |
| 3. Container image | ECR login, `docker pull nanoclaw-agent:latest`, local tag |
| 4. Application | `git clone`, `chown -R ec2-user`, `npm ci`, `npm run build` |
| 5. OneCLI | Install with `ONECLI_BIND_HOST=172.17.0.1`, wait 25s, set restart-always |
| 6. OneCLI CLI | Install, `onecli config set api-host`, create Anthropic secret |
| 7. Secrets | Fetch from SSM, write `.env` and `data/env/env` |
| 8. Registration | `setup/index.ts --step mounts`, `--step register` |
| 9. Service | Write systemd unit with `User=ec2-user`, clear `/tmp/onecli*.pem`, start |

---

## CI/CD: How Deploys Work

Every push to `main` (touching `src/`, `container/`, or `package*.json`) triggers the pipeline:

1. **Build** — `docker build --platform linux/amd64 ./container` on GitHub's `ubuntu-latest` runner (native x86_64 — no emulation)
2. **Push** — Push `:latest` + `:<sha>` tags to ECR
3. **Deploy** — SSM `AWS-RunShellScript` to the EC2 instance:
   - `docker pull` new image
   - `docker tag` as local `nanoclaw-agent:latest`
   - `systemctl restart nanoclaw`
4. **Wait** — Poll `ssm:GetCommandInvocation` until success or 3-minute timeout

No SSH keys needed. No inbound ports opened.

---

## Operations

### Connect to the instance

```bash
aws ssm start-session --target <INSTANCE_ID> --region <REGION>
```

### Check service status

```bash
sudo systemctl status nanoclaw
sudo journalctl -fu nanoclaw
```

### View logs

```bash
# Application log
sudo tail -f /opt/nanoclaw/logs/nanoclaw.log

# Bootstrap log (first boot only)
sudo tail -f /var/log/nanoclaw-setup.log

# Container agent logs (per conversation)
ls /opt/nanoclaw/groups/slack_main/logs/
```

### Manual deploy (without CI)

```bash
bash scripts/ec2-deploy.sh
```

### Rotate a secret

```bash
aws ssm put-parameter \
  --name /nanoclaw/ANTHROPIC_API_KEY \
  --value sk-ant-api03-NEW-KEY \
  --type SecureString --overwrite \
  --region ap-southeast-1

# Restart the service to pick up the new key
aws ssm send-command \
  --instance-ids <INSTANCE_ID> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl restart nanoclaw"]' \
  --region ap-southeast-1
```

### Run the recovery script

If the instance needs a full re-bootstrap (e.g. after manually resetting it):

```bash
aws ssm send-command \
  --instance-ids <INSTANCE_ID> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=[
    "aws ssm get-parameter --name /nanoclaw/recovery-script --query Parameter.Value --output text --region ap-southeast-1 | bash"
  ]' \
  --region ap-southeast-1 \
  --query 'Command.CommandId' --output text
```

---

## Known Issues and Fixes

These are hard-won lessons from production. All fixes are already baked into the scripts.

### 1. Service must run as `ec2-user` (not root)

**Symptom:** Agent never responds. Log shows `EACCES: permission denied, unlink '/workspace/ipc/input/xxx.json'` repeating for minutes.

**Cause:** The agent container runs as the `node` user (UID 1000). The host NanoClaw process writes IPC task files. If the host runs as root (UID 0), those files are root-owned, and the container's `node` user cannot delete them after processing → infinite retry loop.

**Fix:** `User=ec2-user` and `Group=ec2-user` in the `[Service]` section of the systemd unit. All `npm`/`npx` setup commands run as `sudo -u ec2-user`.

---

### 2. OneCLI must bind to `172.17.0.1`, not `127.0.0.1`

**Symptom:** Containers get `ECONNREFUSED` when calling the Anthropic API. Log shows `Unable to connect to API`.

**Cause:** `127.0.0.1` (loopback) is not reachable from inside Docker containers. The Docker bridge gateway IP `172.17.0.1` is reachable from all containers via `--add-host=host.docker.internal:host-gateway`.

**Fix:** `export ONECLI_BIND_HOST=172.17.0.1` before installing OneCLI. `ONECLI_URL=http://172.17.0.1:10254` in `.env`.

---

### 3. Delete OneCLI CA cert files before starting the service

**Symptom:** Service starts but no containers spawn. Error log shows `EACCES: permission denied, open '/tmp/onecli-proxy-ca.pem'`.

**Cause:** OneCLI installation (run as root in UserData) creates `/tmp/onecli-proxy-ca.pem` and `/tmp/onecli-combined-ca.pem` owned by root. When the NanoClaw service later runs as `ec2-user`, it tries to write these files → EACCES.

**Fix:** `rm -f /tmp/onecli-proxy-ca.pem /tmp/onecli-combined-ca.pem` in UserData immediately before `systemctl start nanoclaw`. The service recreates them as `ec2-user` on first container spawn.

---

### 4. Docker Compose standalone binary required

**Symptom:** OneCLI install fails with `docker-compose: command not found`.

**Cause:** Amazon Linux 2023 does not include `docker-compose-plugin` in its repos. OneCLI requires Docker Compose to manage its containers.

**Fix:**
```bash
curl -SL https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-linux-x86_64 \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
```

---

### 5. `ssm:GetCommandInvocation` requires `Resource: "*"`

**Symptom:** GitHub Actions CI/CD hangs forever on the "Poll until done" loop. SSM command status always shows `Pending` even after the command completes.

**Cause:** The IAM policy had `ssm:GetCommandInvocation` scoped to the instance ARN. AWS does not support resource-level restrictions for this action — the permission silently fails and the AWS CLI falls back to returning `Pending`.

**Fix:** The `ssm:GetCommandInvocation` IAM statement must have `"Resource": "*"`. This is an AWS limitation, not a security choice.

---

### 6. Build image as `linux/amd64`, not `arm64`

**Symptom:** Container fails on EC2 with `exec /app/entrypoint.sh: exec format error`.

**Cause:** Building on an Apple Silicon Mac produces an `arm64` image by default. EC2 `t3.medium` is `x86_64`.

**Fix:** `docker build --platform linux/amd64 ./container`. The CI/CD pipeline builds on `ubuntu-latest` (native x86_64) so this only affects local builds.

---

## Troubleshooting

### Instance never appears in SSM

Check that the subnet has a route to the internet via a NAT gateway. The SSM agent needs outbound HTTPS to connect to `ssm.<region>.amazonaws.com`.

```bash
# Verify subnet route table has NAT
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=<SUBNET_ID>" \
  --query 'RouteTables[0].Routes'
```

### Bootstrap log stops mid-way

Common causes:

| Symptom in log | Cause | Fix |
|----------------|-------|-----|
| `dnf` stalls | Network issue in subnet | Check NAT gateway |
| `git clone` fails (404) | Repo is private | Make repo public or add deploy key |
| `docker pull` fails | ECR auth expired or IAM role missing | Check instance profile is attached |
| `onecli` install hangs | OneCLI server slow to start | The script sleeps 25s; if logs stop there, wait longer |

### "Not logged in · Please run /login" from bot

**Cause:** A container with a stale session ID (from a previously killed container) tried to resume a conversation that no longer exists. Claude Code couldn't find it and printed its default unauthenticated message as output.

**Fix:** Clear the stale session:
```bash
# On the EC2 instance
rm -f /opt/nanoclaw/data/sessions/slack_main/.claude/sessions/*.jsonl
sqlite3 /opt/nanoclaw/store/messages.db "DELETE FROM sessions WHERE group_folder='slack_main'"
```

This is transient — the next message will start a fresh session automatically.

### Bot connects but doesn't respond to messages

1. Check Slack channel registration: `sqlite3 /opt/nanoclaw/store/messages.db "SELECT jid, name, is_main, requires_trigger FROM registered_groups"`
2. Check for stuck IPC files: `ls /opt/nanoclaw/data/ipc/slack_main/input/` — delete any `.json` files
3. Check service user: `ps aux | grep nanoclaw | grep -v grep` — must show `ec2-user`, not `root`
4. Restart clean: `systemctl restart nanoclaw`
