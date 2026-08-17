'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { execFileSync } = require('node:child_process');

const scripts = path.resolve(__dirname, '..');

function tempHome(context) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'chatgpt-archive-layout-'));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

test('initializer creates a portable profile marker and fixed control directories', context => {
  const home = tempHome(context);
  const result = JSON.parse(execFileSync(process.execPath, [
    path.join(scripts, 'init-backup.js'), '--archive-home', home, '--profile', 'primary',
  ], { encoding: 'utf8' }));
  assert.equal(result.profile.source, 'chatgpt');
  assert.equal(result.profile.profile_id, 'primary');
  assert.equal(Object.hasOwn(result.profile, 'archive_root'), false);
  for (const relative of ['tool', 'state', 'working', 'final', 'logs', 'reports', 'archive-profile.json']) {
    assert.equal(fs.existsSync(path.join(result.root, relative)), true, relative);
  }
});

test('publisher accepts only verified candidates under the selected working directory', context => {
  const home = tempHome(context);
  const initialized = JSON.parse(execFileSync(process.execPath, [
    path.join(scripts, 'init-backup.js'), '--archive-home', home, '--profile', 'primary',
  ], { encoding: 'utf8' }));
  const candidate = path.join(initialized.root, 'working', 'candidate-test');
  fs.mkdirSync(path.join(candidate, 'metadata'), { recursive: true });
  fs.writeFileSync(path.join(candidate, 'metadata', 'final-verification.json'), '{"passed":true}\n', 'utf8');
  execFileSync(process.execPath, [
    path.join(scripts, 'publish-backup.js'), '--root', initialized.root, '--candidate', candidate,
  ], { stdio: 'pipe' });
  assert.equal(fs.existsSync(path.join(initialized.root, 'final', 'ChatGPT_Backup', 'metadata', 'final-verification.json')), true);
});
