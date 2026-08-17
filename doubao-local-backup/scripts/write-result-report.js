'use strict';

const fs = require('fs');
const path = require('path');
const { atomicWriteJson, atomicWriteText } = require('./lib/atomic-json');
const { readArchiveProfile, resolveArchiveRoot } = require('./lib/archive-profile');

function arg(name, fallback = null) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function numericArg(name, fallback) {
  const value = arg(name);
  if (value == null) return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) throw new Error(`${name} must be a non-negative integer`);
  return parsed;
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, character => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character]);
}

function metric(label, value) {
  return `<div class="metric"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`;
}

function jsonFiles(directory) {
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const item = path.join(directory, entry.name);
    if (entry.isDirectory()) return jsonFiles(item);
    return entry.name.toLowerCase().endsWith('.json') ? [item] : [];
  });
}

const { root } = resolveArchiveRoot('doubao');
readArchiveProfile(root, 'doubao', ['final/Doubao_Backup', 'state/raw']);
const planId = arg('--plan-id');
if (!planId || !/^[A-Za-z0-9_-]+$/.test(planId)) throw new Error('Usage: node write-result-report.js --plan-id <plan-id> [execution counts]');

const runDir = path.join(root, 'reports', 'runs', planId);
const plan = readJson(path.join(runDir, 'plan.json'));
if (plan.plan_id !== planId) throw new Error('Plan ID does not match its run directory');

const finalDir = path.join(root, 'final', 'Doubao_Backup');
const metadataDir = path.join(finalDir, 'metadata');
const verification = readJson(path.join(metadataDir, 'final-verification.json'));
const exported = readJson(path.join(metadataDir, 'export-report.json'));
if (verification.passed !== true) throw new Error('Published final verification is not passed:true');

const rawExportResultPath = path.join(runDir, 'raw-export-result.json');
const storedExportResult = fs.existsSync(rawExportResultPath)
  ? readJson(rawExportResultPath)
  : {};
const execution = {
  discovered: numericArg('--discovered', storedExportResult.discovered ?? 0),
  selected: numericArg('--selected', storedExportResult.selected ?? 0),
  saved: numericArg('--saved', storedExportResult.saved ?? 0),
  skipped: numericArg('--skipped', storedExportResult.skipped ?? 0),
  failed: numericArg('--failed', storedExportResult.failed ?? 0),
  attachments_saved: numericArg('--attachments-saved', storedExportResult.attachments_saved ?? 0),
  attachments_failed: numericArg('--attachments-failed', storedExportResult.attachments_failed ?? 0),
};
if (!fs.existsSync(rawExportResultPath)) {
  atomicWriteJson(rawExportResultPath, {
    provider: 'doubao',
    mode: 'live',
    plan_id: planId,
    ...execution,
    errors: [],
    recorded_from_verified_result: true,
  });
}

let messageCount = 0;
for (const file of jsonFiles(path.join(finalDir, 'conversations'))) {
  const envelope = readJson(file);
  messageCount += Array.isArray(envelope?.derived?.message_ids) ? envelope.derived.message_ids.length : 0;
}

const result = {
  schema_version: 1,
  provider: 'doubao',
  plan_id: planId,
  completed_at: new Date().toISOString(),
  status: 'passed',
  scan_scope: plan.snapshot?.scan_scope || null,
  preflight: {
    new_count: plan.snapshot?.new_count ?? 0,
    changed_count: plan.snapshot?.changed_count ?? 0,
    unchanged_count: plan.snapshot?.unchanged_count ?? 0,
  },
  execution,
  final: {
    conversations: verification.final_conversations,
    messages: messageCount,
    attachment_references: exported.attachments_referenced,
    attachment_files: verification.manifest_files,
  },
  verification: {
    passed: true,
    verified_at: verification.verified_at,
    parse_failures: verification.raw_parse_failures.length + verification.final_parse_failures.length,
    duplicate_conversations: verification.raw_duplicate_conversation_ids.length + verification.duplicate_conversation_ids.length,
    hash_mismatches: verification.conversation_hash_mismatches.length + verification.bad_manifest_hashes.length,
    missing_files: verification.missing_manifest_files.length + verification.unaccounted_attachment_ids.length,
    zero_byte_files: verification.zero_byte_files.length,
    unsafe_items: verification.unsafe_metadata_keys.length + verification.unsafe_conversation_values.length,
    failed_conversations: verification.failed_conversations.length,
    failed_attachments: verification.failed_attachments.length,
  },
};

const html = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<title>豆包本地备份执行结果</title><style>
:root{color-scheme:light dark;--bg:#f5f7fb;--card:#fff;--ink:#172033;--muted:#667085;--line:#e4e7ec;--green:#027a48}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif}.wrap{max-width:980px;margin:36px auto;padding:0 18px}.hero,section{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:24px;margin-bottom:16px;box-shadow:0 8px 26px rgba(16,24,40,.05)}h1,h2{margin:0 0 12px}.meta,.foot{color:var(--muted)}.badge{display:inline-block;padding:5px 10px;border-radius:999px;font-weight:700;color:var(--green);background:#ecfdf3}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px}.metric{border:1px solid var(--line);border-radius:12px;padding:14px}.metric span{display:block;color:var(--muted)}.metric strong{font-size:24px}ul{padding-left:22px}@media(prefers-color-scheme:dark){:root{--bg:#101828;--card:#182230;--ink:#f2f4f7;--muted:#98a2b3;--line:#344054}}</style></head>
<body><main class="wrap"><div class="hero"><span class="badge">执行成功 · 完整性通过</span><h1>豆包本地备份执行结果</h1><div class="meta">计划编号：${escapeHtml(planId)}<br>完成时间：${escapeHtml(result.completed_at)}<br>验证时间：${escapeHtml(result.verification.verified_at)}</div></div>
<section><h2>本轮执行</h2><div class="grid">${metric('扫描会话', execution.discovered)}${metric('变化会话已保存', execution.saved)}${metric('未变化已跳过', execution.skipped)}${metric('采集失败', execution.failed)}${metric('本轮附件处理', execution.attachments_saved)}${metric('附件失败', execution.attachments_failed)}</div></section>
<section><h2>当前完整存档</h2><div class="grid">${metric('会话', result.final.conversations)}${metric('唯一消息', result.final.messages)}${metric('附件引用', result.final.attachment_references)}${metric('物理附件文件', result.final.attachment_files)}</div></section>
<section><h2>完整性复验</h2><div class="grid">${metric('解析失败', result.verification.parse_failures)}${metric('重复会话', result.verification.duplicate_conversations)}${metric('哈希不一致', result.verification.hash_mismatches)}${metric('缺失文件', result.verification.missing_files)}${metric('零字节文件', result.verification.zero_byte_files)}${metric('敏感项', result.verification.unsafe_items)}</div></section>
<p class="foot">${escapeHtml(finalDir)}</p></main></body></html>\n`;

atomicWriteJson(path.join(runDir, 'result.json'), result);
atomicWriteText(path.join(runDir, 'result.html'), html);
atomicWriteText(path.join(root, 'reports', 'latest-result.html'), html);
console.log(JSON.stringify({
  passed: true,
  result_path: path.join(runDir, 'result.html'),
  result_json: path.join(runDir, 'result.json'),
  final: result.final,
}, null, 2));
