---
name: add-slack-interactivity
description: Add Slack interactive components to NanoClaw — buttons, dropdowns, modals, slash commands, image uploads, and threaded replies. Requires the add-slack skill to be installed first.
---

# Slack Interactivity

Upgrades the Slack channel with full Block Kit interactivity so the agent can send buttons, dropdowns, modals, and slash commands rather than plain text replies.

**Requires:** `/add-slack` must be installed first (`src/channels/slack.ts` must exist).

---

## What this adds

| Feature | How it works |
|---------|-------------|
| Approve/Cancel buttons | Agent sends a message with buttons; user clicks; agent receives the action and continues |
| Dropdown menus | Agent sends a select menu (namespace, pod, action); user picks; agent gets the value |
| Modal dialogs | Agent opens a form overlay; user fills it in; submission routes back as a new message |
| Slash commands | `/andy <text>` triggers the agent directly in any channel without @-mention |
| Image/file uploads | Agent calls `upload_image(path, filename)` to send charts, screenshots, reports |
| Threaded replies | Agent can reply inside a thread; conversation history stays in the thread |
| Interactivity webhook | HTTP server inside NanoClaw receives Slack's POST callbacks |

---

## Phase 1: Pre-flight

### Check add-slack is installed

```bash
test -f src/channels/slack.ts && echo "OK" || echo "MISSING — run /add-slack first"
```

If MISSING, stop and run `/add-slack` first.

### Check if already applied

```bash
test -f src/slack-interactivity.ts && echo "ALREADY_INSTALLED" || echo "NEEDS_INSTALL"
```

If ALREADY_INSTALLED, skip to Phase 4 (Slack App Config).

---

## Phase 2: Apply Code Changes

### Merge the skill branch

```bash
git fetch upstream skill/slack-interactivity
git merge upstream/skill/slack-interactivity || {
  git checkout --theirs package-lock.json
  git add package-lock.json
  git merge --continue --no-edit
}
```

This merges in:
- `src/slack-interactivity.ts` — HTTP server, Slack signature verification, action router
- `src/channels/slack.ts` — extended with `sendBlocks()`, `updateMessage()`, `openModal()`, `replyInThread()`, `uploadFile()`
- `container/skills/slack-blocks/` — agent-facing MCP tools
- `package.json` — no new dependencies (uses `@slack/bolt` already present)

### Validate

```bash
npm install
npm run build
npx vitest run src/slack-interactivity.test.ts
```

All tests must pass before continuing.

---

## Phase 3: Implementation Reference

> This section describes what the skill branch implements. Read it when building or debugging.

### 3a. HTTP server (`src/slack-interactivity.ts`)

NanoClaw starts a second HTTP listener (default port `3000`) that Slack posts interaction payloads to. It runs alongside the main process.

```
SLACK_INTERACTIVITY_PORT=3000   # env var, defaults to 3000
```

**Endpoints:**

| Path | Purpose |
|------|---------|
| `POST /slack/actions` | Button clicks, dropdown selections, modal submissions |
| `POST /slack/commands` | Slash command payloads |
| `GET  /health` | Liveness check for ALB/monitoring |

Every incoming request is verified with `SLACK_SIGNING_SECRET` (HMAC-SHA256 over the raw body + timestamp). Requests with invalid signatures or timestamps older than 5 minutes are rejected 403.

**Action routing:**

Slack sends a `payload.action_id` with every interaction. The server routes based on a prefix convention:

| `action_id` prefix | Route |
|-------------------|-------|
| `agent:*` | Serialised as a message and injected into the agent's IPC input, same as a regular Slack message |
| `ack:*` | Acknowledged immediately (no agent involvement) — used for informational buttons |

For `agent:*` actions, the payload is formatted as a structured message and dropped into the group's IPC input directory. The agent receives it as:

```
[SLACK_ACTION]
action_id: agent:scale_down
values: {"namespace":"prod","deployment":"api","replicas":"0"}
user: Rahul Purimetla
original_message_ts: 1713400000.123456
```

The agent processes it like a regular message and can call `update_message` to swap the buttons out for a confirmation.

**Modal submissions** use the same path — `payload.type === 'view_submission'` is serialised as `[SLACK_MODAL_SUBMIT]` with the submitted values.

