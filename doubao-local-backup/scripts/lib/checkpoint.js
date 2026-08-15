'use strict';

const fs = require('fs');
const { atomicWriteJson } = require('./atomic-json');

const FORBIDDEN_KEY = /(authorization|cookie|token|secret|password|signed[_-]?url|download[_-]?url)/i;

function emptyCheckpoint() {
  return {
    schema_version: 1,
    provider: 'doubao',
    list_cursor: null,
    completed_conversations: {},
    completed_attachments: {},
    failed_conversations: [],
    failed_attachments: [],
    last_successful_run: null,
  };
}

function assertSafeMetadata(value, pointer = '') {
  if (!value || typeof value !== 'object') return;
  for (const [key, child] of Object.entries(value)) {
    const childPointer = `${pointer}/${key.replace(/~/g, '~0').replace(/\//g, '~1')}`;
    if (FORBIDDEN_KEY.test(key)) throw new Error(`Credential-shaped key is forbidden in persisted metadata: ${childPointer}`);
    assertSafeMetadata(child, childPointer);
  }
}

function validateCheckpoint(checkpoint) {
  if (!checkpoint || checkpoint.schema_version !== 1 || checkpoint.provider !== 'doubao') {
    throw new Error('Unsupported or invalid Doubao checkpoint');
  }
  assertSafeMetadata(checkpoint);
  return checkpoint;
}

function loadCheckpoint(file) {
  if (!fs.existsSync(file)) return emptyCheckpoint();
  return validateCheckpoint(JSON.parse(fs.readFileSync(file, 'utf8')));
}

function saveCheckpoint(file, checkpoint) {
  validateCheckpoint(checkpoint);
  atomicWriteJson(file, checkpoint);
}

module.exports = { assertSafeMetadata, emptyCheckpoint, loadCheckpoint, saveCheckpoint, validateCheckpoint };
