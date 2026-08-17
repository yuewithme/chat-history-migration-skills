'use strict';

const path = require('path');
const { DoubaoLiveAdapter } = require('./lib/doubao-adapter');
const { initializeRawState, shouldFetchConversation } = require('./lib/raw-state');

function arg(name, fallback = null) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

const rootArg = arg('--root');
const rawArg = arg('--raw');
if (!rootArg && !rawArg) throw new Error('Usage: node diagnose-incremental.js --root <profile-root> [--raw <raw-dir>]');
const rawDir = path.resolve(rawArg || path.join(path.resolve(rootArg), 'state', 'raw'));
const limit = Number(arg('--limit', '10'));

(async () => {
  const adapter = new DoubaoLiveAdapter();
  const summaries = (await adapter.discoverConversations()).slice(0, limit);
  const state = initializeRawState(rawDir);
  const counts = {};
  const comparisons = [];
  for (const summary of summaries) {
    const existing = state.checkpoint.completed_conversations[summary.conversation_id] || null;
    const decision = shouldFetchConversation(state.checkpoint, summary);
    counts[decision.reason] = (counts[decision.reason] || 0) + 1;
    comparisons.push({
      existing: !!existing,
      decision: decision.reason,
      updated_type_remote: typeof summary.updated_at,
      updated_type_local: existing ? typeof existing.updated_at : 'missing',
      updated_equal: existing ? existing.updated_at === summary.updated_at : false,
      fingerprint_type_remote: typeof summary.content_fingerprint,
      fingerprint_type_local: existing ? typeof existing.content_fingerprint : 'missing',
      fingerprint_equal: existing ? existing.content_fingerprint === summary.content_fingerprint : false,
    });
  }
  console.log(JSON.stringify({ selected: summaries.length, checkpoint_entries: Object.keys(state.checkpoint.completed_conversations).length, decisions: counts, comparisons }, null, 2));
})().catch(error => {
  console.error(`Incremental diagnosis failed: ${error.message}`);
  process.exitCode = 1;
});
