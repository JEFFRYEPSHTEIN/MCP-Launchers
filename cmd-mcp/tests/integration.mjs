import assert from 'node:assert/strict';
import { spawn, execFile } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, readFile, writeFile, access, rm } from 'node:fs/promises';
import { createServer } from 'node:net';
import { request as httpRequest } from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';
import { before, after, test } from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

// These tests use a disposable token, folder, and server. They never invoke
// destructive system commands or operate on an existing MCP service.
const project = fileURLToPath(new URL('../', import.meta.url));
const main = path.join(project, 'dist', 'main.js');
const runFile = promisify(execFile);
let directory;
let token;
let server;
let serverExit;
let client;
let endpoint;
let startupOutput = '';

async function availablePort() {
  const socket = createServer();
  await new Promise((resolve, reject) => {
    socket.once('error', reject);
    socket.listen(0, '127.0.0.1', resolve);
  });
  const port = socket.address().port;
  await new Promise((resolve, reject) => socket.close(error => error ? reject(error) : resolve()));
  return port;
}

async function tool(name, args = {}) {
  const result = await client.callTool({ name, arguments: args });
  assert.notEqual(result.isError, true, `${name} unexpectedly returned a tool error`);
  assert.ok(result.structuredContent, `${name} must expose machine-readable structuredContent`);
  assert.ok(!JSON.stringify(result).includes(token), `${name} leaked the bearer token`);
  return result.structuredContent;
}

async function rejectedTool(name, args) {
  let response;
  try {
    response = await client.callTool({ name, arguments: args });
  } catch (error) {
    assert.ok(error instanceof Error);
    assert.ok(!error.message.includes(token), 'error leaked the bearer token');
    return;
  }
  assert.equal(response.isError, true, `${name} must reject invalid input`);
  assert.ok(!JSON.stringify(response).includes(token), 'tool error leaked the bearer token');
}

async function finished(sessionId, cursor = 0) {
  let result;
  for (let attempt = 0; attempt < 20; attempt++) {
    result = await tool('pc_read_session', { session_id: sessionId, cursor, wait_ms: 250 });
    if (result.state !== 'running') return result;
  }
  assert.fail('test process did not finish in time');
}

before(async () => {
  assert.equal(process.platform, 'win32', 'integration suite requires Windows');
  directory = await mkdtemp(path.join(os.tmpdir(), 'pc-control-mcp-test-'));
  await runFile(process.execPath, [main, 'init', '--quiet', '--data-dir', directory], {
    cwd: project, windowsHide: true, timeout: 15000,
  });
  ({ token } = JSON.parse(await readFile(path.join(directory, 'token.json'), 'utf8')));
  assert.match(token, /^[A-Za-z0-9_-]{40,}$/);
  const port = await availablePort();
  endpoint = `http://127.0.0.1:${port}`;
  server = spawn(process.execPath, [main, 'serve', '--port', String(port), '--data-dir', directory], {
    cwd: project, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverExit = once(server, 'exit');
  const capture = chunk => { startupOutput = (startupOutput + chunk).slice(-8192); };
  server.stdout.on('data', capture);
  server.stderr.on('data', capture);
  let healthy = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    if (server.exitCode !== null) break;
    try {
      const response = await fetch(`${endpoint}/health`, { signal: AbortSignal.timeout(1000) });
      if (response.ok) {
        const health = await response.json();
        assert.equal(health.ok, true);
        assert.equal(health.service, 'pc-control-mcp');
        assert.equal(health.pid, server.pid);
        assert.equal(health.port, port);
        healthy = true;
        break;
      }
    } catch {}
    await delay(100);
  }
  assert.ok(healthy, 'disposable MCP server did not become healthy');
  assert.ok(!startupOutput.includes(token), 'server logs leaked the bearer token');
  client = new Client({ name: 'pc-control-integration', version: '1.0.0' });
  await client.connect(new StreamableHTTPClientTransport(new URL(`${endpoint}/mcp`), {
    requestInit: { headers: { Authorization: `Bearer ${token}` } },
  }));
}, { timeout: 30000 });

after(async () => {
  if (client) await client.close();
  if (server && server.exitCode === null && token) {
    const response = await fetch(`${endpoint}/admin/shutdown`, {
      method: 'POST', headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(5000),
    });
    assert.ok(response.ok, 'graceful shutdown request failed');
    await Promise.race([serverExit, delay(10000).then(() => { throw new Error('server did not stop gracefully'); })]);
  }
  assert.ok(!startupOutput.includes(token), 'server logs leaked the bearer token');
  if (directory) {
    const resolved = path.resolve(directory);
    assert.equal(path.dirname(resolved).toLowerCase(), path.resolve(os.tmpdir()).toLowerCase());
    assert.ok(path.basename(resolved).startsWith('pc-control-mcp-test-'));
    await rm(resolved, { recursive: true, force: true });
  }
}, { timeout: 20000 });

test('invalid bearer requests are rejected before a command can create a file (4.3, 6.2)', async () => {
  const sentinel = path.join(directory, 'unauthorized.txt');
  const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: {
    name: 'pc_run_command', arguments: { command: `echo forbidden>"${sentinel}"` },
  } });
  for (const authorization of [undefined, 'Bearer deliberately-wrong']) {
    const headers = { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' };
    if (authorization) headers.Authorization = authorization;
    const response = await fetch(`${endpoint}/mcp`, { method: 'POST', headers, body });
    assert.equal(response.status, 401);
  }
  await assert.rejects(access(sentinel), { code: 'ENOENT' });
});

