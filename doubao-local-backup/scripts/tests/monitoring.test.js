'use strict';

const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');
const test = require('node:test');
const { emptyCheckpoint, saveCheckpoint } = require('../lib/checkpoint');
const {
  buildPreflightDiff,
  checkpointSnapshotHash,
  loadExecutionPlan,
  planHash,
  remoteSnapshotHash,
  renderFailureHtml,
  renderPreflightHtml,
} = require('../lib/monitoring');

const scripts = path.resolve(__dirname, '..');

function tempRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'doubao-monitor-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, 'state', 'raw'), { recursive: true });
  fs.mkdirSync(path.join(root, 'final', 'Doubao_Backup', 'metadata'), { recursive: true });
  fs.writeFileSync(path.join(root, 'final', 'Doubao_Backup', 'metadata', 'final-verification.json'), JSON.stringify({ passed: true, verified_at: '2026-08-14T00:00:00.000Z' }));
  return root;
}

function writeFixture(root, summaries) {
  const file = path.join(root, 'fixture.json');
  fs.writeFileSync(file, JSON.stringify({ summaries }), 'utf8');
  return file;
}

function runPreflight(root, fixture, extra = []) {
  return JSON.parse(execFileSync(process.execPath, [
    path.join(scripts, 'preflight-backup.js'), '--root', root, '--fixture', fixture, ...extra,
  ], { encoding: 'utf8' }));
}

test('preflight diff and hashes ignore titles and use update markers', () => {
  const checkpoint = emptyCheckpoint();
  checkpoint.completed_conversations.one = { updated_at: 'v1', content_fingerprint: 'f1', content_sha256: 'a' };
  checkpoint.completed_conversations.missing = { updated_at: 'v1', content_fingerprint: 'f1', content_sha256: 'b' };
  const summaries = [
    { conversation_id: 'one', title: 'private title', updated_at: 'v2', content_fingerprint: 'f1' },
    { conversation_id: 'two', title: 'another title', updated_at: 'v1', content_fingerprint: 'f1' },
  ];
  assert.deepEqual(buildPreflightDiff(summaries, checkpoint), {
    remote_count: 2,
    local_completed_count: 2,
    new_count: 1,
    changed_count: 1,
    unchanged_count: 0,
    remote_missing_count: 1,
    failed_conversation_count: 0,
    failed_attachment_count: 0,
  });
  assert.equal(remoteSnapshotHash(summaries), remoteSnapshotHash(summaries.map(item => ({ ...item, title: 'changed but ignored' }))));
  assert.match(checkpointSnapshotHash(checkpoint), /^[a-f0-9]{64}$/);
});

test('unchanged automatic planning emits no HTML report', t => {
  const root = tempRoot(t);
  const checkpoint = emptyCheckpoint();
  checkpoint.completed_conversations.one = { updated_at: 'v1', content_fingerprint: 'f1', content_sha256: 'a' };
  saveCheckpoint(path.join(root, 'state', 'raw', 'checkpoint.json'), checkpoint);
  const fixture = writeFixture(root, [{ conversation_id: 'one', title: 'secret', updated_at: 'v1', content_fingerprint: 'f1' }]);
  const result = runPreflight(root, fixture, ['--silent-if-unchanged']);
  assert.equal(result.status, 'unchanged');
  assert.equal(result.report_created, false);
  assert.equal(fs.existsSync(path.join(root, 'reports', 'latest.html')), false);
  assert.equal(JSON.parse(fs.readFileSync(path.join(root, 'reports', 'monitor-state.json'), 'utf8')).status, 'unchanged');
});

test('changed scan creates a private self-contained automatic execution plan', t => {
  const root = tempRoot(t);
  const fixture = writeFixture(root, [{ conversation_id: 'sensitive-id', title: '<private title>', updated_at: 'v1', content_fingerprint: 'f1' }]);
  const first = runPreflight(root, fixture, ['--silent-if-unchanged']);
  assert.equal(first.status, 'ready_to_execute');
  assert.equal(first.report_created, true);
  const html = fs.readFileSync(first.report_path, 'utf8');
  assert.match(html, /Content-Security-Policy/);
  assert.match(html, /下一步/);
  assert.equal(html.includes('批准执行'), false);
  assert.equal(html.includes('sensitive-id'), false);
  assert.equal(html.includes('private title'), false);
  assert.equal(html.includes('https://'), false);
  assert.equal(fs.existsSync(path.join(root, 'reports', 'pending-plan.json')), false);
});

test('automatic execution is tied to an immutable, unexpired plan', t => {
  const root = tempRoot(t);
  const fixture = writeFixture(root, [{ conversation_id: 'one', updated_at: 'v1', content_fingerprint: 'f1' }]);
  const preflight = runPreflight(root, fixture);
  assert.equal(loadExecutionPlan(preflight.plan_path).plan.plan_id, preflight.plan_id);
  const planPath = preflight.plan_path;
  const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));
  plan.planned_actions.push('tampered');
  fs.writeFileSync(planPath, JSON.stringify(plan), 'utf8');
  assert.throws(() => loadExecutionPlan(planPath), /hash is invalid/);
});

