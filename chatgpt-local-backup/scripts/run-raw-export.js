'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');
const { spawn } = require('child_process');
const { arg, readArchiveProfile, resolveArchiveRoot } = require('./lib/archive-profile');

function stamp() {
  const d = new Date();
  const p = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}
function bridge(action, args, session) {
  const body = JSON.stringify({ action, args, session });
  return new Promise((resolve, reject) => {
    const req = http.request({ hostname: '127.0.0.1', port: 10086, path: '/command', method: 'POST', headers: {
      'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body),
    } }, res => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', c => { data += c; });
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          if (!parsed.ok) reject(new Error(parsed.error || 'WebBridge command failed'));
          else resolve(parsed.data);
        } catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.end(body);
  });
}

const { root: backupRoot } = resolveArchiveRoot('chatgpt');
readArchiveProfile(backupRoot, 'chatgpt', ['final/ChatGPT_Backup', 'state/raw']);
const tool = path.resolve(arg('--tool', path.join(backupRoot, 'tool', 'export-chatgpt')));
const working = path.resolve(arg('--working', path.join(backupRoot, 'working')));
const requestedRaw = arg('--raw', null);
const raw = requestedRaw ? path.resolve(requestedRaw) : path.join(working, `raw_export_${stamp()}`);
const session = 'chatgpt-local-backup';

(async () => {
  if (!fs.existsSync(path.join(tool, 'export-chatgpt.js'))) throw new Error(`Invalid exporter path: ${tool}`);
  fs.mkdirSync(raw, { recursive: true });

  try {
    await bridge('find_tab', { url: 'https://chatgpt.com', active: true }, session);
  } catch {
    await bridge('navigate', { url: 'https://chatgpt.com', newTab: true, group_title: 'ChatGPT 本地备份' }, session);
  }

  let token = '';
  try {
    const result = await bridge('evaluate', {
      code: "fetch('/api/auth/session',{credentials:'include'}).then(r=>r.json()).then(d=>d.accessToken||'')",
    }, session);
    token = result?.value || '';
    if (!token.startsWith('eyJ')) throw new Error('Current Edge session did not return a valid ChatGPT access token');

    console.log(`RAW_EXPORT_DIR=${raw}`);
    const child = spawn(process.execPath, [
      'export-chatgpt.js', '--output', raw, '--no-user-dir', '--format', 'json',
      '--no-canvas', '--include-archived', '--non-interactive', '--no-donate',
    ], {
      cwd: tool,
      stdio: 'inherit',
      env: { ...process.env, CHATGPT_BEARER_TOKEN: token },
    });
    token = '';
    await new Promise((resolve, reject) => {
      child.on('error', reject);
      child.on('exit', code => code === 0 ? resolve() : reject(new Error(`Exporter exited with code ${code}`)));
    });
  } finally {
    token = '';
  }
})().catch(error => {
  console.error(`Raw export failed: ${error.message}`);
  process.exitCode = 1;
});
