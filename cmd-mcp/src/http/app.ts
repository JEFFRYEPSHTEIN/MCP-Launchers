import express from 'express';
import type { Server } from 'node:http';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { createMcpServer } from '../mcp/server.js';
import { bearerValidator } from '../services/token-store.js';
import { Sessions } from '../services/sessions.js';

export async function startHttp(port: number, token: string): Promise<{ listener: Server; shutdown: () => Promise<void> }> {
  const app = express();
  app.disable('x-powered-by');
  const started = new Date().toISOString();
  const authorized = bearerValidator(token);
  const sessions = new Sessions();
  const allowedHosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`, '127.0.0.1', 'localhost']);
  const origins = new Set([`http://127.0.0.1:${port}`, `http://localhost:${port}`, 'https://app.notion.com', 'https://www.notion.so', 'https://notion.so',
    ...(process.env.PC_MCP_ALLOWED_ORIGINS?.split(',').map(s => s.trim()).filter(Boolean) ?? [])]);
  app.use((req, res, next) => {
    if (!allowedHosts.has((req.headers.host ?? '').toLowerCase()) || (req.headers.origin && !origins.has(req.headers.origin))) {
      res.status(403).json({ error: 'Host or Origin is not allowed.' }); return;
    }
    res.setHeader('Cache-Control', 'no-store');
    next();
  });
  app.get('/health', (_req, res) => res.json({ ok: true, service: 'pc-control-mcp', pid: process.pid, port, started_at: started }));
  app.use((req, res, next) => {
    if (!authorized(req.headers.authorization)) {
      res.setHeader('WWW-Authenticate', 'Bearer');
      res.status(401).json({ error: 'Valid bearer authentication is required.' }); return;
    }
    next();
  });
  app.use(express.json({ limit: '128kb' }));
  let closing: Promise<void> | undefined;
  let listener: Server;
  const shutdown = (): Promise<void> => closing ??= (async () => {
    // Keep the listener alive if the OS refuses to stop an owned process, so the owner can retry.
    await sessions.shutdown();
    await new Promise<void>(resolve => { listener.close(() => resolve()); listener.closeIdleConnections(); });
  })().catch(error => { closing = undefined; throw error; });
  app.post('/admin/shutdown', (req, res) => {
    if (req.headers['cf-connecting-ip'] || req.headers['x-forwarded-for'] || !['127.0.0.1', '::ffff:127.0.0.1', '::1'].includes(req.socket.remoteAddress ?? '')) {
      res.status(403).json({ error: 'Shutdown is local only.' }); return;
    }
    res.json({ stopping: true });
    setImmediate(() => void shutdown().then(() => process.exit(0)).catch(() => process.stderr.write('Graceful shutdown failed.\n')));
  });
  app.post('/mcp', async (req, res) => {
    const server = createMcpServer(sessions, token);
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    res.on('close', () => { void transport.close(); void server.close(); });
    try { await server.connect(transport); await transport.handleRequest(req, res, req.body); }
    catch {
      if (!res.headersSent) res.status(500).json({ error: 'MCP request failed.' });
    }
  });
  app.all('/mcp', (_req, res) => res.status(405).set('Allow', 'POST').json({ error: 'Use MCP Streamable HTTP POST with JSON responses.' }));
  app.use((_req, res) => res.status(404).json({ error: 'Unknown endpoint.' }));
  app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    const status = (error as { status?: number })?.status === 413 ? 413 : 400;
    if (!res.headersSent) res.status(status).json({ error: status === 413 ? 'Request body is too large.' : 'Invalid JSON request.' });
  });
  listener = await new Promise<Server>((resolve, reject) => {
    const result = app.listen(port, '127.0.0.1', () => resolve(result));
    result.once('error', reject);
  });
  return { listener, shutdown };
}
