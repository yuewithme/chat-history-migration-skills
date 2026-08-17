'use strict';

const fs = require('fs');
const path = require('path');
const { readArchiveProfile, resolveArchiveRoot } = require('./lib/archive-profile');

function arg(name) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : null;
}
const candidate = path.resolve(arg('--candidate') || '');
if (!arg('--candidate')) throw new Error('Usage: node publish-backup.js --root <profile-root> --candidate <candidate-dir>');
const { root: backupRoot } = resolveArchiveRoot('chatgpt');
readArchiveProfile(backupRoot, 'chatgpt', ['final/ChatGPT_Backup', 'state/raw']);
const workingRoot = path.join(backupRoot, 'working');
const finalRoot = path.join(backupRoot, 'final');
const final = path.join(finalRoot, 'ChatGPT_Backup');
const rollback = path.join(finalRoot, `ChatGPT_Backup.rollback-${Date.now()}`);

const candidateRelative = path.relative(workingRoot, candidate);
if (!candidateRelative || candidateRelative.startsWith('..') || path.isAbsolute(candidateRelative)) {
  throw new Error(`Candidate must be a separate directory under ${workingRoot}`);
}
const verificationPath = path.join(candidate, 'metadata', 'final-verification.json');
if (!fs.existsSync(verificationPath)) throw new Error('Candidate has no final verification report');
const verification = JSON.parse(fs.readFileSync(verificationPath, 'utf8'));
if (verification.passed !== true) throw new Error('Candidate verification did not pass');

let oldMoved = false;
try {
  fs.mkdirSync(finalRoot, { recursive: true });
  if (fs.existsSync(final)) {
    fs.renameSync(final, rollback);
    oldMoved = true;
  }
  fs.renameSync(candidate, final);
  if (oldMoved) fs.rmSync(rollback, { recursive: true, force: false });
  console.log(`Published verified backup: ${final}`);
} catch (error) {
  if (!fs.existsSync(final) && oldMoved && fs.existsSync(rollback)) fs.renameSync(rollback, final);
  throw error;
}
