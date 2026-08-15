'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { assertInside, atomicWriteJson, atomicWriteText, ensureDir } = require('./lib/atomic-json');
const { renderFailureHtml } = require('./lib/monitoring');
const { sanitizeDiagnostic } = require('./lib/redaction');

function arg(name, fallback = null) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

function has(name) {
  return process.argv.includes(name);
}

function timestamp(now = new Date()) {
  return now.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
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
    if (age < 6 * 60 * 60 * 1000) throw new Error('Another Doubao automatic backup is active');
    fs.rmSync(file, { force: false });
    return acquireLock(file);
  }
  return () => { if (fs.existsSync(file)) fs.rmSync(file, { force: false }); };
}

function runJson(script, args, options = {}) {
  const result = spawnSync(process.execPath, [script, ...args], {
    cwd: __dirname,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    env: { ...process.env, DOUBAO_PROGRESS: options.progress ? '1' : '0' },
  });
  if (result.stderr && options.progress) process.stderr.write(result.stderr);
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${path.basename(script)} failed with exit code ${result.status}`);
  const output = String(result.stdout || '').trim();
  if (!output) throw new Error(`${path.basename(script)} returned no JSON result`);
  try {
    return JSON.parse(output);
  } catch {
    throw new Error(`${path.basename(script)} returned invalid JSON`);
  }
}

const root = path.resolve(arg('--root', 'D:\\Doubao_Backup'));
const rawDir = path.resolve(arg('--raw', path.join(root, 'state', 'raw')));
const reportRoot = path.resolve(arg('--report-root', path.join(root, 'reports')));
const fixture = arg('--fixture');
const completeListing = has('--complete-listing');
assertInside(root, rawDir, 'Raw state');
assertInside(root, reportRoot, 'Report root');
ensureDir(reportRoot);
const releaseLock = acquireLock(path.join(root, 'tool', 'auto-backup.lock'));
let phase = 'planning';
let activeRunId = `${timestamp()}-auto`;

try {
  const preflightArgs = ['--root', root, '--raw', rawDir, '--report-root', reportRoot, '--silent-if-unchanged'];
  preflightArgs.push(completeListing ? '--complete-listing' : '--recent-only');
  if (fixture) preflightArgs.push('--fixture', path.resolve(fixture));
  const preflight = runJson(path.join(__dirname, 'preflight-backup.js'), preflightArgs);
  if (preflight.status === 'unchanged') {
    console.log(JSON.stringify({
      provider: 'doubao',
      status: 'unchanged',
      checked_at: preflight.checked_at,
      discovered: preflight.remote_count,
      saved: 0,
      skipped: preflight.unchanged_count,
      published: false,
      report_created: false,
    }, null, 2));
    process.exitCode = 0;
  } else {
    if (preflight.status !== 'ready_to_execute' || !preflight.plan_path || !preflight.plan_id) {
      throw new Error(`Automatic planning returned unexpected status ${preflight.status || 'unknown'}`);
    }
    activeRunId = preflight.plan_id;
    phase = 'collecting';
    const exportArgs = ['--raw', rawDir, '--plan', preflight.plan_path, '--page-size', '20'];
    if (fixture) exportArgs.push('--fixture', path.resolve(fixture));
    const exported = runJson(path.join(__dirname, 'run-raw-export.js'), exportArgs, { progress: true });

    phase = 'organizing';
    const candidate = path.join(root, 'working', `candidate-${preflight.plan_id}`);
    assertInside(path.join(root, 'working'), candidate, 'Candidate');
    const organized = runJson(path.join(__dirname, 'organize-backup.js'), ['--raw', rawDir, '--out', candidate]);

    phase = 'verifying candidate';
    const candidateVerification = runJson(path.join(__dirname, 'verify-backup.js'), ['--raw', rawDir, '--final', candidate]);
    if (candidateVerification.passed !== true) throw new Error('Candidate verification did not pass');

    phase = 'publishing';
    runJson(path.join(__dirname, 'publish-backup.js'), ['--candidate', candidate, '--root', root]);
    phase = 'rebuilding state';
    const rebuilt = runJson(path.join(__dirname, 'rebuild-incremental-state.js'), ['--root', root]);
    phase = 'verifying published final';
    const finalVerification = runJson(path.join(__dirname, 'verify-backup.js'), [
      '--raw', rawDir,
      '--final', path.join(root, 'final', 'Doubao_Backup'),
    ]);
    if (finalVerification.passed !== true) throw new Error('Published final verification did not pass');

    phase = 'writing result report';
    const resultReport = runJson(path.join(__dirname, 'write-result-report.js'), ['--root', root, '--plan-id', preflight.plan_id]);
    const pendingPath = path.join(reportRoot, 'pending-plan.json');
    const latestPath = path.join(reportRoot, 'latest.html');
    if (fs.existsSync(pendingPath)) fs.rmSync(pendingPath, { force: false });
    if (fs.existsSync(latestPath)) fs.rmSync(latestPath, { force: false });
    atomicWriteJson(path.join(reportRoot, 'monitor-state.json'), {
      schema_version: 1,
      provider: 'doubao',
      checked_at: new Date().toISOString(),
      status: 'completed',
      plan_id: preflight.plan_id,
      result_path: resultReport.result_path,
      conversations: finalVerification.final_conversations,
      attachment_files: finalVerification.manifest_files,
    });
    console.log(JSON.stringify({
      provider: 'doubao',
      status: 'completed',
      plan_id: preflight.plan_id,
      preflight: {
        discovered: preflight.remote_count,
        new: preflight.new_count,
        changed: preflight.changed_count,
      },
      execution: exported,
      final: resultReport.final,
      candidate_verified: candidateVerification.passed,
      final_verified: finalVerification.passed,
      hardlinks: rebuilt.hardlinks,
      fallback_copies: rebuilt.fallback_copies,
      result_path: resultReport.result_path,
      organized_at: organized.export_report?.organized_at || null,
    }, null, 2));
  }
} catch (error) {
  const checkedAt = new Date().toISOString();
  const safeError = sanitizeDiagnostic(`${phase}: ${error.message || error}`);
  const runDir = path.join(reportRoot, 'runs', activeRunId);
  ensureDir(runDir);
  const failurePath = path.join(runDir, 'failure.html');
  const html = renderFailureHtml({ runId: activeRunId, checkedAt, error: safeError });
  atomicWriteText(failurePath, html);
  atomicWriteText(path.join(reportRoot, 'latest.html'), html);
  atomicWriteJson(path.join(reportRoot, 'monitor-state.json'), {
    schema_version: 1,
    provider: 'doubao',
    checked_at: checkedAt,
    status: 'action_required',
    phase,
    error: safeError,
    report_path: failurePath,
  });
  console.error(JSON.stringify({ provider: 'doubao', status: 'action_required', phase, report_path: failurePath, error: safeError }, null, 2));
  process.exitCode = 1;
} finally {
  releaseLock();
}
