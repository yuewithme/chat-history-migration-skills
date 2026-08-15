'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { atomicWriteJson, atomicWriteText, ensureDir } = require('./atomic-json');

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonicalize(value[key])]));
}

function sha256Canonical(value) {
  return crypto.createHash('sha256').update(JSON.stringify(canonicalize(value))).digest('hex');
}

function normalizeSummary(summary) {
  if (typeof summary?.conversation_id !== 'string' || !summary.conversation_id) {
    throw new Error('Conversation summary has no conversation_id');
  }
  return {
    conversation_id: summary.conversation_id,
    updated_at: summary.updated_at ?? null,
    content_fingerprint: summary.content_fingerprint ?? null,
  };
}

function normalizeSummaries(summaries) {
  if (!Array.isArray(summaries)) throw new Error('Conversation summaries must be an array');
  return summaries.map(normalizeSummary).sort((a, b) => a.conversation_id.localeCompare(b.conversation_id));
}

function remoteSnapshotHash(summaries) {
  return sha256Canonical(normalizeSummaries(summaries));
}

function checkpointSnapshotHash(checkpoint) {
  const completed = Object.entries(checkpoint?.completed_conversations || {})
    .map(([conversation_id, item]) => ({
      conversation_id,
      updated_at: item?.updated_at ?? null,
      content_fingerprint: item?.content_fingerprint ?? null,
      content_sha256: item?.content_sha256 ?? null,
    }))
    .sort((a, b) => a.conversation_id.localeCompare(b.conversation_id));
  return sha256Canonical({
    completed,
    failed_conversations: checkpoint?.failed_conversations || [],
    failed_attachments: checkpoint?.failed_attachments || [],
  });
}

function buildPreflightDiff(summaries, checkpoint, options = {}) {
  const normalized = normalizeSummaries(summaries);
  const completed = checkpoint?.completed_conversations || {};
  const remoteIds = new Set(normalized.map(item => item.conversation_id));
  let newCount = 0;
  let changedCount = 0;
  let unchangedCount = 0;

  for (const summary of normalized) {
    const existing = completed[summary.conversation_id];
    if (!existing) {
      newCount++;
    } else if (
      (summary.updated_at != null && existing.updated_at !== summary.updated_at)
      || (summary.content_fingerprint != null && existing.content_fingerprint !== summary.content_fingerprint)
    ) {
      changedCount++;
    } else {
      unchangedCount++;
    }
  }

  const remoteMissingCount = options.completeListing === false
    ? 0
    : Object.keys(completed).filter(id => !remoteIds.has(id)).length;
  return {
    remote_count: normalized.length,
    local_completed_count: Object.keys(completed).length,
    new_count: newCount,
    changed_count: changedCount,
    unchanged_count: unchangedCount,
    remote_missing_count: remoteMissingCount,
    failed_conversation_count: (checkpoint?.failed_conversations || []).length,
    failed_attachment_count: (checkpoint?.failed_attachments || []).length,
  };
}

function planHash(plan) {
  const copy = structuredClone(plan);
  delete copy.plan_hash;
  return sha256Canonical(copy);
}

function loadJson(file, fallback = null) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, character => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character]);
}

function metric(label, value, tone = '') {
  return `<div class="metric ${tone}"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`;
}

