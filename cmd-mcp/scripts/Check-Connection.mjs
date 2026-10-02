import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const directory = process.env.PC_MCP_DATA_DIR ?? path.join(process.env.LOCALAPPDATA, 'PcControlMcp');
const parse = async name => JSON.parse((await readFile(path.join(directory, name), 'utf8')).replace(/^\uFEFF/, ''));
const { endpoint } = await parse('connection.json');
const { token } = await parse('token.json');
const client = new Client({ name: 'local-owner-connection-check', version: '1.0.0' });
try {
  const denied = await fetch(endpoint, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}', signal: AbortSignal.timeout(15000) });
  if (denied.status !== 401) throw new Error(`Unexpected unauthenticated status: ${denied.status}`);
  await client.connect(new StreamableHTTPClientTransport(new URL(endpoint), { requestInit: { headers: { Authorization: `Bearer ${token}` } } }));
  const { tools } = await client.listTools();
  const result = await client.callTool({ name: 'pc_run_command', arguments: { command: 'echo CMD_MCP_OK', wait_ms: 10000 } });
  if (result.isError || result.structuredContent?.exit_code !== 0 || !result.structuredContent?.stdout?.includes('CMD_MCP_OK')) throw new Error('Harmless CMD echo failed.');
  console.log(JSON.stringify({ endpoint, authenticated: true, unauthorized_status: denied.status, tools: tools.length, command: 'CMD_MCP_OK', exit_code: result.structuredContent.exit_code }));
} catch (error) {
  console.error('Connection check failed:', String(error.message).split(token).join('[redacted]'));
  process.exitCode = 1;
} finally { await client.close(); }
