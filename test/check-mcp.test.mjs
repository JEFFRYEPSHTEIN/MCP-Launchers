import test from 'node:test';
import assert from 'node:assert/strict';
import { canonicalEndpoint, toolFailure, decodeResponse, redact } from '../Check-MCP.mjs';

const key = '0123456789abcdef'.repeat(4);
const base = 'https://test-domain.trycloudflare.com';
const connection = { running: true, baseUrl: base, serverUrl: `${base}/mcp` };

test('Only a matching canonical public HTTPS endpoint is accepted', () => {
  assert.equal(canonicalEndpoint(connection).href, `${base}/mcp`);
  for (const change of [
    { running: false }, { baseUrl: 'http://127.0.0.1:8770' },
    { baseUrl: 'https://trycloudflare.com.attacker.example' },
    { serverUrl: `${base}/${key}/mcp` }, { serverUrl: `${base}/mcp?key=${key}` },
    { serverUrl: 'https://other-domain.trycloudflare.com/mcp' },
    { serverUrl: 'https://user:password@test-domain.trycloudflare.com/mcp' },
    { baseUrl: `${base}:8443` }, { serverUrl: `${base}/mcp#secret` },
  ]) assert.throws(() => canonicalEndpoint({ ...connection, ...change }));
});
test('Blender textual errors are failures even when isError is false', () => {
  assert.match(toolFailure({ isError: false, content: [{ type: 'text', text: 'Error getting scene info: connection refused' }] }), /connection refused/);
  assert.ok(toolFailure({ structuredContent: { ok: false }, content: [] }));
  assert.equal(toolFailure({ content: [{ type: 'text', text: '{"name":"Scene","object_count":49}' }] }), null);
});
test('Wrapped Studio and Rojo JSON is decoded without losing the application state', () => {
  assert.deepEqual(decodeResponse({ structuredContent: { result: '{"studios":[]}' } }), { studios: [] });
  assert.deepEqual(decodeResponse({ content: [{ type: 'text', text: '{"serving":{"state":"stopped"}}' }] }), { serving: { state: 'stopped' } });
});
test('Reports and upstream exceptions remove keys and Bearer values', () => {
  const output = redact(`Bearer ${key} ${base}/${key}/mcp Bearer short-secret`, [key]);
  assert.equal(output.includes(key), false);
  assert.equal(output.includes('short-secret'), false);
  assert.match(output, /REDACTED/);
});
