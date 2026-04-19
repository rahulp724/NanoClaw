import crypto from 'crypto';
import http from 'http';

import { SLACK_INTERACTIVITY_PORT, SLACK_SIGNING_SECRET } from './config.js';
import { logger } from './logger.js';
import { NewMessage, RegisteredGroup } from './types.js';

function readBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (chunk) => (body += chunk.toString()));
    req.on('end', () => resolve(body));
    req.on('error', reject);
  });
}

function verifySignature(
  rawBody: string,
  timestamp: string,
  signature: string,
): boolean {
  const age = Math.abs(Date.now() / 1000 - parseInt(timestamp, 10));
  if (age > 300) return false;
  const baseString = `v0:${timestamp}:${rawBody}`;
  const hmac = `v0=${crypto.createHmac('sha256', SLACK_SIGNING_SECRET).update(baseString).digest('hex')}`;
  try {
    return crypto.timingSafeEqual(Buffer.from(hmac), Buffer.from(signature));
  } catch {
    return false;
  }
}

async function handleAction(
  rawBody: string,
  onMessage: (jid: string, msg: NewMessage) => void,
  registeredGroups: () => Record<string, RegisteredGroup>,
): Promise<void> {
  const params = new URLSearchParams(rawBody);
  const payloadStr = params.get('payload');
  if (!payloadStr) return;

  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(payloadStr);
  } catch {
    logger.warn('Failed to parse Slack action payload');
    return;
  }

  const groups = registeredGroups();

  if (payload.type === 'block_actions') {
    const payloadAny = payload as Record<string, Record<string, string>>;
    const channelId =
      (payload.channel as Record<string, string> | undefined)?.id ||
      (payload.container as Record<string, string> | undefined)?.channel_id;
    if (!channelId) {
      logger.warn('Slack action missing channel ID');
      return;
    }
    const jid = `slack:${channelId}`;
    if (!groups[jid]) {
      logger.debug({ jid }, 'Slack action for unregistered channel — ignored');
      return;
    }

    const user = payload.user as Record<string, string> | undefined;
    const userId = user?.id || '';
    const userName =
      user?.name || user?.username || userId || 'unknown';
    const originalTs =
      (payload.message as Record<string, string> | undefined)?.ts || '';

    // Collect state values (dropdown selections etc.)
    const stateValues = (
      payload.state as
        | {
            values?: Record<
              string,
              Record<
                string,
                { value?: string; selected_option?: { value: string } }
              >
            >;
          }
        | undefined
    )?.values;
    const collectedValues: Record<string, string> = {};
    if (stateValues) {
      for (const blockValues of Object.values(stateValues)) {
        for (const [actionId, actionValue] of Object.entries(blockValues)) {
          collectedValues[actionId] =
            actionValue.value ||
            actionValue.selected_option?.value ||
            '';
        }
      }
    }

    for (const action of (payload.actions as Array<Record<string, string>>) ||
      []) {
      if (!action.action_id?.startsWith('agent:')) continue;

      const lines = [
        '[SLACK_ACTION]',
        `action_id: ${action.action_id}`,
        `values: ${JSON.stringify(collectedValues)}`,
        `user: ${userName}`,
      ];
      if (originalTs) lines.push(`original_message_ts: ${originalTs}`);

      onMessage(jid, {
        id: `action-${payloadAny.action_ts || String(Date.now())}`,
        chat_jid: jid,
        sender: userId,
        sender_name: userName,
        content: lines.join('\n'),
        timestamp: new Date().toISOString(),
        is_from_me: false,
        is_bot_message: false,
      });
    }
  } else if (payload.type === 'view_submission') {
    const view = payload.view as Record<string, unknown> | undefined;
    const privateMetadata = view?.private_metadata as string | undefined;
    let jid: string | undefined;
    if (privateMetadata) {
      try {
        const meta = JSON.parse(privateMetadata) as Record<string, string>;
        jid = meta.jid;
      } catch {
        // private_metadata is a bare JID
        jid = privateMetadata;
      }
    }
    if (!jid || !groups[jid]) {
      logger.warn(
        { jid },
        'Modal submission: missing or unregistered channel in private_metadata',
      );
      return;
    }

    const user = payload.user as Record<string, string> | undefined;
    const userId = user?.id || '';
    const userName = user?.name || userId || 'unknown';
    const callbackId = (view?.callback_id as string) || '';

    const stateValues =
      (view?.state as { values?: Record<string, unknown> } | undefined)
        ?.values || {};

    onMessage(jid, {
      id: `modal-${Date.now()}`,
      chat_jid: jid,
      sender: userId,
      sender_name: userName,
      content: [
        '[SLACK_MODAL_SUBMIT]',
        `callback_id: ${callbackId}`,
        `values: ${JSON.stringify(stateValues)}`,
        `user: ${userName}`,
      ].join('\n'),
      timestamp: new Date().toISOString(),
      is_from_me: false,
      is_bot_message: false,
    });
  }
}

