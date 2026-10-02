import { dataDirectory, provisionToken } from './services/token-store.js';
import { startHttp } from './http/app.js';

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const operation = args[0] ?? 'serve';
  const option = (name: string) => { const index = args.indexOf(name); return index >= 0 ? args[index + 1] : undefined; };
  const directory = dataDirectory(option('--data-dir'));
  if (operation === 'init' || operation === 'rotate') {
    const token = provisionToken(directory, operation === 'rotate');
    if (!args.includes('--quiet')) process.stdout.write(`Bearer token (local owner only): ${token}\n`);
    return;
  }
  if (operation !== 'serve') throw new Error('Use serve, init, or rotate.');
  const port = Number(option('--port') ?? 8765);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('port must be an integer from 1024 to 65535.');
  const token = provisionToken(directory);
  const { shutdown } = await startHttp(port, token);
  process.stdout.write(`pc-control-mcp listening on http://127.0.0.1:${port}/mcp\n`);
  const finish = () => void shutdown().then(() => process.exit(0)).catch(() => process.stderr.write('Graceful shutdown failed.\n'));
  process.once('SIGINT', finish);
  process.once('SIGTERM', finish);
}
main().catch(() => { process.stderr.write('MCP startup failed. Check the port, token file and Windows account permissions.\n'); process.exitCode = 1; });
