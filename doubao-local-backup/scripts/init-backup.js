'use strict';

const path = require('path');
const { ensureDir } = require('./lib/atomic-json');
const { arg, has, initializeArchive, PROFILE_DIRECTORIES, resolveArchiveRoot } = require('./lib/archive-profile');
const { initializeRawState } = require('./lib/raw-state');

const resolved = resolveArchiveRoot('doubao');
const root = resolved.root;
const profileId = resolved.profileId || arg('--profile');
if (!profileId) throw new Error('Initialization requires --profile <stable-id>');
const marker = initializeArchive({
  root,
  source: 'doubao',
  profileId,
  directories: PROFILE_DIRECTORIES,
  legacyIndicators: ['final/Doubao_Backup', 'state/raw'],
  adoptExisting: has('--adopt-existing'),
  upgradeLayout: has('--upgrade-layout'),
});
const raw = path.join(root, 'state', 'raw');
for (const directory of [path.join(root, 'working'), path.join(root, 'final'), path.join(root, 'logs'), path.join(root, 'tool'), path.join(root, 'reports')]) {
  ensureDir(directory);
}
const state = initializeRawState(raw);
console.log(JSON.stringify({ root, profile: marker, raw_state: state.root, initialized: true }, null, 2));
