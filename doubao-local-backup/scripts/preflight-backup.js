'use strict';

const fs = require('fs');
const path = require('path');
const { atomicWriteJson, assertInside, ensureDir } = require('./lib/atomic-json');
const { discoverConversations } = require('./lib/doubao-adapter');
const { initializeRawState } = require('./lib/raw-state');
const { sanitizeDiagnostic } = require('./lib/redaction');
const {
  buildPreflightDiff,
  checkpointSnapshotHash,
  loadJson,
  planHash,
  remoteSnapshotHash,
  renderFailureHtml,
  renderPreflightHtml,
  sha256Canonical,
  writeReportFiles,
} = require('./lib/monitoring');

function arg(name, fallback = null) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

function has(name) {
  return process.argv.includes(name);
}

function runId(now = new Date()) {
  return now.toISOString().replace(/[-:.]/g, '');
}

function acquireLock(file) {
  ensureDir(path.dirname(file));
  try {
    const descriptor = fs.openSync(file, 'wx');
    fs.writeFileSync(descriptor, `${JSON.stringify({ pid: process.pid, started_at: new Date().toISOString() })}\n`, 'utf8');
    fs.closeSync(descriptor);
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    const age = Date.now() - fs.statSync(file).mtimeMs;
    if (age < 30 * 60 * 1000) throw new Error('Another Doubao preflight or backup operation is active');
    fs.rmSync(file, { force: false });
    return acquireLock(file);
  }
  return () => { if (fs.existsSync(file)) fs.rmSync(file, { force: false }); };
}

function fixtureSummaries(file) {
  const fixture = JSON.parse(fs.readFileSync(path.resolve(file), 'utf8'));
  if (Array.isArray(fixture.summaries)) return fixture.summaries;
  if (Array.isArray(fixture.conversations)) return fixture.conversations.map(item => item.summary);
  throw new Error('Fixture must contain summaries or conversations');
}

function plannedActions(diff, finalVerification) {
  const actions = [];
  if (diff.new_count) actions.push(`采集 ${diff.new_count} 条新增会话。`);
  if (diff.changed_count) actions.push(`重新采集 ${diff.changed_count} 条发生变化的会话。`);
  if (diff.failed_conversation_count || diff.failed_attachment_count) actions.push('重试现有失败会话或附件。');
  if (diff.remote_missing_count) actions.push(`保留 ${diff.remote_missing_count} 条线上暂时缺失的本地历史，不执行删除。`);
  if (finalVerification?.passed !== true) actions.push('重新验证候选；正式备份校验未通过前禁止发布。');
  if (actions.length) actions.push('生成独立候选，完整校验通过后原子发布并重建增量状态。');
  else actions.push('没有发现变化；不下载、不组织候选、不发布。');
  return actions;
}

const root = path.resolve(arg('--root', 'D:\\Doubao_Backup'));
const rawDir = path.resolve(arg('--raw', path.join(root, 'state', 'raw')));
const reportRoot = path.resolve(arg('--report-root', path.join(root, 'reports')));
const fixture = arg('--fixture');
const silentIfUnchanged = has('--silent-if-unchanged');
const recentOnly = has('--recent-only') || !has('--complete-listing');
assertInside(root, rawDir, 'Raw state');
assertInside(root, reportRoot, 'Report root');
ensureDir(reportRoot);
const lockPath = path.join(root, 'tool', 'preflight.lock');
const releaseLock = acquireLock(lockPath);

(async () => {
  const now = new Date();
  const checkedAt = now.toISOString();
  const idBase = runId(now);
  const state = initializeRawState(rawDir);
  const summaries = fixture ? fixtureSummaries(fixture) : await discoverConversations(recentOnly ? { maxPages: 1 } : {});
  const diff = buildPreflightDiff(summaries, state.checkpoint, { completeListing: !recentOnly });
  const finalVerificationPath = path.join(root, 'final', 'Doubao_Backup', 'metadata', 'final-verification.json');
  const finalVerification = loadJson(finalVerificationPath);
  const snapshot = {
    ...diff,
    scan_scope: recentOnly ? 'recent-page' : 'complete-listing',
    scanned_count: summaries.length,
    remote_snapshot_hash: remoteSnapshotHash(summaries),
    checkpoint_snapshot_hash: checkpointSnapshotHash(state.checkpoint),
    final_verification_passed: finalVerification?.passed === true,
    final_verified_at: finalVerification?.verified_at ?? null,
  };
  const attentionNeeded = diff.new_count > 0
    || diff.changed_count > 0
    || diff.remote_missing_count > 0
    || diff.failed_conversation_count > 0
    || diff.failed_attachment_count > 0
    || finalVerification?.passed !== true;
  const attentionFingerprint = sha256Canonical({ ...snapshot, final_verified_at: null });
  const pendingPath = path.join(reportRoot, 'pending-plan.json');
  const monitorPath = path.join(reportRoot, 'monitor-state.json');
  if (fs.existsSync(pendingPath)) fs.rmSync(pendingPath, { force: false });
  const latestPath = path.join(reportRoot, 'latest.html');
  if (fs.existsSync(latestPath)) fs.rmSync(latestPath, { force: false });

  if (!attentionNeeded && silentIfUnchanged) {
    const monitor = { schema_version: 1, provider: 'doubao', checked_at: checkedAt, status: 'unchanged', ...snapshot };
    atomicWriteJson(monitorPath, monitor);
    console.log(JSON.stringify({ checked_at: checkedAt, status: 'unchanged', report_created: false, ...diff }, null, 2));
    return;
  }

  const planId = `${idBase}-${attentionFingerprint.slice(0, 8)}`;
  const plan = {
    schema_version: 1,
    provider: 'doubao',
    plan_id: planId,
    created_at: checkedAt,
    expires_at: new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000).toISOString(),
    status: attentionNeeded ? 'ready_to_execute' : 'no_changes',
    execution_mode: 'automatic',
    source_mode: fixture ? 'synthetic-fixture' : 'live-read-only',
    snapshot,
    planned_actions: plannedActions(diff, finalVerification),
  };
  plan.plan_hash = planHash(plan);
  const html = renderPreflightHtml(plan);
  const written = writeReportFiles(reportRoot, planId, plan, html);
  atomicWriteJson(monitorPath, { schema_version: 1, provider: 'doubao', checked_at: checkedAt, status: plan.status, report_path: written.report_path, ...snapshot });
  console.log(JSON.stringify({ checked_at: checkedAt, status: plan.status, report_created: true, report_path: written.report_path, plan_path: path.join(written.run_dir, 'plan.json'), plan_id: planId, ...diff }, null, 2));
})().catch(error => {
  const checkedAt = new Date().toISOString();
  const id = `${runId()}-error`;
  const safeError = sanitizeDiagnostic(error?.message || error);
  const html = renderFailureHtml({ runId: id, checkedAt, error: safeError });
  const written = writeReportFiles(reportRoot, id, null, html);
  atomicWriteJson(path.join(reportRoot, 'monitor-state.json'), {
    schema_version: 1,
    provider: 'doubao',
    checked_at: checkedAt,
    status: 'action_required',
    error: safeError,
    report_path: written.report_path,
  });
  console.error(JSON.stringify({ checked_at: checkedAt, status: 'action_required', report_created: true, report_path: written.report_path, error: safeError }, null, 2));
  process.exitCode = 2;
}).finally(() => releaseLock());
