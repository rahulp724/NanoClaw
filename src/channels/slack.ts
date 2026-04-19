import fs from 'fs';

import { App, LogLevel } from '@slack/bolt';
import type { GenericMessageEvent, BotMessageEvent } from '@slack/types';

import { ASSISTANT_NAME, TRIGGER_PATTERN } from '../config.js';
import { updateChatName } from '../db.js';
import { readEnvFile } from '../env.js';
import { logger } from '../logger.js';
import { registerChannel, ChannelOpts } from './registry.js';
import {
  Channel,
  OnInboundMessage,
  OnChatMetadata,
  RegisteredGroup,
} from '../types.js';

// Slack's chat.postMessage API limits text to ~4000 characters per call.
// Messages exceeding this are split into sequential chunks.
const MAX_MESSAGE_LENGTH = 4000;

// The message subtypes we process. Bolt delivers all subtypes via app.event('message');
// we filter to regular messages (GenericMessageEvent, subtype undefined) and bot messages
// (BotMessageEvent, subtype 'bot_message') so we can track our own output.
type HandledMessageEvent = GenericMessageEvent | BotMessageEvent;

export interface SlackChannelOpts {
  onMessage: OnInboundMessage;
  onChatMetadata: OnChatMetadata;
  registeredGroups: () => Record<string, RegisteredGroup>;
}

export class SlackChannel implements Channel {
  name = 'slack';

  private app: App;
  private botUserId: string | undefined;
  private connected = false;
  private outgoingQueue: Array<{ jid: string; text: string }> = [];
  private flushing = false;
  private userNameCache = new Map<string, string>();

  private opts: SlackChannelOpts;

  constructor(opts: SlackChannelOpts) {
    this.opts = opts;

    // Read tokens from .env (not process.env — keeps secrets off the environment
    // so they don't leak to child processes, matching NanoClaw's security pattern)
    const env = readEnvFile(['SLACK_BOT_TOKEN', 'SLACK_APP_TOKEN']);
    const botToken = env.SLACK_BOT_TOKEN;
    const appToken = env.SLACK_APP_TOKEN;

    if (!botToken || !appToken) {
      throw new Error(
        'SLACK_BOT_TOKEN and SLACK_APP_TOKEN must be set in .env',
      );
    }

    this.app = new App({
      token: botToken,
      appToken,
      socketMode: true,
      logLevel: LogLevel.ERROR,
    });

    this.setupEventHandlers();
    this.setupInteractivityHandlers();
  }

