'use strict';

const fs = require('fs');
const path = require('path');
const { atomicCopy, atomicWriteJson, ensureDir } = require('./atomic-json');
const { loadCheckpoint, saveCheckpoint } = require('./checkpoint');
const { validateEnvelope } = require('./conversation');
const { extensionFor, safeName, sha256 } = require('./file-store');
const { sanitizeDiagnostic } = require('./redaction');

function initializeRawState(rawDir) {
  const root = path.resolve(rawDir);
  ensureDir(path.join(root, 'conversations'));
  ensureDir(path.join(root, 'files'));
  const checkpointPath = path.join(root, 'checkpoint.json');
  const checkpoint = loadCheckpoint(checkpointPath);
  if (!fs.existsSync(checkpointPath)) saveCheckpoint(checkpointPath, checkpoint);
  return { root, checkpointPath, checkpoint };
}

function shouldFetchConversation(checkpoint, summary) {
  const id = summary?.conversation_id;
  if (typeof id !== 'string' || !id) throw new Error('Conversation summary has no conversation_id');
  const existing = checkpoint.completed_conversations[id];
  if (!existing) return { fetch: true, reason: 'new conversation' };
  if (summary.updated_at != null && existing.updated_at !== summary.updated_at) {
    return { fetch: true, reason: 'provider update marker changed' };
  }
  if (summary.content_fingerprint != null && existing.content_fingerprint !== summary.content_fingerprint) {
    return { fetch: true, reason: 'content fingerprint changed' };
  }
  return { fetch: false, reason: 'unchanged' };
}

function saveConversation(rawDir, envelope) {
  const state = initializeRawState(rawDir);
  validateEnvelope(envelope);
  const id = envelope.conversation_id;
  const target = path.join(state.root, 'conversations', `${safeName(id, 'conversation', 180)}.json`);
  atomicWriteJson(target, envelope);
  const legacySuffix = `__${safeName(id, 'conversation', 180)}.json`;
  for (const name of fs.readdirSync(path.dirname(target))) {
    if (!name.endsWith(legacySuffix)) continue;
    const legacyPath = path.join(path.dirname(target), name);
    if (legacyPath === target) continue;
    try {
      const legacy = JSON.parse(fs.readFileSync(legacyPath, 'utf8'));
      if (legacy.conversation_id === id) fs.rmSync(legacyPath, { force: true });
    } catch {}
  }
  const digest = sha256(target);
  state.checkpoint.completed_conversations[id] = {
    updated_at: envelope.derived.updated_at || null,
    content_fingerprint: envelope.derived.content_fingerprint || digest,
    content_sha256: digest,
  };
  state.checkpoint.failed_conversations = state.checkpoint.failed_conversations.filter(item => item.conversation_id !== id);
  saveCheckpoint(state.checkpointPath, state.checkpoint);
  return { path: target, sha256: digest };
}

function recordConversationFailure(rawDir, conversationId, error) {
  const state = initializeRawState(rawDir);
  const item = {
    conversation_id: String(conversationId || 'unknown'),
    error: sanitizeDiagnostic(error?.message || error),
    recorded_at: new Date().toISOString(),
  };
  state.checkpoint.failed_conversations = state.checkpoint.failed_conversations.filter(entry => entry.conversation_id !== item.conversation_id);
  state.checkpoint.failed_conversations.push(item);
  saveCheckpoint(state.checkpointPath, state.checkpoint);
  return item;
}

function saveAttachment(rawDir, reference, temporaryFile) {
  const state = initializeRawState(rawDir);
  const id = reference?.attachment_id;
  if (typeof id !== 'string' || !id) throw new Error('Attachment reference has no attachment_id');
  const stat = fs.statSync(temporaryFile);
  if (!stat.isFile() || stat.size === 0) throw new Error('Attachment temporary file is empty or invalid');
  const extension = extensionFor(temporaryFile, reference.original_name);
  const target = path.join(state.root, 'files', `${safeName(id, 'attachment', 180)}${extension}`);
  atomicCopy(temporaryFile, target);
  const digest = sha256(target);
  state.checkpoint.completed_attachments[id] = { sha256: digest, size_bytes: stat.size };
  state.checkpoint.failed_attachments = state.checkpoint.failed_attachments.filter(item => item.attachment_id !== id);
  saveCheckpoint(state.checkpointPath, state.checkpoint);
  return { path: target, sha256: digest, size_bytes: stat.size };
}

function recordAttachmentFailure(rawDir, attachmentId, error) {
  const state = initializeRawState(rawDir);
  const item = {
    attachment_id: String(attachmentId || 'unknown'),
    error: sanitizeDiagnostic(error?.message || error),
    recorded_at: new Date().toISOString(),
  };
  state.checkpoint.failed_attachments = state.checkpoint.failed_attachments.filter(entry => entry.attachment_id !== item.attachment_id);
  state.checkpoint.failed_attachments.push(item);
  saveCheckpoint(state.checkpointPath, state.checkpoint);
  return item;
}

module.exports = {
  initializeRawState,
  recordAttachmentFailure,
  recordConversationFailure,
  saveAttachment,
  saveConversation,
  shouldFetchConversation,
};
