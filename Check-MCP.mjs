import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ids = ['Filesystem', 'Blender', 'Roblox-Studio', 'Rojo'];
const diagnosticTools = {
  Filesystem: 'list_allowed_directories', Blender: 'get_scene_info',
  'Roblox-Studio': 'roblox_list_roblox_studios', Rojo: 'rojo_status',
};

export function canonicalEndpoint(connection) {
  if (connection?.running !== true) throw new Error('Connection is not marked running');
  const base = new URL(connection.baseUrl);
  const endpoint = new URL(connection.serverUrl);
  if (base.protocol !== 'https:' || !/^[a-z0-9-]+\.trycloudflare\.com$/.test(base.hostname)
      || base.port || base.pathname !== '/' || base.search || base.hash || base.username || base.password
      || endpoint.origin !== base.origin || endpoint.pathname !== '/mcp'
      || endpoint.search || endpoint.hash || endpoint.username || endpoint.password) {
    throw new Error('Expected a canonical HTTPS trycloudflare.com /mcp endpoint');
  }
  return endpoint;
}

export function textContent(response) {
  return (response?.content ?? []).filter(item => item.type === 'text').map(item => item.text).join('\n');
}

export function decodeResponse(response) {
  if (typeof response?.structuredContent?.result === 'string') {
    try { return JSON.parse(response.structuredContent.result); } catch { return response.structuredContent; }
  }
  if (response?.structuredContent) return response.structuredContent;
  try { return JSON.parse(textContent(response)); } catch { return null; }
}

export function toolFailure(response) {
  const data = decodeResponse(response);
  const message = textContent(response).trim();
  if (response?.isError || /^Error\b/i.test(message) || data?.ok === false || data?.status === 'error') {
    return message || 'The diagnostic tool returned an error';
  }
  return null;
}

