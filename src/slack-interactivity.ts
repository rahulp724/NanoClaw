/**
 * Slack interactivity HTTP server.
 *
 * With Socket Mode enabled, Slack delivers button clicks, modal submissions,
 * and slash commands through the existing Bolt WebSocket — not HTTP. Those
 * handlers live in src/channels/slack.ts (setupInteractivityHandlers).
 *
 * This server exists for:
 *   GET /health — liveness probe for ALB health checks and monitoring
 */
import http from 'http';

import { SLACK_INTERACTIVITY_PORT } from './config.js';
import { logger } from './logger.js';
import { NewMessage, RegisteredGroup } from './types.js';

export function startInteractivityServer(
  _onMessage: (jid: string, msg: NewMessage) => void,
  _registeredGroups: () => Record<string, RegisteredGroup>,
): void {
  const server = http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'ok' }));
      return;
    }
    res.writeHead(404);
    res.end('Not Found');
  });

  server.on('error', (err) => {
    logger.error({ err }, 'Slack interactivity server error');
  });

  server.listen(SLACK_INTERACTIVITY_PORT, () => {
    logger.info(
      { port: SLACK_INTERACTIVITY_PORT },
      'Slack health server started',
    );
  });
}