test('hostile Origin and Host are rejected before MCP processing (6.2)', async () => {
  for (const maliciousHeaders of [{ Origin: 'https://attacker.example' }, { Host: 'attacker.example' }]) {
    const status = await new Promise((resolve, reject) => {
      // fetch/Undici may replace Host, so use a raw HTTP client to exercise that header.
      const request = httpRequest(`${endpoint}/mcp`, { method: 'POST', headers: {
      Authorization: `Bearer ${token}`, 'Content-Type': 'application/json',
      Accept: 'application/json, text/event-stream', ...maliciousHeaders,
      } }, response => { response.resume(); resolve(response.statusCode); });
      request.once('error', reject);
      request.end(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }));
    });
    assert.equal(status, 403);
  }
});

test('official MCP client discovers all eight tools (1-4)', async () => {
  const result = await client.listTools();
  assert.deepEqual(result.tools.map(item => item.name).sort(), [
    'pc_get_pc_status', 'pc_list_processes', 'pc_list_sessions', 'pc_read_session',
    'pc_run_command', 'pc_start_process', 'pc_stop_process', 'pc_stop_session',
  ].sort());
});

test('CMD returns separate output streams and a nonzero exit code; service survives (1.1, 5.1, 7.1)', async () => {
  const result = await tool('pc_run_command', {
    command: 'echo STDOUT_MARKER & echo STDERR_MARKER 1>&2 & exit /b 7', wait_ms: 10000,
  });
  assert.equal(result.state, 'completed');
  assert.equal(result.exit_code, 7);
  assert.match(result.stdout, /STDOUT_MARKER/);
  assert.match(result.stderr, /STDERR_MARKER/);
  assert.ok(!result.stdout.includes('STDERR_MARKER'));
  assert.ok(!result.stderr.includes('STDOUT_MARKER'));
  const success = await tool('pc_run_command', { command: 'echo STILL_ALIVE', wait_ms: 10000 });
  assert.equal(success.exit_code, 0);
  assert.match(success.stdout, /STILL_ALIVE/);
});

test('commands honor cwd and reject invalid commands/directories (1.2, 1.3)', async () => {
  const result = await tool('pc_run_command', { command: 'cd', cwd: directory, wait_ms: 10000 });
  assert.equal(result.stdout.trim().toLowerCase(), directory.toLowerCase());
  await rejectedTool('pc_run_command', { command: '' });
  await rejectedTool('pc_run_command', { command: 'x'.repeat(7001) });
  await rejectedTool('pc_run_command', { command: 'echo ignored', cwd: path.join(directory, 'missing-folder') });
  await rejectedTool('pc_run_command', { command: 'echo ignored', cwd: 'relative-folder' });
  await rejectedTool('pc_run_command', { command: 'echo ignored', wait_ms: -1 });
});

