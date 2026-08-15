'use strict';

const fs = require('fs');
const path = require('path');

function arg(name) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : null;
}
const candidate = path.resolve(arg('--candidate') || '');
const finalRoot = path.resolve('D:\\ChatGPT_Backup\\final');
const final = path.join(finalRoot, 'ChatGPT_Backup');
const rollback = path.join(finalRoot, `ChatGPT_Backup.rollback-${Date.now()}`);

if (!candidate.startsWith(finalRoot + path.sep) || candidate === final) {
  throw new Error(`Candidate must be a separate directory under ${finalRoot}`);
}
const verificationPath = path.join(candidate, 'metadata', 'final-verification.json');
if (!fs.existsSync(verificationPath)) throw new Error('Candidate has no final verification report');
const verification = JSON.parse(fs.readFileSync(verificationPath, 'utf8'));
if (verification.passed !== true) throw new Error('Candidate verification did not pass');

let oldMoved = false;
try {
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
