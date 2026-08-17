'use strict';

const fs = require('fs');
const path = require('path');
const { assertInside, atomicWriteJson, ensureDir } = require('./lib/atomic-json');
const { arg, readArchiveProfile, resolveArchiveRoot } = require('./lib/archive-profile');
const { validateEnvelope } = require('./lib/conversation');
const { safeName, sha256 } = require('./lib/file-store');
const { emptyCheckpoint, saveCheckpoint } = require('./lib/checkpoint');

function jsonFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  const result = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const item = path.join(dir, entry.name);
    if (entry.isDirectory()) result.push(...jsonFiles(item));
    else if (entry.name.toLowerCase().endsWith('.json')) result.push(item);
  }
  return result;
}

function linkOrCopy(source, target) {
  ensureDir(path.dirname(target));
  try {
    fs.linkSync(source, target);
    return 'hardlink';
  } catch (error) {
    if (!['EXDEV', 'ENOTSUP', 'EPERM', 'EACCES'].includes(error.code)) throw error;
    fs.copyFileSync(source, target);
    return 'copy';
  }
}

const { root } = resolveArchiveRoot('doubao');
readArchiveProfile(root, 'doubao', ['final/Doubao_Backup', 'state/raw']);
const finalDir = path.resolve(arg('--final', path.join(root, 'final', 'Doubao_Backup')));
const stateDir = path.resolve(arg('--state', path.join(root, 'state', 'raw')));
const stateParent = path.dirname(stateDir);
const candidate = path.join(stateParent, `raw.candidate-${Date.now()}`);
const rollback = path.join(stateParent, `raw.rollback-${Date.now()}`);
assertInside(root, finalDir, 'Final backup');
assertInside(root, stateDir, 'Incremental state');
assertInside(root, candidate, 'State candidate');
assertInside(root, rollback, 'State rollback');

const verificationPath = path.join(finalDir, 'metadata', 'final-verification.json');
if (!fs.existsSync(verificationPath)) throw new Error(`Verified final backup not found: ${finalDir}`);
const verification = JSON.parse(fs.readFileSync(verificationPath, 'utf8'));
if (verification.passed !== true) throw new Error('Published backup verification is not passed:true');

ensureDir(path.join(candidate, 'conversations'));
ensureDir(path.join(candidate, 'files'));
let hardlinks = 0;
let copies = 0;
const checkpoint = emptyCheckpoint();
const conversationIndex = [];

for (const source of jsonFiles(path.join(finalDir, 'conversations'))) {
  const envelope = validateEnvelope(JSON.parse(fs.readFileSync(source, 'utf8')));
  const target = path.join(candidate, 'conversations', path.basename(source));
  const mode = linkOrCopy(source, target);
  if (mode === 'hardlink') hardlinks++; else copies++;
  const digest = sha256(source);
  checkpoint.completed_conversations[envelope.conversation_id] = {
    updated_at: envelope.derived.updated_at || null,
    content_fingerprint: envelope.derived.content_fingerprint || digest,
    content_sha256: digest,
  };
  conversationIndex.push({
    conversation_id: envelope.conversation_id,
    title: envelope.derived.title || null,
    created_at: envelope.derived.created_at || null,
    updated_at: envelope.derived.updated_at || null,
    content_sha256: digest,
  });
}

const manifest = JSON.parse(fs.readFileSync(path.join(finalDir, 'attachments', 'manifest.json'), 'utf8'));
for (const item of manifest.files || []) {
  const source = path.join(finalDir, item.stored_path);
  const extension = path.extname(source);
  for (const attachmentId of item.attachment_ids || []) {
    const target = path.join(candidate, 'files', `${safeName(attachmentId, 'attachment', 180)}${extension}`);
    const mode = linkOrCopy(source, target);
    if (mode === 'hardlink') hardlinks++; else copies++;
    checkpoint.completed_attachments[attachmentId] = { sha256: item.sha256, size_bytes: item.size_bytes };
  }
}

checkpoint.last_successful_run = verification.verified_at || new Date().toISOString();
atomicWriteJson(path.join(candidate, 'conversation-index.json'), conversationIndex);
saveCheckpoint(path.join(candidate, 'checkpoint.json'), checkpoint);

ensureDir(stateParent);
let oldMoved = false;
try {
  if (fs.existsSync(stateDir)) {
    fs.renameSync(stateDir, rollback);
    oldMoved = true;
  }
  fs.renameSync(candidate, stateDir);
  if (oldMoved && fs.existsSync(rollback)) fs.rmSync(rollback, { recursive: true, force: false });
} catch (error) {
  if (!fs.existsSync(stateDir) && oldMoved && fs.existsSync(rollback)) fs.renameSync(rollback, stateDir);
  throw error;
} finally {
  if (fs.existsSync(candidate)) fs.rmSync(candidate, { recursive: true, force: false });
}

console.log(JSON.stringify({
  state: stateDir,
  conversations: conversationIndex.length,
  attachment_ids: Object.keys(checkpoint.completed_attachments).length,
  hardlinks,
  fallback_copies: copies,
}, null, 2));
