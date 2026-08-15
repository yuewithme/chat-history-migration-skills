'use strict';

const fs = require('fs');
const path = require('path');
const { atomicWriteJson } = require('./lib/atomic-json');
const { normalizedAttachments, validateEnvelope } = require('./lib/conversation');
const { sha256 } = require('./lib/file-store');
const { isEphemeralSignedUrl, isSensitiveKey } = require('./lib/redaction');

function arg(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : null;
}

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

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function unsafeMetadataHits(value, file, pointer = '', result = []) {
  if (typeof value === 'string') {
    if (isEphemeralSignedUrl(value)) result.push({ file, json_pointer: pointer || '/', reason: 'complete ephemeral signed URL' });
    if (/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/.test(value)) {
      result.push({ file, json_pointer: pointer || '/', reason: 'JWT-shaped value' });
    }
    return result;
  }
  if (!value || typeof value !== 'object') return result;
  for (const [key, child] of Object.entries(value)) {
    const childPointer = `${pointer}/${key.replace(/~/g, '~0').replace(/\//g, '~1')}`;
    if (isSensitiveKey(key)) {
      result.push({ file, json_pointer: childPointer, reason: 'credential-shaped key' });
    }
    unsafeMetadataHits(child, file, childPointer, result);
  }
  return result;
}

function unsafeConversationHits(value, file, pointer = '', result = []) {
  if (typeof value === 'string') {
    if (isEphemeralSignedUrl(value)) result.push({ file, json_pointer: pointer || '/', reason: 'complete ephemeral signed URL' });
    return result;
  }
  if (!value || typeof value !== 'object') return result;
  for (const [key, child] of Object.entries(value)) {
    const childPointer = `${pointer}/${key.replace(/~/g, '~0').replace(/\//g, '~1')}`;
    if (isSensitiveKey(key) && child != null) result.push({ file, json_pointer: childPointer, reason: 'non-null authentication material' });
    unsafeConversationHits(child, file, childPointer, result);
  }
  return result;
}

const rawDir = path.resolve(arg('--raw') || '');
const finalDir = path.resolve(arg('--final') || '');
const allowEmpty = process.argv.includes('--allow-empty');
if (!arg('--raw') || !arg('--final')) throw new Error('Usage: node verify-backup.js --raw <raw-dir> --final <candidate-dir>');

const manifestPath = path.join(finalDir, 'attachments', 'manifest.json');
const reportPath = path.join(finalDir, 'metadata', 'export-report.json');
if (!fs.existsSync(manifestPath) || !fs.existsSync(reportPath)) throw new Error('Candidate metadata is incomplete');
const manifest = readJson(manifestPath);
const exportReport = readJson(reportPath);

const rawById = new Map();
const rawParseFailures = [];
const rawDuplicateIds = [];
const referencedAttachmentIds = new Set();
for (const file of jsonFiles(path.join(rawDir, 'conversations'))) {
  try {
    const envelope = validateEnvelope(readJson(file));
    if (rawById.has(envelope.conversation_id)) rawDuplicateIds.push(envelope.conversation_id);
    rawById.set(envelope.conversation_id, file);
    for (const attachment of normalizedAttachments(envelope)) referencedAttachmentIds.add(attachment.attachment_id);
  } catch (error) {
    rawParseFailures.push({ file: path.relative(rawDir, file).replace(/\\/g, '/'), error: error.message });
  }
}

const finalIds = new Set();
const finalParseFailures = [];
const duplicateConversationIds = [];
const zeroByteFiles = [];
const conversationHashMismatches = [];
const unsafeConversationValues = [];
for (const file of jsonFiles(path.join(finalDir, 'conversations'))) {
  if (fs.statSync(file).size === 0) zeroByteFiles.push(path.relative(finalDir, file).replace(/\\/g, '/'));
  try {
    const envelope = validateEnvelope(readJson(file));
    const id = envelope.conversation_id;
    if (finalIds.has(id)) duplicateConversationIds.push(id);
    finalIds.add(id);
    const rawFile = rawById.get(id);
    if (!rawFile || sha256(rawFile) !== sha256(file)) conversationHashMismatches.push(id);
    unsafeConversationHits(envelope.responses, path.relative(finalDir, file).replace(/\\/g, '/'), '/responses', unsafeConversationValues);
  } catch (error) {
    finalParseFailures.push({ file: path.relative(finalDir, file).replace(/\\/g, '/'), error: error.message });
  }
}