  private setupInteractivityHandlers(): void {
    // Button clicks, dropdown selections — action_id must start with "agent:"
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    this.app.action(/^agent:.*/, async ({ action, body, ack }: any) => {
      await ack();

      const channelId = body.channel?.id || body.container?.channel_id;
      if (!channelId) return;
      const jid = `slack:${channelId}`;
      const groups = this.opts.registeredGroups();
      if (!groups[jid]) return;

      const userId: string = body.user?.id || '';
      const userName: string =
        body.user?.name || body.user?.username || userId || 'unknown';
      const originalTs: string = body.message?.ts || '';

      // Collect state values (dropdowns, text inputs)
      const collectedValues: Record<string, string> = {};
      const stateValues = body.state?.values as
        | Record<string, Record<string, { value?: string; selected_option?: { value: string } }>>
        | undefined;
      if (stateValues) {
        for (const blockValues of Object.values(stateValues)) {
          for (const [id, v] of Object.entries(blockValues)) {
            collectedValues[id] =
              v.value || v.selected_option?.value || '';
          }
        }
      }

      const lines = [
        '[SLACK_ACTION]',
        `action_id: ${action.action_id}`,
        `values: ${JSON.stringify(collectedValues)}`,
        `user: ${userName}`,
      ];
      if (originalTs) lines.push(`original_message_ts: ${originalTs}`);
      // Provide trigger_id so agent can open a modal immediately (3-second window)
      if (body.trigger_id) lines.push(`trigger_id: ${body.trigger_id}`);

      this.opts.onMessage(jid, {
        id: `action-${action.action_ts || String(Date.now())}`,
        chat_jid: jid,
        sender: userId,
        sender_name: userName,
        content: lines.join('\n'),
        timestamp: new Date().toISOString(),
        is_from_me: false,
        is_bot_message: false,
      });
    });

    // Modal submissions — callback_id must start with "agent:"
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    this.app.view(/^agent:.*/, async ({ view, body, ack }: any) => {
      await ack();

      // Channel JID is stored in private_metadata when the modal was opened
      const privateMetadata: string = view.private_metadata || '';
      let jid: string | undefined;
      if (privateMetadata) {
        try {
          const meta = JSON.parse(privateMetadata) as Record<string, string>;
          jid = meta.jid;
        } catch {
          jid = privateMetadata; // treat as bare JID
        }
      }
      if (!jid) return;
      const groups = this.opts.registeredGroups();
      if (!groups[jid]) return;

      const userId: string = body.user?.id || '';
      const userName: string = body.user?.name || userId || 'unknown';

      this.opts.onMessage(jid, {
        id: `modal-${Date.now()}`,
        chat_jid: jid,
        sender: userId,
        sender_name: userName,
        content: [
          '[SLACK_MODAL_SUBMIT]',
          `callback_id: ${view.callback_id}`,
          `values: ${JSON.stringify(view.state?.values || {})}`,
          `user: ${userName}`,
        ].join('\n'),
        timestamp: new Date().toISOString(),
        is_from_me: false,
        is_bot_message: false,
      });
    });

    // Slash commands — matches any /command
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    this.app.command(/\/.*/ as any, async ({ command, ack }: any) => {
      await ack();

      const channelJid = `slack:${command.channel_id}`;
      const groups = this.opts.registeredGroups();

      let targetJid: string;
      if (groups[channelJid]) {
        targetJid = channelJid;
      } else {
        const mainEntry = Object.entries(groups).find(([, g]) => g.isMain);
        if (!mainEntry) {
          logger.warn(
            { command: command.command },
            'Slash command: no registered group found',
          );
          return;
        }
        targetJid = mainEntry[0];
      }

      this.opts.onMessage(targetJid, {
        id: `cmd-${Date.now()}`,
        chat_jid: targetJid,
        sender: command.user_id,
        sender_name: command.user_name || command.user_id || 'unknown',
        content: [
          `[SLASH_COMMAND ${command.command}]`,
          `user: ${command.user_name}`,
          `channel: ${command.channel_id}`,
          `text: ${command.text}`,
        ].join('\n'),
        timestamp: new Date().toISOString(),
        is_from_me: false,
        is_bot_message: false,
      });
    });
  }