test('long commands can be listed, polled without duplicate output, and stopped (2.1-2.4)', async () => {
  const fixture = path.join(directory, 'long.cjs');
  await writeFile(fixture, "console.log('START_MARKER'); setTimeout(() => console.log('LATER_MARKER'), 250); setInterval(() => {}, 1000);\n");
  const started = await tool('pc_run_command', {
    command: `"${process.execPath}" "${fixture}"`, wait_ms: 0,
  });
  assert.equal(started.state, 'running');
  const listed = await tool('pc_list_sessions', { state: 'running', limit: 50 });
  assert.ok(JSON.stringify(listed).includes(started.session_id));
  let observed = started.stdout;
  let cursor = started.cursor;
  for (let attempt = 0; attempt < 20 && !observed.includes('LATER_MARKER'); attempt++) {
    const polled = await tool('pc_read_session', { session_id: started.session_id, cursor, wait_ms: 250 });
    observed += polled.stdout;
    assert.ok(polled.cursor >= cursor);
    cursor = polled.cursor;
  }
  assert.match(observed, /START_MARKER/);
  assert.match(observed, /LATER_MARKER/);
  assert.equal(observed.split('START_MARKER').length - 1, 1);
  assert.equal(observed.split('LATER_MARKER').length - 1, 1);
  const stopped = await tool('pc_stop_session', { session_id: started.session_id });
  assert.notEqual(stopped.state, 'running');
  assert.notEqual((await finished(started.session_id, cursor)).state, 'running');
  await rejectedTool('pc_read_session', { session_id: '00000000-0000-4000-8000-000000000000' });
  await rejectedTool('pc_stop_session', { session_id: '00000000-0000-4000-8000-000000000000' });
});

test('bounded responses preserve remaining output through cursor pagination (5.2)', async () => {
  const fixture = path.join(directory, 'output.cjs');
  await writeFile(fixture, "process.stdout.write('Ж'.repeat(50000)); process.stderr.write('B'.repeat(1000));\n");
  let result = await tool('pc_run_command', {
    command: `"${process.execPath}" "${fixture}"`, wait_ms: 10000,
  });
  assert.equal(result.state, 'completed');
  assert.equal(result.truncated, true);
  let stdout = '';
  let stderr = '';
  for (let page = 0; page < 10; page++) {
    assert.ok(Buffer.byteLength(result.stdout + result.stderr) <= 65536, 'response exceeded output budget');
    assert.equal(result.output_lost, false);
    stdout += result.stdout;
    stderr += result.stderr;
    if (!result.truncated) break;
    const oldCursor = result.cursor;
    result = await tool('pc_read_session', { session_id: result.session_id, cursor: result.cursor });
    assert.ok(result.cursor > oldCursor, 'cursor pagination made no progress');
  }
  assert.equal(stdout, 'Ж'.repeat(50000));
  assert.equal(stderr, 'B'.repeat(1000));
});

test('status and paginated process listing return usable Windows data (3.1, 3.2)', async () => {
  const status = await tool('pc_get_pc_status');
  assert.ok(JSON.stringify(status).includes(os.hostname()));
  assert.ok(JSON.stringify(status).toLowerCase().includes('windows'));
  const listed = await tool('pc_list_processes', { limit: 5, offset: 0 });
  assert.ok(Array.isArray(listed.processes));
  assert.ok(listed.processes.length > 0 && listed.processes.length <= 5);
  for (const processInfo of listed.processes) {
    assert.ok(Number.isInteger(processInfo.pid));
    assert.equal(typeof processInfo.name, 'string');
    assert.ok(!Object.keys(processInfo).some(key => /command.?line|arguments/i.test(key)));
  }
});

test('process identity guard refuses an outdated start time, then stops only the test child (3.3)', async () => {
  const started = await tool('pc_start_process', {
    executable: process.execPath, args: ['-e', 'setInterval(() => {}, 1000)'], cwd: directory,
  });
  assert.ok(Number.isInteger(started.pid) && started.pid > 0);
  assert.equal(typeof started.started_at, 'string');
  assert.equal(typeof started.session_id, 'string');
  await rejectedTool('pc_stop_process', { pid: started.pid, expected_started_at: '2000-01-01T00:00:00.000Z' });
  assert.equal((await tool('pc_read_session', { session_id: started.session_id })).state, 'running');
  await tool('pc_stop_process', { pid: started.pid, expected_started_at: started.started_at });
  assert.notEqual((await finished(started.session_id)).state, 'running');
});

test('graceful shutdown terminates an owned active command process (7.2)', async () => {
  const child = await tool('pc_start_process', {
    executable: process.execPath, args: ['-e', 'setInterval(() => {}, 1000)'], cwd: directory,
  });
  const response = await fetch(`${endpoint}/admin/shutdown`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(5000),
  });
  assert.ok(response.ok);
  await Promise.race([serverExit, delay(10000).then(() => { throw new Error('server did not stop gracefully'); })]);
  assert.throws(() => process.kill(child.pid, 0), { code: 'ESRCH' });
});
