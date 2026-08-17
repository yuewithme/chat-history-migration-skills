'use strict';

const fs = require('fs');
const path = require('path');
const { arg, readArchiveProfile, resolveArchiveRoot } = require('./lib/archive-profile');

const { root: backupRoot } = resolveArchiveRoot('chatgpt');
readArchiveProfile(backupRoot, 'chatgpt', ['final/ChatGPT_Backup', 'state/raw']);
const finalDir = path.resolve(arg('--final', path.join(backupRoot, 'final', 'ChatGPT_Backup')));
const stateDir = path.resolve(arg('--state', path.join(backupRoot, 'state', 'raw')));
const stateParent = path.dirname(stateDir);
const candidate = path.join(stateParent, `raw.candidate-${Date.now()}`);
const rollback = path.join(stateParent, `raw.rollback-${Date.now()}`);

function assertInside(parent, child, label) {
  const relative = path.relative(parent, child);
  if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error(`${label} must be a child of ${parent}: ${child}`);
  }
}

assertInside(backupRoot, finalDir, 'Final backup');
assertInside(backupRoot, stateDir, 'Incremental state');

const ensureDir = p => fs.mkdirSync(p, { recursive: true });
const readJson = p => JSON.parse(fs.readFileSync(p, 'utf8'));
const readJsonIf = (p, fallback) => fs.existsSync(p) ? readJson(p) : fallback;
const writeJson = (p, value) => {
  ensureDir(path.dirname(p));
  fs.writeFileSync(p, JSON.stringify(value, null, 2) + '\n', 'utf8');
};

function sanitizeProjectFolder(name) {
  if (!name) return 'untitled_project';
  return String(name)
    .replace(/[<>:"/\\|?*]/g, '_')
    .replace(/\.{2,}/g, '_')
    .replace(/\s+/g, '_')
    .trim()
    .substring(0, 50)
    .replace(/^\.+$/, 'untitled_project');
}

function jsonFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  const result = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const item = path.join(dir, entry.name);
    if (entry.isDirectory()) result.push(...jsonFiles(item));
    else if (entry.name.endsWith('.json')) result.push(item);
  }
  return result;
}

function indexEntry(conversation) {
  return {
    id: conversation.id || conversation.conversation_id,
    title: conversation.title || null,
    create_time: conversation.create_time || null,
    update_time: conversation.update_time || null,
    is_archived: !!conversation.is_archived,
    gizmo_id: conversation.gizmo_id || null,
  };
}

function linkFile(source, target) {
  ensureDir(path.dirname(target));
  try {
    fs.linkSync(source, target);
    return 'hardlink';
  } catch (error) {
    if (!['EXDEV', 'ENOTSUP', 'EPERM', 'EACCES'].includes(error.code)) throw error;
    fs.copyFileSync(source, target);
    return 'copy';
  }
}

if (!fs.existsSync(finalDir)) throw new Error(`Published backup not found: ${finalDir}`);
for (const required of [
  path.join(finalDir, 'metadata', 'conversation-index.json'),
  path.join(finalDir, 'attachments', 'manifest.json'),
  path.join(finalDir, 'metadata', 'final-verification.json'),
]) {
  if (!fs.existsSync(required)) throw new Error(`Published backup is incomplete: ${required}`);
}
const verification = readJson(path.join(finalDir, 'metadata', 'final-verification.json'));
if (verification.passed !== true) throw new Error('Published backup verification is not passed:true');

ensureDir(stateParent);
ensureDir(candidate);
let hardlinks = 0;
let copies = 0;
const link = (source, target) => {
  const mode = linkFile(source, target);
  if (mode === 'hardlink') hardlinks++;
  else copies++;
};

const finalIndex = readJson(path.join(finalDir, 'metadata', 'conversation-index.json'));
const finalMetaById = new Map(finalIndex.map(item => [item.conversation_id, item]));
const projectIndex = readJsonIf(path.join(finalDir, 'metadata', 'project-index.json'), []);
const projectById = new Map(projectIndex.map(project => [project.id, project]));
const regularEntries = [];
const projectEntries = new Map();
const allConversationIds = [];

for (const source of jsonFiles(path.join(finalDir, 'conversations'))) {
  const conversation = readJson(source);
  const entry = indexEntry(conversation);
  if (!entry.id) throw new Error(`Conversation has no ID: ${source}`);
  allConversationIds.push(entry.id);

  const meta = finalMetaById.get(entry.id) || {};
  const projectId = meta.project_id || null;
  if (projectId) {
    const project = projectById.get(projectId) || { id: projectId, name: meta.project_name || 'Untitled Project' };
    const folder = sanitizeProjectFolder(project.name);
    link(source, path.join(candidate, 'projects', folder, 'json', path.basename(source)));
    if (!projectEntries.has(projectId)) projectEntries.set(projectId, { project, folder, entries: [], ids: [] });
    projectEntries.get(projectId).entries.push(entry);
    projectEntries.get(projectId).ids.push(entry.id);
  } else {
    regularEntries.push(entry);
    link(source, path.join(candidate, 'json', path.basename(source)));
  }
}

writeJson(path.join(candidate, 'conversation-index.json'), regularEntries);
writeJson(path.join(candidate, 'projects', 'project-index.json'), projectIndex);
for (const value of projectEntries.values()) {
  writeJson(path.join(candidate, 'projects', value.folder, 'conversation-index.json'), value.entries);
}

const manifest = readJson(path.join(finalDir, 'attachments', 'manifest.json'));
const downloadedFileIds = new Set();
for (const item of manifest.files || []) {
  const source = path.join(finalDir, item.stored_path);
  if (!fs.existsSync(source)) throw new Error(`Manifest file is missing: ${source}`);
  const extension = path.extname(source);
  for (const fileId of item.file_ids || []) {
    downloadedFileIds.add(fileId);
    link(source, path.join(candidate, 'files', `${fileId}${extension}`));
  }
}
const report = readJsonIf(path.join(finalDir, 'metadata', 'export-report.json'), {});
for (const item of report.excluded_generated_files || []) downloadedFileIds.add(item.file_id);

const projects = {};
for (const project of projectIndex) {
  const value = projectEntries.get(project.id);
  projects[project.id] = {
    name: project.name,
    indexingComplete: false,
    lastCursor: null,
    downloadedIds: value ? value.ids : [],
  };
}
writeJson(path.join(candidate, '.export-progress.json'), {
  indexingComplete: false,
  lastOffset: 0,
  archivedIndexingComplete: false,
  lastArchivedOffset: 0,
  downloadedIds: allConversationIds,
  projectsIndexingComplete: false,
  projectsLastCursor: null,
  projects,
  downloadedFileIds: [...downloadedFileIds],
  failedFileIds: {},
});

let oldMoved = false;
try {
  if (fs.existsSync(stateDir)) {
    fs.renameSync(stateDir, rollback);
    oldMoved = true;
  }
  fs.renameSync(candidate, stateDir);
  if (oldMoved) fs.rmSync(rollback, { recursive: true, force: false });
} catch (error) {
  if (!fs.existsSync(stateDir) && oldMoved && fs.existsSync(rollback)) fs.renameSync(rollback, stateDir);
  throw error;
} finally {
  if (fs.existsSync(candidate)) fs.rmSync(candidate, { recursive: true, force: false });
}

console.log(JSON.stringify({
  state: stateDir,
  conversations: allConversationIds.length,
  regular_conversations: regularEntries.length,
  project_conversations: allConversationIds.length - regularEntries.length,
  projects: projectIndex.length,
  downloaded_file_ids: downloadedFileIds.size,
  hardlinks,
  fallback_copies: copies,
}, null, 2));