export function redact(value, secrets = []) {
  let output = String(value);
  for (const secret of secrets.filter(Boolean)) {
    output = output.replaceAll(String(secret), '[REDACTED]').replaceAll(encodeURIComponent(secret), '[REDACTED]');
  }
  return output.replace(/\bBearer\s+[^\s"'<>]+/gi, 'Bearer [REDACTED]')
    .replace(/\b[a-f0-9]{64}\b/gi, '[REDACTED]');
}

async function readJson(filename) {
  return JSON.parse((await fs.readFile(filename, 'utf8')).replace(/^\uFEFF/, ''));
}

function samePath(left, right) {
  return typeof left === 'string' && typeof right === 'string'
    && path.resolve(left).toLowerCase() === path.resolve(right).toLowerCase();
}

async function loadSdk(servers) {
  for (const server of servers) {
    const sdk = path.join(server.projectDirectory, 'node_modules/@modelcontextprotocol/sdk/dist/esm');
    try {
      await fs.access(path.join(sdk, 'client/streamableHttp.js'));
      const [{ Client }, { StreamableHTTPClientTransport }] = await Promise.all([
        import(pathToFileURL(path.join(sdk, 'client/index.js'))),
        import(pathToFileURL(path.join(sdk, 'client/streamableHttp.js'))),
      ]);
      return { Client, StreamableHTTPClientTransport };
    } catch { /* Try another existing installation. */ }
  }
  throw new Error('Installed MCP SDK was not found in the configured server packages');
}

async function checkServer(record, sdk, profile, secrets) {
  const { server, config, connection } = record;
  const result = {
    id: server.id, ok: false, localHealthy: false, publicHealthy: false,
    protocolHealthy: false, toolHealthy: false, applicationReady: null, stage: 'configuration',
  };
  let client;
  try {
    if (record.error) throw new Error(record.error);
    if (!Number.isInteger(config.port) || config.port < 1024 || config.port > 65535 || !config.token) {
      throw new Error('Runtime port or Bearer key is missing or invalid');
    }
    const endpoint = canonicalEndpoint(connection);
    result.endpoint = endpoint.href;
    const headers = { Authorization: `Bearer ${config.token}` };
    result.stage = 'local identity';
    const local = await fetch(`http://127.0.0.1:${config.port}/_status`, {
      headers, signal: AbortSignal.timeout(4000),
    });
    const state = await local.json();
    if (state.server !== server.serverIdentity) throw new Error('The local service identity does not match');
    if (!local.ok || state.ok !== true) throw new Error('The local MCP gateway reports unhealthy');
    result.localHealthy = true;
    result.stage = 'public HTTPS';
    const publicResponse = await fetch(new URL('/health', endpoint), { signal: AbortSignal.timeout(6000) });
    if (!publicResponse.ok || (await publicResponse.json()).ok !== true) throw new Error('HTTPS health check failed');
    result.publicHealthy = true;
    result.stage = 'MCP initialize';
    client = new sdk.Client({ name: 'mcp-commands-readonly-check', version: '1.0.0' }, { capabilities: {} });
    await client.connect(new sdk.StreamableHTTPClientTransport(endpoint, { requestInit: { headers } }), { timeout: 15000 });
    result.stage = 'MCP tools/list';
    const listing = await client.listTools({}, { timeout: 15000 });
    result.protocolHealthy = true;
    result.toolCount = listing.tools.length;
    const tool = diagnosticTools[server.id];
    if (!listing.tools.some(item => item.name === tool)) throw new Error('Required read-only diagnostic tool is missing');
    result.stage = tool;
    const args = server.id === 'Blender'
      ? { user_prompt: 'Read-only connection check: inspect the current scene; do not change or save anything.' }
      : {};
    const response = await client.callTool({ name: tool, arguments: args }, undefined, { timeout: 25000 });
    const failure = toolFailure(response);
    if (failure) {
      result.applicationReady = false;
      throw new Error(failure);
    }
    result.toolHealthy = true;
    result.applicationReady = true;
    const data = decodeResponse(response);
    if (server.id === 'Filesystem') {
      result.allowedDirectories = textContent(response).split(/\r?\n/).map(line => line.trim()).filter(line => path.isAbsolute(line));
      if (result.allowedDirectories.length !== 1 || !samePath(result.allowedDirectories[0], config.allowedDirectory)) {
        result.applicationReady = false;
        result.limitation = 'Reported allowed directories differ from the configured folder';
      }
    } else if (server.id === 'Blender') {
      result.sceneName = data?.name ?? null;
      result.objectCount = data?.object_count ?? null;
    } else if (server.id === 'Roblox-Studio') {
      if (!Array.isArray(data?.studios)) throw new Error('Studio list response could not be decoded');
      result.studiosCount = data.studios.length;
      if (result.studiosCount === 0) {
        result.applicationReady = false;
        result.limitation = 'Open a Place in Studio and enable Studio as MCP server in Assistant settings';
      }
    } else if (server.id === 'Rojo') {
      result.projectRoot = data?.projectRoot ?? null;
      result.version = data?.version ?? null;
      result.serveState = data?.serving?.state ?? null;
      if (!result.projectRoot || !result.version) throw new Error('Rojo status response could not be decoded');
      if (profile?.projectRoot && !samePath(result.projectRoot, profile.projectRoot)) {
        result.applicationReady = false;
        result.expectedProjectRoot = profile.projectRoot;
        result.limitation = 'MCP targets a different project. Run MCP-Commands.ps1 Start Rojo to apply the ARC profile';
      } else if (result.serveState !== 'running') {
        result.limitation = 'MCP is callable; synchronization is stopped. Use rojo_serve to start it';
      }
    }
    result.ok = true;
    result.stage = 'read-only tool call complete';
  } catch (error) {
    result.error = redact(error.message ?? error, secrets).slice(0, 1200);
  } finally {
    if (client) await client.close().catch(() => {});
  }
  return result;
}

async function main(argv) {
  const directory = path.dirname(fileURLToPath(import.meta.url));
  const options = {
    server: 'All', config: path.join(directory, '.runtime/servers.json'),
    report: path.join(directory, '.runtime/mcp-command-status.json'),
    profile: path.join(directory, '.runtime/arc-command-settings.json'),
  };
  let explicitProfile = false;
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]?.replace(/^--/, '');
    if (!Object.hasOwn(options, key) || !argv[index + 1]) throw new Error('Invalid diagnostic arguments');
    options[key] = argv[index + 1];
    if (key === 'profile') explicitProfile = true;
  }
  if (![...ids, 'All'].includes(options.server)) throw new Error('Unknown server selection');
  const servers = await readJson(options.config);
  if (!Array.isArray(servers) || !servers.length) throw new Error('Server mapping must be a nonempty array');
  const seen = new Set();
  for (const server of servers) {
    if (!ids.includes(server.id) || seen.has(server.id) || !server.serverIdentity
        || typeof server.projectDirectory !== 'string' || !path.isAbsolute(server.projectDirectory)) {
      throw new Error('Invalid or duplicate server definition');
    }
    seen.add(server.id);
  }
  const selected = servers.filter(server => options.server === 'All' || server.id === options.server);
  if (!selected.length) throw new Error('No server matches the selection');
  const sdk = await loadSdk(servers);
  let profile;
  if (explicitProfile || samePath(options.config, path.join(directory, '.runtime/servers.json'))) {
    try { profile = await readJson(options.profile); } catch { /* Profile is optional. */ }
  }
  const records = await Promise.all(selected.map(async server => {
    try {
      return {
        server, config: await readJson(path.join(server.projectDirectory, '.runtime/config.json')),
        connection: await readJson(path.join(server.projectDirectory, '.runtime/connection.json')),
      };
    } catch { return { server, error: 'Runtime config or connection record is missing or invalid' }; }
  }));
  const secrets = records.flatMap(record => [record.config?.token, record.connection?.token]).filter(Boolean);
  const results = await Promise.all(records.map(record => checkServer(record, sdk, profile, secrets)));
  const report = { checkedAt: new Date().toISOString(), readOnly: true, results };
  await fs.mkdir(path.dirname(options.report), { recursive: true });
  await fs.writeFile(options.report, redact(JSON.stringify(report, null, 2), secrets) + '\n', { mode: 0o600 });
  for (const result of results) console.log(redact(JSON.stringify(result), secrets));
  if (results.some(result => !result.ok || result.applicationReady === false)) process.exitCode = 2;
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  await main(process.argv.slice(2)).catch(error => {
    console.error(redact(error.message ?? error));
    process.exitCode = 1;
  });
}
