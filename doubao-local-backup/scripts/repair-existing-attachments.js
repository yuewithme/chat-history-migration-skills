'use strict';

const fs = require('fs');
const path = require('path');
const { atomicWriteJson } = require('./lib/atomic-json');
const { readArchiveProfile, resolveArchiveRoot } = require('./lib/archive-profile');
const { DoubaoLiveAdapter } = require('./lib/doubao-adapter');
const { downloadAttachment, extractAttachmentCandidates, publicReference } = require('./lib/doubao-attachments');
const { sha256 } = require('./lib/file-store');
const { sanitizeForPersistence } = require('./lib/redaction');
const {
  initializeRawState,
  recordAttachmentFailure,
  saveAttachment,
} = require('./lib/raw-state');
const { saveCheckpoint } = require('./lib/checkpoint');

function arg(name, fallback = null) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

const { root } = resolveArchiveRoot('doubao');
readArchiveProfile(root, 'doubao', ['final/Doubao_Backup', 'state/raw']);
const rawDir = path.resolve(arg('--raw', path.join(root, 'state', 'raw')));
process.env.DOUBAO_WORKING_ROOT = path.join(root, 'working', 'downloads');
const limitValue = arg('--limit-attachments');
const limit = limitValue == null ? null : Number(limitValue);
if (limit != null && (!Number.isInteger(limit) || limit < 1)) throw new Error('--limit-attachments must be a positive integer');

function mergeRedactions(existing, added) {
  const byKey = new Map();
  for (const item of [...(existing || []), ...added]) byKey.set(`${item.json_pointer}:${item.reason}`, item);
  return [...byKey.values()];
}

(async () => {
  const records = [];
  const globalCandidates = new Map();
  for (const name of fs.readdirSync(path.join(rawDir, 'conversations')).filter(item => item.endsWith('.json'))) {
    const file = path.join(rawDir, 'conversations', name);
    const envelope = JSON.parse(fs.readFileSync(file, 'utf8'));
    const candidates = extractAttachmentCandidates(envelope.responses.map(item => item.response));
    for (const candidate of candidates) if (!globalCandidates.has(candidate.attachment_id)) globalCandidates.set(candidate.attachment_id, candidate);
    records.push({ file, envelope, candidates });
  }

  const adapter = new DoubaoLiveAdapter();
  await adapter.initialize();
  const resolved = await adapter.resolveAttachmentCandidates([...globalCandidates.values()]);
  const state = initializeRawState(rawDir);
  const selected = limit == null ? resolved : resolved.slice(0, limit);
  let downloadedCount = 0;
  let skippedCount = 0;
  let failedCount = 0;
  const downloadedIds = new Set();

  for (const candidate of selected) {
    if (state.checkpoint.completed_attachments[candidate.attachment_id]) {
      skippedCount++;
      downloadedIds.add(candidate.attachment_id);
      continue;
    }
    let downloaded = null;
    try {
      if (!candidate.download_url) throw new Error('Resource resolver returned no download URL');
      downloaded = await downloadAttachment(candidate);
      saveAttachment(rawDir, downloaded, downloaded.source_path);
      downloadedIds.add(candidate.attachment_id);
      downloadedCount++;
    } catch (error) {
      recordAttachmentFailure(rawDir, candidate.attachment_id, error);
      failedCount++;
    } finally {
      if (downloaded?.source_path && fs.existsSync(downloaded.source_path)) fs.rmSync(downloaded.source_path, { force: true });
    }
  }

  let redactionsAdded = 0;
  for (const record of records) {
    record.envelope.derived.attachments = record.candidates.map(publicReference);
    const added = [];
    record.envelope.responses = record.envelope.responses.map((response, index) => {
      const sanitized = sanitizeForPersistence(response.response);
      for (const item of sanitized.redactions) {
        added.push({ ...item, json_pointer: `/responses/${index}/response${item.json_pointer === '/' ? '' : item.json_pointer}` });
      }
      return { ...response, response: sanitized.value };
    });
    redactionsAdded += added.length;
    record.envelope.redactions = mergeRedactions(record.envelope.redactions, added);
    atomicWriteJson(record.file, record.envelope);
  }

  const finalState = initializeRawState(rawDir);
  for (const record of records) {
    const existing = finalState.checkpoint.completed_conversations[record.envelope.conversation_id] || {};
    finalState.checkpoint.completed_conversations[record.envelope.conversation_id] = {
      ...existing,
      updated_at: record.envelope.derived.updated_at || null,
      content_fingerprint: record.envelope.derived.content_fingerprint || existing.content_fingerprint || null,
      content_sha256: sha256(record.file),
    };
  }
  saveCheckpoint(finalState.checkpointPath, finalState.checkpoint);

  console.log(JSON.stringify({
    conversations_processed: records.length,
    unique_attachment_candidates: globalCandidates.size,
    selected_attachments: selected.length,
    downloaded: downloadedCount,
    skipped_existing: skippedCount,
    failed: failedCount,
    redactions_added: redactionsAdded,
    checkpoint_attachment_ids: Object.keys(finalState.checkpoint.completed_attachments).length,
  }, null, 2));
  if (failedCount) process.exitCode = 1;
})().catch(error => {
  console.error(`Attachment repair failed: ${String(error.message || error).replace(/https?:\/\/\S+/g, '[redacted-url]')}`);
  process.exitCode = 1;
});
