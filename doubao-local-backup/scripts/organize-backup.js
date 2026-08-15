'use strict';

const fs = require('fs');
const path = require('path');
const { atomicCopy, atomicWriteJson, atomicWriteText, ensureDir } = require('./lib/atomic-json');
const { normalizedAttachments, uniqueStrings, validateEnvelope } = require('./lib/conversation');
const { datePrefix, extensionFor, findAttachment, safeName, sha256 } = require('./lib/file-store');

function arg(name, fallback = null) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

const rawDir = path.resolve(arg('--raw') || '');
const outDir = path.resolve(arg('--out') || '');
if (!arg('--raw') || !arg('--out')) throw new Error('Usage: node organize-backup.js --raw <raw-dir> --out <new-candidate-dir>');
if (!fs.existsSync(rawDir)) throw new Error(`Raw state not found: ${rawDir}`);
if (fs.existsSync(outDir)) throw new Error(`Candidate must not already exist: ${outDir}`);
if (!path.relative(rawDir, outDir) || !path.relative(outDir, rawDir)) throw new Error('Raw and candidate paths must be different');

const conversationSource = path.join(rawDir, 'conversations');
const rawFiles = path.join(rawDir, 'files');
const conversationOut = path.join(outDir, 'conversations');
const attachmentOut = path.join(outDir, 'attachments', 'files');
const metadataOut = path.join(outDir, 'metadata');
for (const directory of [conversationOut, attachmentOut, metadataOut]) ensureDir(directory);

const parseFailures = [];
const duplicateConversationIds = [];
const conversationIndex = [];
const envelopeHashes = new Map();
const attachmentRefs = new Map();

const names = fs.existsSync(conversationSource)
  ? fs.readdirSync(conversationSource).filter(name => name.toLowerCase().endsWith('.json')).sort()
  : [];

for (const name of names) {
  const source = path.join(conversationSource, name);
  try {
    const envelope = validateEnvelope(JSON.parse(fs.readFileSync(source, 'utf8')));
    const id = envelope.conversation_id;
    if (envelopeHashes.has(id)) {
      duplicateConversationIds.push(id);
      continue;
    }
    const digest = sha256(source);
    envelopeHashes.set(id, digest);
    const title = envelope.derived.title || null;
    const date = datePrefix(envelope.derived.created_at || envelope.derived.updated_at || envelope.collected_at);
    const target = path.join(conversationOut, `${date}__${safeName(title)}__${safeName(id, 'unknown-id', 160)}.json`);
    atomicCopy(source, target);
    const attachments = normalizedAttachments(envelope);
    conversationIndex.push({
      conversation_id: id,
      title,
      created_at: envelope.derived.created_at || null,
      updated_at: envelope.derived.updated_at || null,
      content_fingerprint: envelope.derived.content_fingerprint || null,
      collected_at: envelope.collected_at || null,
      message_count: uniqueStrings(envelope.derived.message_ids).length,
      attachment_ids: attachments.map(item => item.attachment_id),
      raw_sha256: digest,
      stored_path: path.relative(outDir, target).replace(/\\/g, '/'),
    });
    for (const attachment of attachments) {
      if (!attachmentRefs.has(attachment.attachment_id)) attachmentRefs.set(attachment.attachment_id, { ...attachment, referenced_by: [] });
      const reference = attachmentRefs.get(attachment.attachment_id);
      if (!reference.referenced_by.some(item => item.conversation_id === id && item.message_id === attachment.message_id)) {
        reference.referenced_by.push({ conversation_id: id, message_id: attachment.message_id || null });
      }
    }
  } catch (error) {
    parseFailures.push({ file: path.relative(rawDir, source).replace(/\\/g, '/'), error: error.message });
  }
}