### 3b. Extended Slack channel methods

```typescript
// Send a Block Kit message (returns message timestamp for future updates)
sendBlocks(jid: string, blocks: KnownBlock[], text: string): Promise<string>

// Replace an existing message in-place (use ts from sendBlocks return value)
updateMessage(jid: string, ts: string, blocks: KnownBlock[], text: string): Promise<void>

// Open a modal from an interaction trigger_id (valid for 3 seconds after user action)
openModal(triggerId: string, view: View): Promise<void>

// Reply inside a thread (thread_ts = parent message timestamp)
replyInThread(jid: string, threadTs: string, text: string): Promise<void>

// Upload an image or file to a channel
uploadFile(jid: string, filePath: string, filename: string, title?: string): Promise<void>
```

### 3c. Agent MCP tools (`container/skills/slack-blocks/`)

The agent gets these tools inside the container:

```
mcp__slack_blocks__send_blocks        Send a Block Kit message with interactive elements
mcp__slack_blocks__update_message     Replace a previously sent Block Kit message
mcp__slack_blocks__open_modal         Open a modal dialog (only valid inside an action handler)
mcp__slack_blocks__reply_in_thread    Post a reply inside a thread
mcp__slack_blocks__upload_image       Upload a file/image to the channel
```

**`send_blocks` schema:**
```json
{
  "jid": "slack:C0ATKPXBVFY",
  "text": "fallback for notifications",
  "blocks": [
    {
      "type": "section",
      "text": { "type": "mrkdwn", "text": "*Scale down deployment?*\nNamespace: `prod` / Pod: `api`" }
    },
    {
      "type": "actions",
      "elements": [
        { "type": "button", "text": { "type": "plain_text", "text": "Scale down ✓" }, "style": "danger",   "action_id": "agent:scale_down" },
        { "type": "button", "text": { "type": "plain_text", "text": "Cancel ✗"     }, "style": "primary",  "action_id": "agent:cancel"     }
      ]
    }
  ]
}
```

**`open_modal` schema:**
```json
{
  "trigger_id": "<from action payload>",
  "view": {
    "type": "modal",
    "callback_id": "agent:config_change",
    "title": { "type": "plain_text", "text": "Change config" },
    "submit": { "type": "plain_text", "text": "Apply" },
    "blocks": [
      {
        "type": "input",
        "block_id": "replicas",
        "label": { "type": "plain_text", "text": "Replica count" },
        "element": { "type": "plain_text_input", "action_id": "value" }
      }
    ]
  }
}
```

**`reply_in_thread` schema:**
```json
{
  "jid": "slack:C0ATKPXBVFY",
  "thread_ts": "1713400000.123456",
  "text": "Done. Scaled `api` to 0 replicas in `prod`."
}
```

### 3d. Slash commands

Slash commands (`/andy`, `/andy-status`, `/andy-pods`) are registered in the Slack app and POST to `https://<host>/slack/commands`. The handler formats them as a standard message and injects into the agent's IPC input:

```
[SLASH_COMMAND /andy]
user: Rahul Purimetla
channel: C0ATKPXBVFY
text: get pods in prod namespace
```

Slash command routing rules:
- Any `/andy <text>` goes to the main group agent (same as messaging the main channel)
- `/andy-<group> <text>` routes to the named sub-group if registered

---

## Phase 4: Slack App Configuration

### Add signing secret to `.env`

```bash
SLACK_SIGNING_SECRET=<from app settings → Basic Information → App Credentials>
```

You can find it at **api.slack.com/apps → your app → Basic Information → Signing Secret**.

### Enable Interactivity

1. Go to **api.slack.com/apps → your app → Interactivity & Shortcuts**
2. Toggle **Interactivity** ON
3. Set **Request URL**: `https://<your-host>/slack/actions`
4. Save

### Add slash commands

For each slash command you want:

1. Go to **Slash Commands → Create New Command**
2. Command: `/andy`
3. Request URL: `https://<your-host>/slack/commands`
4. Short description: `Ask Andy`
5. Usage hint: `[your question or command]`
6. Save

### Update OAuth scopes

Go to **OAuth & Permissions → Scopes → Bot Token Scopes** and add:

```
files:write        (for image/file uploads)
```