const manifestIds = new Set();
const missingManifestFiles = [];
const badManifestHashes = [];
const badManifestSizes = [];
const duplicateStoredPaths = [];
const storedPaths = new Set();
for (const item of manifest.files || []) {
  const relative = item.stored_path;
  const target = path.resolve(finalDir, relative || '');
  const relation = path.relative(finalDir, target);
  if (!relative || relation.startsWith('..') || path.isAbsolute(relation)) {
    missingManifestFiles.push(relative || '(missing path)');
    continue;
  }
  if (storedPaths.has(relative)) duplicateStoredPaths.push(relative);
  storedPaths.add(relative);
  if (!fs.existsSync(target)) missingManifestFiles.push(relative);
  else {
    const stat = fs.statSync(target);
    if (stat.size === 0) zeroByteFiles.push(relative);
    if (stat.size !== item.size_bytes) badManifestSizes.push(relative);
    if (sha256(target) !== item.sha256) badManifestHashes.push(relative);
  }
  for (const id of item.attachment_ids || []) manifestIds.add(id);
}

const failedIds = new Set((exportReport.failed_attachments || []).map(item => item.attachment_id));
const unaccountedAttachmentIds = [...referencedAttachmentIds].filter(id => !manifestIds.has(id) && !failedIds.has(id));

const forbiddenChatDerivatives = [];
const conversationRoot = path.join(finalDir, 'conversations');
if (fs.existsSync(conversationRoot)) {
  for (const entry of fs.readdirSync(conversationRoot, { withFileTypes: true })) {
    if (entry.isFile() && !entry.name.toLowerCase().endsWith('.json')) forbiddenChatDerivatives.push(`conversations/${entry.name}`);
  }
}

const unsafeMetadata = [];
for (const file of jsonFiles(path.join(finalDir, 'metadata')).concat([manifestPath])) {
  try {
    unsafeMetadataHits(readJson(file), path.relative(finalDir, file).replace(/\\/g, '/'), '', unsafeMetadata);
  } catch (error) {
    finalParseFailures.push({ file: path.relative(finalDir, file).replace(/\\/g, '/'), error: error.message });
  }
}

const result = {
  passed: false,
  empty_backup: rawById.size === 0,
  verified_at: new Date().toISOString(),
  raw_conversations: rawById.size,
  final_conversations: finalIds.size,
  raw_parse_failures: rawParseFailures,
  final_parse_failures: finalParseFailures,
  raw_duplicate_conversation_ids: rawDuplicateIds,
  duplicate_conversation_ids: duplicateConversationIds,
  conversation_hash_mismatches: conversationHashMismatches,
  manifest_files: (manifest.files || []).length,
  referenced_attachment_ids: referencedAttachmentIds.size,
  unaccounted_attachment_ids: unaccountedAttachmentIds,
  missing_manifest_files: missingManifestFiles,
  bad_manifest_hashes: badManifestHashes,
  bad_manifest_sizes: badManifestSizes,
  duplicate_stored_paths: duplicateStoredPaths,
  zero_byte_files: [...new Set(zeroByteFiles)],
  forbidden_chat_derivatives: forbiddenChatDerivatives,
  unsafe_metadata_keys: unsafeMetadata,
  unsafe_conversation_values: unsafeConversationValues,
  failed_conversations: exportReport.failed_conversations || [],
  failed_attachments: exportReport.failed_attachments || [],
};

const failureLists = [
  result.raw_parse_failures,
  result.final_parse_failures,
  result.raw_duplicate_conversation_ids,
  result.duplicate_conversation_ids,
  result.conversation_hash_mismatches,
  result.unaccounted_attachment_ids,
  result.missing_manifest_files,
  result.bad_manifest_hashes,
  result.bad_manifest_sizes,
  result.duplicate_stored_paths,
  result.zero_byte_files,
  result.forbidden_chat_derivatives,
  result.unsafe_metadata_keys,
  result.unsafe_conversation_values,
  result.failed_conversations,
  result.failed_attachments,
];
result.passed = (allowEmpty || !result.empty_backup)
  && result.raw_conversations === result.final_conversations
  && failureLists.every(items => items.length === 0);
atomicWriteJson(path.join(finalDir, 'metadata', 'final-verification.json'), result);
console.log(JSON.stringify(result, null, 2));
if (!result.passed) process.exitCode = 1;
