'use strict';

const fs = require('fs');
const path = require('path');
const { atomicWriteJson } = require('./lib/atomic-json');
const { readArchiveProfile, resolveArchiveRoot } = require('./lib/archive-profile');
const { buildConversationEnvelope, discoverConversations, fetchConversationPage } = require('./lib/doubao-adapter');
const { checkpointSnapshotHash, loadExecutionPlan, remoteSnapshotHash } = require('./lib/monitoring');
const {
  initializeRawState,
  recordAttachmentFailure,
  recordConversationFailure,
  saveAttachment,
  saveConversation,
  shouldFetchConversation,
} = require('./lib/raw-state');

function arg(name, fallback = null) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

function fixtureAdapter(file) {
  const fixture = JSON.parse(fs.readFileSync(path.resolve(file), 'utf8'));
  if (!Array.isArray(fixture.conversations)) throw new Error('Fixture must contain a conversations array');
  const byId = new Map(fixture.conversations.map(item => [item.summary?.conversation_id, item]));
  return {
    async discover() {
      return fixture.conversations.map(item => item.summary);
    },
    async collect(summary) {
      const item = byId.get(summary.conversation_id);
      if (!item) throw new Error(`Fixture conversation missing: ${summary.conversation_id}`);
      return item;
    },
  };
}

function liveAdapter(pageSize) {
  return {
    async discover(options = {}) {
      return discoverConversations(options);
    },
    async collect(summary) {
      return fetchConversationPage(summary.conversation_id, { pageSize });
    },
  };
}

const fixture = arg('--fixture');
const limitValue = arg('--limit');
const limit = limitValue == null ? null : Number(limitValue);
if (limit != null && (!Number.isInteger(limit) || limit < 1)) throw new Error('--limit must be a positive integer');
const pageSize = Number(arg('--page-size', '20'));
if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > 20) throw new Error('--page-size must be an integer from 1 to 20');
const adapter = fixture ? fixtureAdapter(fixture) : liveAdapter(pageSize);
const executionPlanPath = arg('--plan');
if (!fixture && !executionPlanPath) throw new Error('Live export requires --plan from the automatic planning step');
const { root } = resolveArchiveRoot('doubao');
if (!fixture) readArchiveProfile(root, 'doubao', ['final/Doubao_Backup', 'state/raw']);
const rawDir = path.resolve(arg('--raw', path.join(root, 'state', 'raw')));
const workingRoot = path.join(root, 'working', 'downloads');
process.env.DOUBAO_WORKING_ROOT = workingRoot;
const execution = executionPlanPath ? loadExecutionPlan(path.resolve(executionPlanPath)) : null;

(async () => {
  const discoveryOptions = execution?.plan.snapshot.scan_scope === 'recent-page' ? { maxPages: 1 } : {};
  const discoveredSummaries = await adapter.discover(discoveryOptions);
  const state = initializeRawState(rawDir);
  if (execution) {
    const currentRemoteHash = remoteSnapshotHash(discoveredSummaries);
    const currentCheckpointHash = checkpointSnapshotHash(state.checkpoint);
    const retryCompatibleCheckpointHash = checkpointSnapshotHash({
      ...state.checkpoint,
      failed_conversations: [],
      failed_attachments: [],
    });
    if (currentRemoteHash !== execution.plan.snapshot.remote_snapshot_hash) {
      throw new Error('Automatic plan is stale because the remote conversation snapshot changed');
    }
    if (
      currentCheckpointHash !== execution.plan.snapshot.checkpoint_snapshot_hash
      && retryCompatibleCheckpointHash !== execution.plan.snapshot.checkpoint_snapshot_hash
    ) {
      throw new Error('Automatic plan is stale because the local checkpoint changed');
    }
  }
  const summaries = limit == null ? discoveredSummaries : discoveredSummaries.slice(0, limit);
  if (!Array.isArray(summaries)) throw new Error('Adapter did not return a conversation summary array');
  const index = [];
  const report = {
    provider: 'doubao',
    mode: fixture ? 'synthetic-fixture' : 'live',
    plan_id: execution?.plan.plan_id || null,
    started_at: new Date().toISOString(),
    discovered: discoveredSummaries.length,
    selected: summaries.length,
    saved: 0,
    skipped: 0,
    failed: 0,
    attachments_saved: 0,
    attachments_failed: 0,
    errors: [],
  };

  for (const summary of summaries) {
    const id = summary?.conversation_id;
    try {
      const currentState = initializeRawState(rawDir);
      const decision = shouldFetchConversation(currentState.checkpoint, summary);
      index.push({
        conversation_id: id,
        title: summary.title ?? null,
        created_at: summary.created_at ?? null,
        updated_at: summary.updated_at ?? null,
        content_fingerprint: summary.content_fingerprint ?? null,
      });
      if (!decision.fetch) {
        report.skipped++;
        continue;
      }
      const collected = await adapter.collect(summary);
      const envelope = buildConversationEnvelope({
        conversationId: id,
        collectedAt: collected.collected_at || new Date().toISOString(),
        pages: collected.pages,
        metadata: collected.metadata,
      });
      saveConversation(rawDir, envelope);
      report.saved++;

      for (const attachment of collected.attachments || []) {
        try {
          if (attachment.download_error) throw new Error(attachment.download_error);
          if (!attachment.source_path) throw new Error('Adapter did not provide a temporary attachment file');
          saveAttachment(rawDir, attachment, path.resolve(attachment.source_path));
          report.attachments_saved++;
        } catch (error) {
          recordAttachmentFailure(rawDir, attachment.attachment_id, error);
          report.attachments_failed++;
        } finally {
          if (attachment.cleanup && attachment.source_path) {
            const temp = path.resolve(attachment.source_path);
            const relative = path.relative(workingRoot, temp);
            if (relative && !relative.startsWith('..') && !path.isAbsolute(relative) && fs.existsSync(temp)) fs.rmSync(temp, { force: true });
          }
        }
      }
    } catch (error) {
      const failure = recordConversationFailure(rawDir, id, error);
      report.failed++;
      report.errors.push({ error: failure.error, recorded_at: failure.recorded_at });
    }
  }

  const indexPath = path.join(rawDir, 'conversation-index.json');
  let previousIndex = [];
  try { previousIndex = JSON.parse(fs.readFileSync(indexPath, 'utf8')); } catch {}
  const mergedIndex = new Map(previousIndex.map(item => [item.conversation_id, item]));
  for (const item of index) mergedIndex.set(item.conversation_id, item);
  atomicWriteJson(indexPath, [...mergedIndex.values()]);
  const latest = initializeRawState(rawDir);
  latest.checkpoint.last_successful_run = report.failed === 0 ? new Date().toISOString() : latest.checkpoint.last_successful_run;
  const { saveCheckpoint } = require('./lib/checkpoint');
  saveCheckpoint(latest.checkpointPath, latest.checkpoint);
  report.completed_at = new Date().toISOString();
  if (execution) {
    atomicWriteJson(path.join(path.dirname(execution.planPath), 'raw-export-result.json'), {
      ...report,
      errors: report.errors,
    });
  }
  console.log(JSON.stringify(report, null, 2));
  if (report.failed > 0 || report.attachments_failed > 0) process.exitCode = 1;
})().catch(error => {
  console.error(`Doubao raw export failed: ${error.message}`);
  process.exitCode = 1;
});