test('plan hashing and failure HTML are deterministic and escaped', () => {
  const plan = {
    schema_version: 1,
    plan_id: 'x<y',
    created_at: 'now',
    expires_at: 'later',
    status: 'no_changes',
    execution_mode: 'automatic',
    snapshot: { remote_count: 0, local_completed_count: 0, new_count: 0, changed_count: 0, unchanged_count: 0, remote_missing_count: 0, failed_conversation_count: 0, failed_attachment_count: 0 },
    planned_actions: ['none'],
  };
  plan.plan_hash = planHash(plan);
  assert.equal(planHash(plan), plan.plan_hash);
  assert.equal(renderPreflightHtml(plan).includes('x<y'), false);
  const failure = renderFailureHtml({ runId: 'x', checkedAt: 'now', error: '<script>alert(1)</script>' });
  assert.equal(failure.includes('<script>alert(1)</script>'), false);
});

test('live raw export refuses to run without an automatic plan before browser access', () => {
  const result = spawnSync(process.execPath, [path.join(scripts, 'run-raw-export.js')], { encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(`${result.stdout}${result.stderr}`, /requires --plan/);
});

test('result report is private, self-contained, and reflects verified final counts', t => {
  const root = tempRoot(t);
  const planId = 'run-1';
  const runDir = path.join(root, 'reports', 'runs', planId);
  const finalDir = path.join(root, 'final', 'Doubao_Backup');
  fs.mkdirSync(runDir, { recursive: true });
  fs.mkdirSync(path.join(finalDir, 'conversations'), { recursive: true });
  fs.writeFileSync(path.join(runDir, 'plan.json'), JSON.stringify({
    plan_id: planId,
    snapshot: { scan_scope: 'recent-page', new_count: 0, changed_count: 1, unchanged_count: 19 },
  }), 'utf8');
  fs.writeFileSync(path.join(finalDir, 'conversations', 'private-id.json'), JSON.stringify({
    derived: { message_ids: ['m1', 'm2'], title: 'private title' },
  }), 'utf8');
  fs.writeFileSync(path.join(finalDir, 'metadata', 'export-report.json'), JSON.stringify({
    attachments_referenced: 3,
  }), 'utf8');
  fs.writeFileSync(path.join(finalDir, 'metadata', 'final-verification.json'), JSON.stringify({
    passed: true,
    verified_at: '2026-08-15T00:00:00.000Z',
    final_conversations: 1,
    manifest_files: 2,
    raw_parse_failures: [], final_parse_failures: [], raw_duplicate_conversation_ids: [],
    duplicate_conversation_ids: [], conversation_hash_mismatches: [], bad_manifest_hashes: [],
    missing_manifest_files: [], unaccounted_attachment_ids: [], zero_byte_files: [],
    unsafe_metadata_keys: [], unsafe_conversation_values: [], failed_conversations: [], failed_attachments: [],
  }), 'utf8');
  execFileSync(process.execPath, [
    path.join(scripts, 'write-result-report.js'), '--root', root, '--plan-id', planId,
    '--discovered', '20', '--saved', '1', '--skipped', '19', '--attachments-saved', '3',
  ], { encoding: 'utf8' });
  const html = fs.readFileSync(path.join(runDir, 'result.html'), 'utf8');
  const result = JSON.parse(fs.readFileSync(path.join(runDir, 'result.json'), 'utf8'));
  assert.match(html, /Content-Security-Policy/);
  assert.equal(html.includes('private title'), false);
  assert.equal(html.includes('private-id'), false);
  assert.equal(html.includes('https://'), false);
  assert.equal(result.final.messages, 2);
  assert.equal(result.execution.saved, 1);
});

test('single automatic runner scans, exports, verifies, publishes, and reports', t => {
  const root = tempRoot(t);
  const fixture = path.join(root, 'auto-fixture.json');
  fs.writeFileSync(fixture, JSON.stringify({ conversations: [{
    summary: { conversation_id: 'auto-one', title: 'private', updated_at: 'v1', content_fingerprint: 'f1' },
    collected_at: '2026-08-15T00:00:00.000Z',
    pages: [{ kind: 'conversation_info', cursor: null, nextCursor: null, response: { conversation: { conversation_id: 'auto-one' } } }],
    metadata: { title: 'private', updatedAt: 'v1', contentFingerprint: 'f1', messageIds: ['m1'], attachments: [], pagination: { stop: true } },
    attachments: [],
  }] }), 'utf8');
  const output = JSON.parse(execFileSync(process.execPath, [
    path.join(scripts, 'run-auto-backup.js'), '--root', root, '--fixture', fixture,
  ], { encoding: 'utf8' }));
  assert.equal(output.status, 'completed');
  assert.equal(output.execution.saved, 1);
  assert.equal(output.final.conversations, 1);
  assert.equal(output.final.messages, 1);
  assert.equal(output.final_verified, true);
  assert.equal(fs.existsSync(output.result_path), true);
  assert.equal(fs.existsSync(path.join(root, 'reports', 'pending-plan.json')), false);
});