async function handleCommand(
  rawBody: string,
  onMessage: (jid: string, msg: NewMessage) => void,
  registeredGroups: () => Record<string, RegisteredGroup>,
): Promise<void> {
  const params = new URLSearchParams(rawBody);
  const command = params.get('command') || '/andy';
  const text = params.get('text') || '';
  const channelId = params.get('channel_id') || '';
  const userId = params.get('user_id') || '';
  const userName = params.get('user_name') || userId || 'unknown';

  const groups = registeredGroups();
  const channelJid = `slack:${channelId}`;

  let targetJid: string;
  if (groups[channelJid]) {
    targetJid = channelJid;
  } else {
    const mainEntry = Object.entries(groups).find(([, g]) => g.isMain);
    if (!mainEntry) {
      logger.warn({ command, channelId }, 'Slash command: no registered group found');
      return;
    }
    targetJid = mainEntry[0];
  }

  onMessage(targetJid, {
    id: `cmd-${Date.now()}`,
    chat_jid: targetJid,
    sender: userId,
    sender_name: userName,
    content: [
      `[SLASH_COMMAND ${command}]`,
      `user: ${userName}`,
      `channel: ${channelId}`,
      `text: ${text}`,
    ].join('\n'),
    timestamp: new Date().toISOString(),
    is_from_me: false,
    is_bot_message: false,
  });
}

export function startInteractivityServer(
  onMessage: (jid: string, msg: NewMessage) => void,
  registeredGroups: () => Record<string, RegisteredGroup>,
): void {
  if (!SLACK_SIGNING_SECRET) {
    logger.warn(
      'SLACK_SIGNING_SECRET not set — Slack interactivity server not started. ' +
        'Add it to .env to enable buttons, slash commands, and modals.',
    );
    return;
  }

  const server = http.createServer(async (req, res) => {
    if (req.method === 'GET' && req.url === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'ok' }));
      return;
    }

    if (req.method !== 'POST') {
      res.writeHead(405);
      res.end('Method Not Allowed');
      return;
    }

    let rawBody: string;
    try {
      rawBody = await readBody(req);
    } catch {
      res.writeHead(400);
      res.end('Bad Request');
      return;
    }

    const timestamp =
      (req.headers['x-slack-request-timestamp'] as string) || '';
    const signature = (req.headers['x-slack-signature'] as string) || '';

    if (!verifySignature(rawBody, timestamp, signature)) {
      logger.warn(
        { url: req.url, timestamp },
        'Slack interactivity: invalid signature',
      );
      res.writeHead(403);
      res.end('Forbidden');
      return;
    }

    // Ack immediately — Slack requires a response within 3 seconds
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end('{}');

    const url = req.url?.split('?')[0];
    setImmediate(async () => {
      try {
        if (url === '/slack/actions') {
          await handleAction(rawBody, onMessage, registeredGroups);
        } else if (url === '/slack/commands') {
          await handleCommand(rawBody, onMessage, registeredGroups);
        }
      } catch (err) {
        logger.error({ err, url }, 'Error processing Slack interactivity payload');
      }
    });
  });

  server.on('error', (err) => {
    logger.error({ err }, 'Slack interactivity server error');
  });

  server.listen(SLACK_INTERACTIVITY_PORT, () => {
    logger.info(
      { port: SLACK_INTERACTIVITY_PORT },
      'Slack interactivity server started',
    );
  });
}