const byHash = new Map();
const failedAttachments = [];
let bytesBeforeDedup = 0;
for (const reference of attachmentRefs.values()) {
  const source = findAttachment(rawFiles, reference.attachment_id);
  if (!source) {
    failedAttachments.push({ attachment_id: reference.attachment_id, reason: 'referenced file missing or ambiguous in raw state' });
    continue;
  }
  const stat = fs.statSync(source);
  if (stat.size === 0) {
    failedAttachments.push({ attachment_id: reference.attachment_id, reason: 'referenced file is zero bytes' });
    continue;
  }
  bytesBeforeDedup += stat.size;
  const digest = sha256(source);
  if (!byHash.has(digest)) {
    const extension = extensionFor(source, reference.original_name);
    const stored = path.join(attachmentOut, `${digest.slice(0, 16)}__${safeName(reference.attachment_id, 'attachment', 120)}${extension}`);
    atomicCopy(source, stored);
    byHash.set(digest, {
      sha256: digest,
      size_bytes: stat.size,
      mime_type: reference.mime_type,
      stored_path: path.relative(outDir, stored).replace(/\\/g, '/'),
      attachment_ids: [],
      original_names: [],
      referenced_by: [],
    });
  }
  const manifestItem = byHash.get(digest);
  if (!manifestItem.attachment_ids.includes(reference.attachment_id)) manifestItem.attachment_ids.push(reference.attachment_id);
  if (reference.original_name && !manifestItem.original_names.includes(reference.original_name)) manifestItem.original_names.push(reference.original_name);
  for (const origin of reference.referenced_by) {
    if (!manifestItem.referenced_by.some(item => item.conversation_id === origin.conversation_id && item.message_id === origin.message_id)) {
      manifestItem.referenced_by.push(origin);
    }
  }
}

const manifest = { schema_version: 1, provider: 'doubao', files: [...byHash.values()] };
const bytesAfterDedup = manifest.files.reduce((sum, item) => sum + item.size_bytes, 0);
const exportReport = {
  schema_version: 1,
  provider: 'doubao',
  organized_at: new Date().toISOString(),
  conversations_saved: conversationIndex.length,
  failed_conversations: parseFailures,
  duplicate_conversation_ids: duplicateConversationIds,
  attachments_referenced: attachmentRefs.size,
  attachments_saved: manifest.files.length,
  failed_attachments: failedAttachments,
  warnings: [],
};
if (parseFailures.length) exportReport.warnings.push(`${parseFailures.length} conversation envelope(s) failed validation`);
if (duplicateConversationIds.length) exportReport.warnings.push(`${duplicateConversationIds.length} duplicate conversation ID(s) found`);
if (failedAttachments.length) exportReport.warnings.push(`${failedAttachments.length} attachment(s) failed`);

atomicWriteJson(path.join(outDir, 'attachments', 'manifest.json'), manifest);
atomicWriteJson(path.join(metadataOut, 'conversation-index.json'), conversationIndex);
atomicWriteJson(path.join(metadataOut, 'export-report.json'), exportReport);
atomicWriteJson(path.join(metadataOut, 'dedup-report.json'), {
  attachment_ids_referenced: attachmentRefs.size,
  physical_files_after_dedup: manifest.files.length,
  bytes_before_dedup: bytesBeforeDedup,
  bytes_after_dedup: bytesAfterDedup,
  bytes_saved_by_dedup: bytesBeforeDedup - bytesAfterDedup,
});
atomicWriteText(path.join(outDir, 'README.txt'), [
  'Doubao local backup',
  '',
  'conversations/             Sanitized provider-response envelopes in JSON.',
  'attachments/files/         Original retained attachments deduplicated by SHA-256.',
  'attachments/manifest.json  Hashes, provider IDs, paths, and conversation/message references.',
  'metadata/                  Conversation index and export, deduplication, and verification reports.',
  '',
  'No permanent Markdown, HTML, PDF, TXT, JSONL, or ZIP chat derivative was generated.',
  'Original user attachments retain their original formats.',
  'Authentication material and complete temporary signed URLs are not intentionally stored.',
  '',
].join('\r\n'));

console.log(JSON.stringify({ candidate: outDir, export_report: exportReport }, null, 2));
