'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { DoubaoLiveAdapter } = require('./lib/doubao-adapter');

function arg(name, fallback = null) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

function setHash(values) {
  return crypto.createHash('sha256').update([...new Set(values)].sort().join('\n')).digest('hex');
}

const rootArg = arg('--root');
const rawArg = arg('--raw');
if (!rootArg && !rawArg) throw new Error('Usage: node verify-long-conversation.js --root <profile-root> [--raw <raw-dir>]');
const rawDir = path.resolve(rawArg || path.join(path.resolve(rootArg), 'state', 'raw'));
const files = fs.readdirSync(path.join(rawDir, 'conversations')).filter(name => name.endsWith('.json'));
let longest = null;
for (const name of files) {
  const envelope = JSON.parse(fs.readFileSync(path.join(rawDir, 'conversations', name), 'utf8'));
  const pages = envelope.derived?.pagination?.pages || 0;
  if (!longest || pages > longest.pages) longest = { envelope, pages };
}
if (!longest || longest.pages < 2) throw new Error('No multi-page conversation exists in raw state');

(async () => {
  const adapter = new DoubaoLiveAdapter();
  await adapter.discoverConversations();
  const collected = await adapter.collectConversation(longest.envelope.conversation_id);
  const oldIds = longest.envelope.derived.message_ids || [];
  const newIds = collected.metadata.messageIds || [];
  const oldHash = setHash(oldIds);
  const newHash = setHash(newIds);
  const result = {
    passed: oldHash === newHash && new Set(oldIds).size === new Set(newIds).size,
    old_pages: longest.pages,
    new_pages: collected.metadata.pagination?.pages || 0,
    old_unique_messages: new Set(oldIds).size,
    new_unique_messages: new Set(newIds).size,
    message_set_sha256_equal: oldHash === newHash,
    stop_reason: collected.metadata.pagination?.stopReason || null,
  };
  console.log(JSON.stringify(result, null, 2));
  if (!result.passed) process.exitCode = 1;
})().catch(error => {
  console.error(`Long-conversation verification failed: ${error.message}`);
  process.exitCode = 1;
});
