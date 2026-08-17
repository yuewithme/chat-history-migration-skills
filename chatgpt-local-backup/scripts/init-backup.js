'use strict';

const { arg, has, initializeArchive, resolveArchiveRoot } = require('./lib/archive-profile');

const resolved = resolveArchiveRoot('chatgpt');
const profileId = resolved.profileId || arg('--profile');
if (!profileId) throw new Error('Initialization requires --profile <stable-id>');
const marker = initializeArchive({
  root: resolved.root,
  source: 'chatgpt',
  profileId,
  directories: ['tool', 'state', 'working', 'final', 'logs', 'reports'],
  legacyIndicators: ['final/ChatGPT_Backup', 'state/raw'],
  adoptExisting: has('--adopt-existing'),
});
console.log(JSON.stringify({ root: resolved.root, profile: marker, initialized: true }, null, 2));
