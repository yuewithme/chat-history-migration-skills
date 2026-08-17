'use strict';

const fs = require('fs');
const path = require('path');

const SCHEMA = 'chat-history-archive-profile-v1';

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
    return { marker, markerPath, legacy: false };
  }
  if (!fs.existsSync(root)) throw new Error(`Archive root does not exist; initialize it first: ${root}`);
  const recognized = legacyIndicators.some(relative => fs.existsSync(path.join(root, relative)));
  if (!recognized) throw new Error(`Archive has no marker and is not a recognized ${source} legacy layout: ${root}`);
  return { marker: null, markerPath, legacy: true };
}

function initializeArchive({ root, source, profileId, directories, legacyIndicators = [], adoptExisting = false }) {
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
    layout_version: 1,
    created_at: new Date().toISOString(),
  };
  for (const relative of directories) fs.mkdirSync(path.join(root, relative), { recursive: true });
  fs.writeFileSync(markerPath, `${JSON.stringify(marker, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
  return marker;
}

module.exports = { SCHEMA, arg, has, initializeArchive, normalizeProfileId, readArchiveProfile, resolveArchiveRoot };
