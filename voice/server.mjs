import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i].startsWith('--')) out[argv[i].slice(2)] = argv[++i];
  }
  return out;
}

export function readEnvValue(filePath, name) {
  const text = fs.readFileSync(filePath, 'utf8');
  const line = text.split(/\r?\n/).find((entry) => new RegExp(`^\\s*${name}\\s*=`).test(entry));
  if (!line) return '';
  let value = line.slice(line.indexOf('=') + 1).trim();
  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
  return value;
}

export function isAllowedRequest(req, port) {
  const host = req.headers.host || '';
  if (host !== `127.0.0.1:${port}` && host !== `localhost:${port}`) return false;
  const origin = req.headers.origin;
  return !origin || origin === `http://127.0.0.1:${port}` || origin === `http://localhost:${port}`;
}

export function safePublicPath(publicDir, requestPath) {
  const decoded = decodeURIComponent(requestPath.split('?')[0]);
  const relative = decoded === '/' ? 'index.html' : decoded.replace(/^\/+/, '');
  const resolved = path.resolve(publicDir, relative);
  return resolved === publicDir || resolved.startsWith(publicDir + path.sep) ? resolved : null;
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const args = parseArgs(process.argv.slice(2));
  const port = Number(args.port || 3847);
  const agentId = String(args['agent-id'] || '');
  const envFile = String(args['env-file'] || '');
  const root = path.resolve(String(args.root || path.join(path.dirname(fileURLToPath(import.meta.url)), '..')));
  const publicDir = path.join(root, 'voice', 'public');
  const avatarPath = path.join(root, 'assets', 'sektor-chibi-avatar.png');
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('invalid port');
  if (!/^agent_[A-Za-z0-9]+$/.test(agentId)) throw new Error('invalid agent id');
  const apiKey = readEnvValue(envFile, 'ELEVENLABS_API_KEY');
  if (!apiKey) throw new Error('ELEVENLABS_API_KEY missing');

  const server = http.createServer(async (req, res) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Cache-Control', 'no-store');
    if (!isAllowedRequest(req, port)) {
      res.writeHead(403, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'forbidden' }));
      return;
    }
    if (req.url === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, pid: process.pid, agentId }));
      return;
    }
    if (req.url === '/api/signed-url') {
      try {
        const url = new URL('https://api.elevenlabs.io/v1/convai/conversation/get_signed_url');
        url.searchParams.set('agent_id', agentId);
        const upstream = await fetch(url, { headers: { 'xi-api-key': apiKey } });
        if (!upstream.ok) throw new Error(`ElevenLabs returned ${upstream.status}`);
        const data = await upstream.json();
        if (!data.signed_url) throw new Error('signed URL missing');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ signedUrl: data.signed_url }));
      } catch (error) {
        res.writeHead(502, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: String(error.message || error) }));
      }
      return;
    }
    let filePath;
    if (req.url === '/avatar.png') filePath = avatarPath;
    else filePath = safePublicPath(publicDir, req.url || '/');
    if (!filePath || !fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('Not found');
      return;
    }
    const ext = path.extname(filePath).toLowerCase();
    const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.png': 'image/png' };
    res.writeHead(200, { 'Content-Type': types[ext] || 'application/octet-stream' });
    fs.createReadStream(filePath).pipe(res);
  });
  server.listen(port, '127.0.0.1', () => console.log(`SnapIt voice ready on 127.0.0.1:${port}`));
}
