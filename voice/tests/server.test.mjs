import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parseArgs, readEnvValue, isAllowedRequest, safePublicPath } from '../server.mjs';

test('parseArgs reads explicit CLI pairs', () => {
  assert.deepEqual(parseArgs(['--port', '3847', '--agent-id', 'agent_123']), { port: '3847', 'agent-id': 'agent_123' });
});

test('readEnvValue reads quoted value without exposing other entries', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'snapit-voice-'));
  const file = path.join(dir, '.env');
  fs.writeFileSync(file, 'OTHER=nope\nELEVENLABS_API_KEY="test-key"\n', 'utf8');
  assert.equal(readEnvValue(file, 'ELEVENLABS_API_KEY'), 'test-key');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('isAllowedRequest permits localhost and blocks foreign origins', () => {
  assert.equal(isAllowedRequest({ headers: { host: '127.0.0.1:3847' } }, 3847), true);
  assert.equal(isAllowedRequest({ headers: { host: '127.0.0.1:3847', origin: 'https://evil.example' } }, 3847), false);
  assert.equal(isAllowedRequest({ headers: { host: 'evil.example' } }, 3847), false);
});

test('safePublicPath blocks traversal outside public directory', () => {
  const root = path.resolve('C:/safe/public');
  assert.equal(safePublicPath(root, '/'), path.join(root, 'index.html'));
  assert.equal(safePublicPath(root, '/../../secret.env'), null);
});