  private setupEventHandlers(): void {
    // Use app.event('message') instead of app.message() to capture all
    // message subtypes including bot_message (needed to track our own output)
    this.app.event('message', async ({ event }) => {
      // Bolt's event type is the full MessageEvent union (17+ subtypes).
      // We filter on subtype first, then narrow to the two types we handle.
      const subtype = (event as { subtype?: string }).subtype;
      if (subtype && subtype !== 'bot_message') return;

      // After filtering, event is either GenericMessageEvent or BotMessageEvent
      const msg = event as HandledMessageEvent;

      if (!msg.text) return;

      // Threaded replies are flattened into the channel conversation.
      // The agent sees them alongside channel-level messages; responses
      // always go to the channel, not back into the thread.

      const jid = `slack:${msg.channel}`;
      const timestamp = new Date(parseFloat(msg.ts) * 1000).toISOString();
      const isGroup = msg.channel_type !== 'im';

      // Always report metadata for group discovery
      this.opts.onChatMetadata(jid, timestamp, undefined, 'slack', isGroup);

      // Only deliver full messages for registered groups
      const groups = this.opts.registeredGroups();
      if (!groups[jid]) return;

      const isBotMessage = !!msg.bot_id || msg.user === this.botUserId;

      let senderName: string;
      if (isBotMessage) {
        senderName = ASSISTANT_NAME;
      } else {
        senderName =
          (msg.user ? await this.resolveUserName(msg.user) : undefined) ||
          msg.user ||
          'unknown';
      }

      // Translate Slack <@UBOTID> mentions into TRIGGER_PATTERN format.
      // Slack encodes @mentions as <@U12345>, which won't match TRIGGER_PATTERN
      // (e.g., ^@<ASSISTANT_NAME>\b), so we prepend the trigger when the bot is @mentioned.
      let content = msg.text;
      if (this.botUserId && !isBotMessage) {
        const mentionPattern = `<@${this.botUserId}>`;
        if (
          content.includes(mentionPattern) &&
          !TRIGGER_PATTERN.test(content)
        ) {
          content = `@${ASSISTANT_NAME} ${content}`;
        }
      }

      this.opts.onMessage(jid, {
        id: msg.ts,
        chat_jid: jid,
        sender: msg.user || msg.bot_id || '',
        sender_name: senderName,
        content,
        timestamp,
        is_from_me: isBotMessage,
        is_bot_message: isBotMessage,
      });
    });
  }

  async connect(): Promise<void> {
    await this.app.start();

    // Get bot's own user ID for self-message detection.
    // Resolve this BEFORE setting connected=true so that messages arriving
    // during startup can correctly detect bot-sent messages.
    try {
      const auth = await this.app.client.auth.test();
      this.botUserId = auth.user_id as string;
      logger.info({ botUserId: this.botUserId }, 'Connected to Slack');
    } catch (err) {
      logger.warn({ err }, 'Connected to Slack but failed to get bot user ID');
    }

    this.connected = true;

    // Flush any messages queued before connection
    await this.flushOutgoingQueue();

    // Sync channel names on startup
    await this.syncChannelMetadata();
  }

  async sendMessage(jid: string, text: string): Promise<void> {
    const channelId = jid.replace(/^slack:/, '');

    if (!this.connected) {
      this.outgoingQueue.push({ jid, text });
      logger.info(
        { jid, queueSize: this.outgoingQueue.length },
        'Slack disconnected, message queued',
      );
      return;
    }

    try {
      // Slack limits messages to ~4000 characters; split if needed
      if (text.length <= MAX_MESSAGE_LENGTH) {
        await this.app.client.chat.postMessage({ channel: channelId, text });
      } else {
        for (let i = 0; i < text.length; i += MAX_MESSAGE_LENGTH) {
          await this.app.client.chat.postMessage({
            channel: channelId,
            text: text.slice(i, i + MAX_MESSAGE_LENGTH),
          });
        }
      }
      logger.info({ jid, length: text.length }, 'Slack message sent');
    } catch (err) {
      this.outgoingQueue.push({ jid, text });
      logger.warn(
        { jid, err, queueSize: this.outgoingQueue.length },
        'Failed to send Slack message, queued',
      );
    }
  }

  isConnected(): boolean {
    return this.connected;
  }

  ownsJid(jid: string): boolean {
    return jid.startsWith('slack:');
  }

  async disconnect(): Promise<void> {
    this.connected = false;
    await this.app.stop();
  }

  // Slack does not expose a typing indicator API for bots.
  // This no-op satisfies the Channel interface so the orchestrator
  // doesn't need channel-specific branching.
  async setTyping(_jid: string, _isTyping: boolean): Promise<void> {
    // no-op: Slack Bot API has no typing indicator endpoint
  }