function renderPreflightHtml(plan) {
  const snapshot = plan.snapshot;
  const automatic = plan.status === 'ready_to_execute';
  const statusLabel = automatic ? '自动执行' : '无需执行';
  const statusTone = automatic ? 'waiting' : 'ok';
  const actions = plan.planned_actions.map(item => `<li>${escapeHtml(item)}</li>`).join('');
  const execution = automatic
    ? '<section class="automatic"><h2>下一步</h2><p>继续备份，校验通过后发布。</p></section>'
    : '<section><h2>结论</h2><p>未发现变化。</p></section>';
  return `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
<title>豆包自动备份计划报告</title><style>
:root{color-scheme:light dark;--bg:#f5f7fb;--card:#fff;--ink:#172033;--muted:#667085;--line:#e4e7ec;--blue:#2563eb;--amber:#b54708;--green:#027a48}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif}.wrap{max-width:980px;margin:36px auto;padding:0 18px}.hero,section{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:24px;margin-bottom:16px;box-shadow:0 8px 26px rgba(16,24,40,.05)}h1,h2{margin:0 0 12px}.meta{color:var(--muted)}.badge{display:inline-block;padding:5px 10px;border-radius:999px;font-weight:700}.badge.waiting{color:var(--amber);background:#fffaeb}.badge.ok{color:var(--green);background:#ecfdf3}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px}.metric{border:1px solid var(--line);border-radius:12px;padding:14px}.metric span{display:block;color:var(--muted)}.metric strong{font-size:24px}.metric.alert strong{color:var(--amber)}code{display:block;padding:12px;border-radius:10px;background:#101828;color:#fff;overflow-wrap:anywhere}.automatic{border-color:#fdb022}ul{padding-left:22px}.foot{color:var(--muted);font-size:13px}@media(prefers-color-scheme:dark){:root{--bg:#101828;--card:#182230;--ink:#f2f4f7;--muted:#98a2b3;--line:#344054}}</style></head>
<body><main class="wrap"><div class="hero"><span class="badge ${statusTone}">${statusLabel}</span><h1>豆包本地自动备份计划报告</h1><div class="meta">计划编号：${escapeHtml(plan.plan_id)}<br>扫描时间：${escapeHtml(plan.created_at)}<br>扫描范围：${escapeHtml(snapshot.scan_scope === 'recent-page' ? '最近会话页（低成本增量发现）' : '完整会话列表')}<br>有效期至：${escapeHtml(plan.expires_at)}</div></div>
<section><h2>扫描摘要</h2><div class="grid">
${metric('线上会话', snapshot.remote_count)}${metric('本地已备份', snapshot.local_completed_count)}${metric('新增', snapshot.new_count, snapshot.new_count ? 'alert' : '')}${metric('发生变化', snapshot.changed_count, snapshot.changed_count ? 'alert' : '')}${metric('未变化', snapshot.unchanged_count)}${metric('线上暂时缺失', snapshot.remote_missing_count, snapshot.remote_missing_count ? 'alert' : '')}${metric('会话失败待处理', snapshot.failed_conversation_count, snapshot.failed_conversation_count ? 'alert' : '')}${metric('附件失败待处理', snapshot.failed_attachment_count, snapshot.failed_attachment_count ? 'alert' : '')}
</div></section><section><h2>本轮计划</h2><ul>${actions}</ul></section>${execution}
<p class="foot">计划哈希：${escapeHtml(plan.plan_hash)}</p></main></body></html>\n`;
}

function renderFailureHtml({ runId, checkedAt, error }) {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'"><title>豆包备份失败</title><style>body{max-width:760px;margin:40px auto;padding:0 18px;font:15px/1.7 system-ui,"Microsoft YaHei";color:#172033;background:#f5f7fb}main{background:#fff;border:1px solid #fdb022;border-radius:16px;padding:24px}code{display:block;background:#101828;color:#fff;padding:12px;border-radius:8px;overflow-wrap:anywhere}</style></head><body><main><h1>豆包备份失败</h1><p>进度和原存档已保留。处理错误后重试。</p><p>编号：${escapeHtml(runId)}<br>时间：${escapeHtml(checkedAt)}</p><code>${escapeHtml(error)}</code></main></body></html>\n`;
}

function writeReportFiles(reportRoot, runId, plan, html) {
  const runDir = path.join(reportRoot, 'runs', runId);
  ensureDir(runDir);
  if (plan) atomicWriteJson(path.join(runDir, 'plan.json'), plan);
  atomicWriteText(path.join(runDir, 'preflight.html'), html);
  atomicWriteText(path.join(reportRoot, 'latest.html'), html);
  return { run_dir: runDir, report_path: path.join(runDir, 'preflight.html') };
}

function loadExecutionPlan(inputPath) {
  const planPath = path.resolve(inputPath);
  const plan = loadJson(planPath);
  if (!plan || plan.schema_version !== 1 || plan.provider !== 'doubao') throw new Error('Execution plan is missing or invalid');
  if (plan.plan_hash !== planHash(plan)) throw new Error('Execution plan hash is invalid');
  if (plan.status !== 'ready_to_execute' || plan.execution_mode !== 'automatic') throw new Error('Plan is not ready for automatic execution');
  if (Date.parse(plan.expires_at) <= Date.now()) throw new Error('Execution plan has expired; run automatic backup again');
  return { plan, planPath };
}

module.exports = {
  buildPreflightDiff,
  checkpointSnapshotHash,
  loadExecutionPlan,
  loadJson,
  planHash,
  remoteSnapshotHash,
  renderFailureHtml,
  renderPreflightHtml,
  sha256Canonical,
  writeReportFiles,
};
