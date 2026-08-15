'use strict';

const fs = require('fs');
const path = require('path');

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function assertInside(parent, child, label = 'Path') {
  const parentPath = path.resolve(parent);
  const childPath = path.resolve(child);
  const relative = path.relative(parentPath, childPath);
  if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error(`${label} must be a child of ${parentPath}: ${childPath}`);
  }
  return childPath;
}

function temporaryPath(target, marker = 'partial') {
  return `${target}.${marker}-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function atomicReplace(target, writeTemporary, validateTemporary = null) {
  const targetPath = path.resolve(target);
  ensureDir(path.dirname(targetPath));
  const temp = temporaryPath(targetPath);
  const rollback = temporaryPath(targetPath, 'rollback');
  let oldMoved = false;

  try {
    writeTemporary(temp);
    if (validateTemporary) validateTemporary(temp);
    if (fs.existsSync(targetPath)) {
      fs.renameSync(targetPath, rollback);
      oldMoved = true;
    }
    fs.renameSync(temp, targetPath);
    if (oldMoved && fs.existsSync(rollback)) fs.rmSync(rollback, { force: false });
  } catch (error) {
    if (fs.existsSync(temp)) fs.rmSync(temp, { force: true });
    if (!fs.existsSync(targetPath) && oldMoved && fs.existsSync(rollback)) fs.renameSync(rollback, targetPath);
    throw error;
  }

  return targetPath;
}

function atomicWriteJson(target, value) {
  return atomicReplace(
    target,
    temp => fs.writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`, 'utf8'),
    temp => JSON.parse(fs.readFileSync(temp, 'utf8')),
  );
}

function atomicWriteText(target, value) {
  return atomicReplace(target, temp => fs.writeFileSync(temp, value, 'utf8'));
}

function atomicCopy(source, target) {
  const sourcePath = path.resolve(source);
  if (!fs.existsSync(sourcePath) || !fs.statSync(sourcePath).isFile()) {
    throw new Error(`Source file does not exist: ${sourcePath}`);
  }
  return atomicReplace(target, temp => fs.copyFileSync(sourcePath, temp));
}

module.exports = {
  assertInside,
  atomicCopy,
  atomicReplace,
  atomicWriteJson,
  atomicWriteText,
  ensureDir,
};