  /**
   * Sync channel metadata from Slack.
   * Fetches channels the bot is a member of and stores their names in the DB.
   */
  async syncChannelMetadata(): Promise<void> {
    try {
      logger.info('Syncing channel metadata from Slack...');
      let cursor: string | undefined;
      let count = 0;

      do {
        const result = await this.app.client.conversations.list({
          types: 'public_channel,private_channel',
          exclude_archived: true,
          limit: 200,
          cursor,
        });

        for (const ch of result.channels || []) {
          if (ch.id && ch.name && ch.is_member) {
            updateChatName(`slack:${ch.id}`, ch.name);
            count++;
          }
        }

        cursor = result.response_metadata?.next_cursor || undefined;
      } while (cursor);

      logger.info({ count }, 'Slack channel metadata synced');
    } catch (err) {
      logger.error({ err }, 'Failed to sync Slack channel metadata');
    }
  }

  private async resolveUserName(userId: string): Promise<string | undefined> {
    if (!userId) return undefined;

    const cached = this.userNameCache.get(userId);
    if (cached) return cached;

    try {
      const result = await this.app.client.users.info({ user: userId });
      const name = result.user?.real_name || result.user?.name;
      if (name) this.userNameCache.set(userId, name);
      return name;
    } catch (err) {
      logger.debug({ userId, err }, 'Failed to resolve Slack user name');
      return undefined;
    }
  }

  getClient() {
    return this.app.client;
  }

  async sendBlocks(
    jid: string,
    blocks: unknown[],
    text: string,
  ): Promise<string> {
    const channelId = jid.replace(/^slack:/, '');
    const result = await this.app.client.chat.postMessage({
      channel: channelId,
      text,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      blocks: blocks as any,
    });
    return (result.ts as string) || '';
  }

  async updateMessage(
    jid: string,
    ts: string,
    blocks: unknown[],
    text: string,
  ): Promise<void> {
    const channelId = jid.replace(/^slack:/, '');
    await this.app.client.chat.update({
      channel: channelId,
      ts,
      text,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      blocks: blocks as any,
    });
  }

  async openModal(triggerId: string, view: unknown): Promise<void> {
    await this.app.client.views.open({
      trigger_id: triggerId,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      view: view as any,
    });
  }

  async replyInThread(
    jid: string,
    threadTs: string,
    text: string,
  ): Promise<void> {
    const channelId = jid.replace(/^slack:/, '');
    await this.app.client.chat.postMessage({
      channel: channelId,
      thread_ts: threadTs,
      text,
    });
  }

  async uploadFile(
    jid: string,
    filePath: string,
    filename: string,
    title?: string,
  ): Promise<void> {
    const channelId = jid.replace(/^slack:/, '');
    await this.app.client.files.uploadV2({
      channel_id: channelId,
      file: fs.readFileSync(filePath),
      filename,
      title: title || filename,
    });
  }

  private async flushOutgoingQueue(): Promise<void> {
    if (this.flushing || this.outgoingQueue.length === 0) return;
    this.flushing = true;
    try {
      logger.info(
        { count: this.outgoingQueue.length },
        'Flushing Slack outgoing queue',
      );
      while (this.outgoingQueue.length > 0) {
        const item = this.outgoingQueue.shift()!;
        const channelId = item.jid.replace(/^slack:/, '');
        await this.app.client.chat.postMessage({
          channel: channelId,
          text: item.text,
        });
        logger.info(
          { jid: item.jid, length: item.text.length },
          'Queued Slack message sent',
        );
      }
    } finally {
      this.flushing = false;
    }
  }
}

registerChannel('slack', (opts: ChannelOpts) => {
  const envVars = readEnvFile(['SLACK_BOT_TOKEN', 'SLACK_APP_TOKEN']);
  if (!envVars.SLACK_BOT_TOKEN || !envVars.SLACK_APP_TOKEN) {
    logger.warn('Slack: SLACK_BOT_TOKEN or SLACK_APP_TOKEN not set');
    return null;
  }
  return new SlackChannel(opts);
});
