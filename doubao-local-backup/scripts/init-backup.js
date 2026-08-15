'use strict';

const path = require('path');
const { ensureDir } = require('./lib/atomic-json');
const { initializeRawState } = require('./lib/raw-state');

function arg(name, fallback = null) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

const root = path.resolve(arg('--root', 'D:\\Doubao_Backup'));
const raw = path.join(root, 'state', 'raw');
for (const directory of [path.join(root, 'working'), path.join(root, 'final'), path.join(root, 'logs'), path.join(root, 'tool'), path.join(root, 'reports')]) {
  ensureDir(directory);
}
const state = initializeRawState(raw);
console.log(JSON.stringify({ root, raw_state: state.root, initialized: true }, null, 2));
