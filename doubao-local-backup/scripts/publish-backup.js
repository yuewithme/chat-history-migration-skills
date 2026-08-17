'use strict';

const fs = require('fs');
const path = require('path');
const { assertInside, ensureDir } = require('./lib/atomic-json');
const { readArchiveProfile, resolveArchiveRoot } = require('./lib/archive-profile');

function arg(name, fallback = null) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

const { root } = resolveArchiveRoot('doubao');
readArchiveProfile(root, 'doubao', ['final/Doubao_Backup', 'state/raw']);
const candidate = path.resolve(arg('--candidate') || '');
if (!arg('--candidate')) throw new Error('Usage: node publish-backup.js --root <profile-root> --candidate <candidate-dir>');
const workingRoot = path.join(root, 'working');
const finalRoot = path.join(root, 'final');
const final = path.join(finalRoot, 'Doubao_Backup');
const rollback = path.join(finalRoot, `Doubao_Backup.rollback-${Date.now()}`);

assertInside(workingRoot, candidate, 'Candidate');
assertInside(root, final, 'Published backup');
assertInside(root, rollback, 'Rollback backup');

const verificationPath = path.join(candidate, 'metadata', 'final-verification.json');
if (!fs.existsSync(verificationPath)) throw new Error('Candidate has no final verification report');
const verification = JSON.parse(fs.readFileSync(verificationPath, 'utf8'));
if (verification.passed !== true) throw new Error('Candidate verification did not pass');

ensureDir(finalRoot);
let oldMoved = false;
try {
  if (fs.existsSync(final)) {
    fs.renameSync(final, rollback);
    oldMoved = true;
  }
  fs.renameSync(candidate, final);
  if (oldMoved && fs.existsSync(rollback)) fs.rmSync(rollback, { recursive: true, force: false });
  console.log(JSON.stringify({ published: final, previous_removed_after_success: oldMoved }, null, 2));
} catch (error) {
  if (!fs.existsSync(final) && oldMoved && fs.existsSync(rollback)) fs.renameSync(rollback, final);
  throw error;
}