The following should already be present from `/add-slack`:
```
chat:write
channels:history
groups:history
im:history
channels:read
groups:read
users:read
```

**Reinstall the app** after scope changes — the bot token changes on reinstall. Update `SLACK_BOT_TOKEN` in `.env`.

### Exposing the HTTP server

The interactivity server on port `3000` must be reachable from Slack's servers.

**EC2 (this setup):**
```bash
# Allow inbound TCP 3000 from Slack's IP ranges (or 0.0.0.0/0 for simplicity)
aws ec2 authorize-security-group-ingress \
  --group-id <sg-id> \
  --protocol tcp \
  --port 3000 \
  --cidr 0.0.0.0/0 \
  --region ap-southeast-1
```

Or put NanoClaw behind an HTTPS ALB (recommended for production) and point Slack's Request URL to the ALB URL. The ALB handles TLS termination; Slack requires HTTPS.

**Local development:**
```bash
npx cloudflared tunnel --url http://localhost:3000
# Copy the generated https://*.trycloudflare.com URL → paste into Slack app settings
```

---

## Phase 5: Build, Sync, Restart

```bash
npm run build
cp .env data/env/env   # sync to container env
```

**macOS:**
```bash
launchctl kickstart -k gui/$(id -u)/com.nanoclaw
```

**Linux/EC2:**
```bash
systemctl restart nanoclaw
```

Verify the HTTP server started:
```bash
curl http://localhost:3000/health
# → {"status":"ok"}
```

---

## Phase 6: Verify

### Interactivity test

1. Go to the registered Slack channel
2. Send: `send me a test button`
3. Andy should reply with a Block Kit message containing an Approve/Cancel button
4. Click the button — Andy should acknowledge and update the message

### Slash command test

```
/andy hello
```

Andy should respond in the same channel.

### Thread test

```
/andy reply to this in a thread
```

Andy should post the response as a thread reply under your slash command trigger.

### Image upload test

```
send me a simple chart of pod counts
```

Andy should upload an image attachment to the channel.

---

## Troubleshooting

### Slack says "Your app's request URL didn't respond with 200 OK"

- Check NanoClaw is running: `systemctl is-active nanoclaw`
- Check port 3000 is open: `curl http://localhost:3000/health`
- Check security group allows inbound on 3000
- Slack requires HTTPS on the Request URL — use an ALB or cloudflared tunnel

### "dispatch_failed" in Slack

The action payload was received but the agent took > 3 seconds to respond. Slack requires acknowledgment within 3 seconds. The interactivity server sends an immediate `200 OK` ack, then delivers the payload to the agent asynchronously. If you're seeing this, the ack is not being sent — check the signature verification isn't throwing.

### Modals not opening

`openModal` requires a `trigger_id` which is only valid for **3 seconds** after the user clicked the button. The agent must call `open_modal` immediately in the action handler, not after running commands. If the agent needs to collect data first, send a message asking for info rather than opening a modal.

### Slash commands not routing to agent

Check the slash command's Request URL in the Slack app matches the running NanoClaw host exactly (including scheme and port). Check `SLACK_SIGNING_SECRET` is set correctly — wrong secret causes all interactions to be rejected 403.

### Images not uploading

`files:write` scope must be added and the app must be reinstalled. Run:
```bash
curl -s -F "token=$SLACK_BOT_TOKEN" https://slack.com/api/auth.test | jq '.error'
# should return null
```

---

## Known Limitations

- **Modals require immediate trigger_id**: The 3-second window means the agent can't do work before opening a modal. Use a two-step flow: button → agent responds with confirmation message → separate `/andy confirm` to apply.
- **Block Kit is Slack-only**: `sendBlocks` only works when `channel.name === 'slack'`. For other channels the agent falls back to plain text.
- **File uploads are one-way**: The agent can upload files to Slack but Slack file uploads to the agent (user sends an image) are not handled — files are ignored. Full file ingestion requires separate work.
- **Slash commands are global**: `/andy` fires regardless of which channel it's used in, and always routes to the main group. Per-channel routing would need the channel ID looked up in the registered groups table.
- **No persistent block state**: When the service restarts, `updateMessage` for old messages requires the caller to re-supply the `ts`. The agent's session history should contain it if the conversation is recent enough.
