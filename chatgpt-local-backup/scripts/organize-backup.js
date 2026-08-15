'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

function arg(name, position, fallback = null) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : (process.argv[position] || fallback);
}
const rawDir = path.resolve(arg('--raw', 2) || '');
const finalDir = path.resolve(arg('--out', 3) || '');
const toolRoot = path.resolve(arg('--tool', 4, 'D:\\ChatGPT_Backup\\tool\\export-chatgpt'));
if (!rawDir || !finalDir) throw new Error('Usage: node organize-backup.js --raw <raw-dir> --out <candidate-dir> [--tool <tool-dir>]');

const ensureDir = p => fs.mkdirSync(p, { recursive: true });
const writeJson = (p, v) => fs.writeFileSync(p, JSON.stringify(v, null, 2) + '\n', 'utf8');
const sha256 = p => crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
function safeName(value, fallback = 'untitled') {
  return (String(value || fallback).replace(/[<>:"/\\|?*\x00-\x1F]/g, '_').replace(/\.{2,}/g, '_')
    .replace(/\s+/g, '_').replace(/[. ]+$/g, '').slice(0, 100) || fallback);
}
function datePrefix(value) {
  if (value == null) return 'unknown';
  const d = typeof value === 'number' ? new Date(value * 1000) : new Date(value);
  return Number.isNaN(d.getTime()) ? 'unknown' : d.toISOString().slice(0, 10);
}
function mimeFor(ext) {
  return ({ '.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg','.webp':'image/webp','.gif':'image/gif',
    '.pdf':'application/pdf','.m4a':'audio/mp4','.webm':'audio/webm','.mp3':'audio/mpeg','.wav':'audio/wav',
    '.docx':'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    '.pptx':'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    '.xlsx':'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','.csv':'text/csv','.txt':'text/plain',
    '.zip':'application/zip' })[ext.toLowerCase()] || null;
}
function walk(value, visit) {
  if (!value || typeof value !== 'object') return;
  visit(value);
  for (const child of Object.values(value)) if (child && typeof child === 'object') walk(child, visit);
}
function assetRefs(conversation) {
  const refs = new Map();
  walk(conversation, obj => {
    if (typeof obj.asset_pointer === 'string' && /^(sediment|file-service):\/\/file_/.test(obj.asset_pointer)) {
      const id = obj.asset_pointer.replace(/^(sediment|file-service):\/\//, '');
      refs.set(id, { file_id:id, kind:obj.content_type === 'image_asset_pointer' ? 'image' : 'attachment',
        mime_type:obj.mime_type || null, generated:!!(obj.metadata?.dalle || obj.metadata?.generation), original_name:null });
    }
    if (typeof obj.dictation_asset_pointer === 'string' && /^(sediment|file-service):\/\/file_/.test(obj.dictation_asset_pointer)) {
      const id = obj.dictation_asset_pointer.replace(/^(sediment|file-service):\/\//, '');
      refs.set(id, { file_id:id, kind:'dictation', mime_type:obj.dictation_asset_format === 'm4a' ? 'audio/mp4' : null,
        generated:false, original_name:null });
    }
  });
  return [...refs.values()];
}
function readJsonIf(p, fallback) {
  if (!fs.existsSync(p)) return fallback;
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return fallback; }
}
function findOne(assetDirs, fileId) {
  const matches = [];
  for (const dir of assetDirs) {
    if (!fs.existsSync(dir)) continue;
    for (const name of fs.readdirSync(dir)) if (name === fileId || name.startsWith(`${fileId}.`)) matches.push(path.join(dir, name));
  }
  const unique = [...new Set(matches.map(p => path.resolve(p)))];
  return unique.length === 1 ? unique[0] : null;
}
function clearManaged(dir) {
  if (!fs.existsSync(dir)) return;
  for (const entry of fs.readdirSync(dir, { withFileTypes:true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) fs.rmSync(p, { recursive:true, force:false }); else fs.unlinkSync(p);
  }
}

const conversationOut = path.join(finalDir, 'conversations', 'regular');
const projectsOut = path.join(finalDir, 'conversations', 'projects');
const attachmentOut = path.join(finalDir, 'attachments', 'files');
const metadataOut = path.join(finalDir, 'metadata');
for (const p of [conversationOut, projectsOut, attachmentOut, metadataOut]) ensureDir(p);
for (const p of [conversationOut, projectsOut, attachmentOut]) clearManaged(p);

const rawProjects = readJsonIf(path.join(rawDir, 'projects', 'project-index.json'), []);
const projectByFolder = new Map();
for (const project of rawProjects) projectByFolder.set(safeName(project.name).slice(0, 50), project);
const sources = [];
const regularJson = path.join(rawDir, 'json');
const regularFiles = path.join(rawDir, 'files');
if (fs.existsSync(regularJson)) sources.push({ jsonDir:regularJson, filesDir:regularFiles, project:null });
const rawProjectsDir = path.join(rawDir, 'projects');
if (fs.existsSync(rawProjectsDir)) {
  for (const entry of fs.readdirSync(rawProjectsDir, { withFileTypes:true })) {
    if (!entry.isDirectory()) continue;
    const project = projectByFolder.get(entry.name) || rawProjects.find(p => safeName(p.name).slice(0,50) === entry.name)
      || { id:null, name:entry.name, files:[] };
    const jsonDir = path.join(rawProjectsDir, entry.name, 'json');
    if (fs.existsSync(jsonDir)) sources.push({ jsonDir, filesDir:path.join(rawProjectsDir, entry.name, 'files'), project });
  }
}
const assetDirs = [...new Set(sources.map(s => s.filesDir).concat(regularFiles))];

const conversationIndex = [];
const refsById = new Map();
const parseFailures = [];
const seenIds = new Set();
const duplicateIds = [];
let regularCount = 0;
let projectConversationCount = 0;
function mergeRef(ref, origin) {
  if (!refsById.has(ref.file_id)) refsById.set(ref.file_id, { ...ref, referenced_by:[] });
  const item = refsById.get(ref.file_id);
  item.generated ||= ref.generated;
  item.mime_type ||= ref.mime_type;
  item.original_name ||= ref.original_name;
  if (!item.referenced_by.some(x => x.conversation_id === origin.conversation_id && x.project_id === origin.project_id)) item.referenced_by.push(origin);
}

for (const source of sources) {
  const project = source.project;
  let destination = conversationOut;
  if (project) {
    const projectFolder = `${safeName(project.name)}__${safeName(project.id || 'unknown-project')}`;
    destination = path.join(projectsOut, projectFolder);
    ensureDir(destination);
  }
  for (const name of fs.readdirSync(source.jsonDir).filter(n => n.endsWith('.json')).sort()) {
    const sourcePath = path.join(source.jsonDir, name);
    let conversation;
    try { conversation = JSON.parse(fs.readFileSync(sourcePath, 'utf8')); }
    catch (error) { parseFailures.push({ file:path.relative(rawDir,sourcePath), error:error.message }); continue; }
    const id = conversation.id || conversation.conversation_id;
    if (!id) { parseFailures.push({ file:path.relative(rawDir,sourcePath), error:'missing conversation ID' }); continue; }
    if (seenIds.has(id)) duplicateIds.push(id);
    seenIds.add(id);
    const target = path.join(destination, `${datePrefix(conversation.create_time || conversation.update_time)}__${safeName(conversation.title)}__${id}.json`);
    fs.copyFileSync(sourcePath, target);
    const refs = assetRefs(conversation);
    const projectId = project?.id || conversation.gizmo_id || null;
    const projectName = project?.name || null;
    conversationIndex.push({ conversation_id:id, title:conversation.title || null, create_time:conversation.create_time || null,
      update_time:conversation.update_time || null, archived:!!conversation.is_archived, project_id:projectId, project_name:projectName,
      stored_path:path.relative(finalDir,target).replace(/\\/g,'/'), attachment_file_ids:refs.map(r => r.file_id) });
    const origin = { conversation_id:id, conversation_title:conversation.title || null, project_id:projectId, project_name:projectName };
    for (const ref of refs) mergeRef(ref, origin);
    if (project) projectConversationCount++; else regularCount++;
  }
}

for (const project of rawProjects) {
  for (const file of project.files || []) {
    const id = file.file_id || file.id;
    if (!id) continue;
    mergeRef({ file_id:id, kind:'project-file', mime_type:file.type || null, generated:false, original_name:file.name || null },
      { conversation_id:null, conversation_title:null, project_id:project.id || null, project_name:project.name || null });
  }
}

const manifestByHash = new Map();
const failedFiles = [];
const excludedGenerated = [];
let includedBefore = 0;
for (const ref of refsById.values()) {
  const sourcePath = findOne(assetDirs, ref.file_id);
  if (ref.generated) {
    excludedGenerated.push({ file_id:ref.file_id, reason:'DALL-E/image-generation metadata present',
      size_bytes:sourcePath ? fs.statSync(sourcePath).size : null });
    continue;
  }
  if (!sourcePath) { failedFiles.push({ file_id:ref.file_id, reason:'referenced file missing or ambiguous in raw export' }); continue; }
  const stat = fs.statSync(sourcePath);
  includedBefore++;
  const digest = sha256(sourcePath);
  const ext = path.extname(sourcePath).toLowerCase();
  if (!manifestByHash.has(digest)) {
    const stored = path.join(attachmentOut, `${digest.slice(0,16)}__${ref.file_id}${ext}`);
    fs.copyFileSync(sourcePath, stored);
    manifestByHash.set(digest, { sha256:digest, stored_path:path.relative(finalDir,stored).replace(/\\/g,'/'), original_names:[],
      file_ids:[], size_bytes:stat.size, mime_type:ref.mime_type || mimeFor(ext), download_time:stat.mtime.toISOString(), referenced_by:[] });
  }
  const item = manifestByHash.get(digest);
  if (!item.file_ids.includes(ref.file_id)) item.file_ids.push(ref.file_id);
  if (ref.original_name && !item.original_names.includes(ref.original_name)) item.original_names.push(ref.original_name);
  for (const origin of ref.referenced_by) if (!item.referenced_by.some(x => x.conversation_id === origin.conversation_id && x.project_id === origin.project_id)) item.referenced_by.push(origin);
}

const manifest = { files:[...manifestByHash.values()] };
writeJson(path.join(finalDir,'attachments','manifest.json'), manifest);
writeJson(path.join(metadataOut,'conversation-index.json'), conversationIndex);
writeJson(path.join(metadataOut,'project-index.json'), rawProjects);
const bytesBefore = [...refsById.values()].reduce((sum,r) => { if (r.generated) return sum; const p=findOne(assetDirs,r.file_id); return sum+(p?fs.statSync(p).size:0); },0);
const bytesAfter = manifest.files.reduce((sum,f) => sum+f.size_bytes,0);
const dedupReport = { referenced_unique_file_ids:refsById.size, included_before_dedup:includedBefore, included_after_dedup:manifest.files.length,
  bytes_before_dedup:bytesBefore, bytes_after_dedup:bytesAfter, bytes_saved_by_dedup:bytesBefore-bytesAfter, excluded_generated_files:excludedGenerated };
writeJson(path.join(metadataOut,'dedup-report.json'), dedupReport);
let commit = null;
try { commit=execFileSync('git',['-C',toolRoot,'rev-parse','HEAD'],{encoding:'utf8'}).trim(); } catch {}
const exportReport = { export_time:new Date().toISOString(), tool:'brianjlacy/export-chatgpt', tool_commit:commit, format:'json',
  regular_conversations:regularCount, project_conversations:projectConversationCount, projects:rawProjects.length,
  attachments_before_dedup:includedBefore, attachments_after_dedup:manifest.files.length, attachment_size_before:bytesBefore,
  attachment_size_after:bytesAfter, excluded_generated_files:excludedGenerated, failed_conversations:parseFailures,
  duplicate_conversation_ids:duplicateIds, failed_files:failedFiles, warnings:[] };
if (excludedGenerated.length) exportReport.warnings.push(`${excludedGenerated.length} generated image(s) excluded by policy`);
if (parseFailures.length) exportReport.warnings.push(`${parseFailures.length} conversation JSON file(s) failed to parse`);
if (failedFiles.length) exportReport.warnings.push(`${failedFiles.length} referenced file(s) missing or ambiguous`);
writeJson(path.join(metadataOut,'export-report.json'), exportReport);
writeJson(path.join(metadataOut,'verification-report.json'), { json_files:conversationIndex.length+parseFailures.length, parsed_json_files:conversationIndex.length,
  duplicate_conversation_ids:duplicateIds, manifest_files:manifest.files.length,
  missing_manifest_paths:manifest.files.filter(f=>!fs.existsSync(path.join(finalDir,f.stored_path))).map(f=>f.stored_path), failed_files:failedFiles });
fs.writeFileSync(path.join(finalDir,'README.txt'), [
  'ChatGPT local backup', '', 'conversations/regular/  Raw active and archived Conversation JSON.',
  'conversations/projects/ Raw Project Conversation JSON grouped by Project.',
  'attachments/files/      Original retained assets deduplicated by SHA-256.',
  'attachments/manifest.json  Hash, file ID, storage path, and Conversation/Project relationships.',
  'metadata/                Indexes and export, deduplication, and verification reports.', '',
  'Chat bodies are permanently stored only as JSON. No Markdown, HTML, PDF, JSONL, or ZIP copies were generated.',
  'Images explicitly identified as DALL-E/image generation are excluded and recorded in metadata/export-report.json.',
  'No authentication token is stored in this directory.', '' ].join('\r\n'),'utf8');
console.log(JSON.stringify({ exportReport, dedupReport },null,2));
