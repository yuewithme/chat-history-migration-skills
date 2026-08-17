'use strict';

const fs = require('fs');
const path = require('path');

const SCHEMA = 'chat-history-archive-profile-v1';
const LAYOUT_VERSION = 2;
const PROFILE_PATHS = Object.freeze({
  chat_json: 'final/Doubao_Backup/conversations',
  original_files: 'final/Doubao_Backup/attachments/files',
  archive_metadata: 'final/Doubao_Backup/metadata',
  document_markdown: 'documents/markdown',
  document_json: 'documents/json',
  document_indexes: 'documents/indexes',
  state: 'state/raw',
  working: 'working',
  reports: 'reports',
  logs: 'logs',
  tool: 'tool',
});
const PROFILE_DIRECTORIES = Object.freeze([
  'working', 'final', 'logs', 'tool', 'reports', 'state',
  PROFILE_PATHS.document_markdown,
  PROFILE_PATHS.document_json,
  PROFILE_PATHS.document_indexes,
]);

function arg(name, fallback = null, argv = process.argv) {
  const index = argv.indexOf(name);
  return index >= 0 ? argv[index + 1] : fallback;
}

function has(name, argv = process.argv) {
  return argv.includes(name);
}

function normalizeProfileId(value) {
  const normalized = String(value || '').trim().toLowerCase();
  if (!/^[a-z0-9][a-z0-9._-]{0,63}$/.test(normalized)) {
    throw new Error('Profile ID must use 1-64 lowercase letters, digits, dots, underscores, or hyphens');
  }
  return normalized;
}

function validateProfilePaths(paths) {
  if (!paths || typeof paths !== 'object' || Array.isArray(paths)) throw new Error('Archive profile paths are missing');
  const expectedKeys = Object.keys(PROFILE_PATHS).sort();
  const actualKeys = Object.keys(paths).sort();
  if (JSON.stringify(actualKeys) !== JSON.stringify(expectedKeys)) throw new Error('Archive profile paths do not match layout version 2');
  for (const key of expectedKeys) {
    const value = String(paths[key] || '').replace(/\\/g, '/');
    if (value !== PROFILE_PATHS[key] || path.posix.isAbsolute(value) || value === '..' || value.startsWith('../')) {
      throw new Error(`Invalid archive profile path: ${key}`);
    }
  }
}

function resolveArchiveRoot(source, argv = process.argv) {
  const explicitRoot = arg('--root', null, argv);
  const archiveHome = arg('--archive-home', process.env.CHAT_HISTORY_ARCHIVE_HOME || null, argv);
  const profileValue = arg('--profile', null, argv);
  if (explicitRoot && archiveHome && argv.includes('--archive-home')) {
    throw new Error('Use either --root or --archive-home with --profile, not both');
  }
  if (!explicitRoot && !archiveHome) {
    throw new Error('Archive location is required: pass --root <profile-root> or --archive-home <home> --profile <id>');
  }
  let root;
  let profileId;
  if (explicitRoot) {
    root = path.resolve(explicitRoot);
    profileId = profileValue ? normalizeProfileId(profileValue) : null;
  } else {
    profileId = normalizeProfileId(profileValue);
    root = path.resolve(archiveHome, source, profileId);
  }
  if (root === path.parse(root).root) throw new Error(`Refusing filesystem root as archive: ${root}`);
  return { root, profileId };
}

function readArchiveProfile(root, source, legacyIndicators = []) {
  const markerPath = path.join(root, 'archive-profile.json');
  if (fs.existsSync(markerPath)) {
    const marker = JSON.parse(fs.readFileSync(markerPath, 'utf8'));
    if (marker.schema !== SCHEMA) throw new Error(`Unsupported archive profile schema in ${markerPath}`);
    if (marker.source !== source) throw new Error(`Archive source mismatch: expected ${source}, found ${marker.source}`);
    normalizeProfileId(marker.profile_id);
    if (marker.layout_version === LAYOUT_VERSION) validateProfilePaths(marker.paths);
    else if (marker.layout_version !== 1) throw new Error(`Unsupported archive layout version in ${markerPath}`);
    return { marker, markerPath, legacy: false };
  }
  if (!fs.existsSync(root)) throw new Error(`Archive root does not exist; initialize it first: ${root}`);
  const recognized = legacyIndicators.some(relative => fs.existsSync(path.join(root, relative)));
  if (!recognized) throw new Error(`Archive has no marker and is not a recognized ${source} legacy layout: ${root}`);
  return { marker: null, markerPath, legacy: true };
}

function initializeArchive({ root, source, profileId, directories = PROFILE_DIRECTORIES, legacyIndicators = [], adoptExisting = false }) {
  fs.mkdirSync(root, { recursive: true });
  const markerPath = path.join(root, 'archive-profile.json');
  if (fs.existsSync(markerPath)) {
    const existing = readArchiveProfile(root, source, legacyIndicators).marker;
    for (const relative of directories) fs.mkdirSync(path.join(root, relative), { recursive: true });
    return existing;
  }
  const entries = fs.readdirSync(root);
  if (entries.length > 0) {
    const recognized = legacyIndicators.some(relative => fs.existsSync(path.join(root, relative)));
    if (!adoptExisting || !recognized) {
      throw new Error('Non-empty archive root has no profile marker; inspect it, then rerun with --adopt-existing only if it is the intended archive');
    }
  }
  const marker = {
    schema: SCHEMA,
    source,
    profile_id: normalizeProfileId(profileId),
    layout_version: LAYOUT_VERSION,
    paths: { ...PROFILE_PATHS },
    created_at: new Date().toISOString(),
  };
  for (const relative of directories) fs.mkdirSync(path.join(root, relative), { recursive: true });
  fs.writeFileSync(markerPath, `${JSON.stringify(marker, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
  return marker;
}

module.exports = {
  LAYOUT_VERSION,
  PROFILE_DIRECTORIES,
  PROFILE_PATHS,
  SCHEMA,
  arg,
  has,
  initializeArchive,
  normalizeProfileId,
  readArchiveProfile,
  resolveArchiveRoot,
  validateProfilePaths,
};
