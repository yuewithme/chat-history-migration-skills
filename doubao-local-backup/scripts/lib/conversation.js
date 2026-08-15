'use strict';

function validateEnvelope(envelope) {
  if (!envelope || typeof envelope !== 'object') throw new Error('Conversation envelope must be an object');
  if (envelope.archive_schema_version !== 1) throw new Error('Unsupported conversation archive schema');
  if (envelope.provider !== 'doubao') throw new Error('Conversation provider must be doubao');
  if (typeof envelope.conversation_id !== 'string' || !envelope.conversation_id.trim()) {
    throw new Error('Conversation envelope has no conversation_id');
  }
  if (!Array.isArray(envelope.responses) || envelope.responses.length === 0) {
    throw new Error('Conversation envelope has no response pages');
  }
  if (!Array.isArray(envelope.redactions)) throw new Error('Conversation redactions must be an array');
  if (!envelope.derived || typeof envelope.derived !== 'object') throw new Error('Conversation derived metadata is missing');
  if (!Array.isArray(envelope.derived.message_ids)) throw new Error('derived.message_ids must be an array');
  if (!Array.isArray(envelope.derived.attachments)) throw new Error('derived.attachments must be an array');
  for (const item of envelope.redactions) {
    if (!item || typeof item.json_pointer !== 'string' || typeof item.reason !== 'string') {
      throw new Error('Invalid redaction record');
    }
  }
  return envelope;
}

function uniqueStrings(values) {
  return [...new Set((values || []).filter(value => typeof value === 'string' && value))];
}

function normalizedAttachments(envelope) {
  const byId = new Map();
  for (const attachment of envelope.derived.attachments || []) {
    const id = attachment?.attachment_id;
    if (typeof id !== 'string' || !id) continue;
    if (!byId.has(id)) {
      byId.set(id, {
        attachment_id: id,
        message_id: attachment.message_id || null,
        original_name: attachment.original_name || null,
        mime_type: attachment.mime_type || null,
        size_bytes: Number.isFinite(attachment.size_bytes) ? attachment.size_bytes : null,
        kind: attachment.kind || 'attachment',
      });
    }
  }
  return [...byId.values()];
}

module.exports = { normalizedAttachments, uniqueStrings, validateEnvelope };
