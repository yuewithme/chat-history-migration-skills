'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

function safeName(value, fallback = 'untitled', maxLength = 100) {
  const result = String(value || fallback)
    .replace(/[<>:"/\\|?*\x00-\x1F]/g, '_')
    .replace(/\.{2,}/g, '_')
    .replace(/\s+/g, '_')
    .replace(/^[. ]+|[. ]+$/g, '')
    .slice(0, maxLength);
  return result || fallback;
}

function datePrefix(value) {
  if (value == null) return 'unknown';
  let candidate = value;
  if (typeof value === 'number' && value < 100000000000) candidate = value * 1000;
  const date = new Date(candidate);
  return Number.isNaN(date.getTime()) ? 'unknown' : date.toISOString().slice(0, 10);
}

function sha256(file) {
  const descriptor = fs.openSync(file, 'r');
  const hash = crypto.createHash('sha256');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  try {
    let bytesRead;
    do {
      bytesRead = fs.readSync(descriptor, buffer, 0, buffer.length, null);
      if (bytesRead > 0) hash.update(buffer.subarray(0, bytesRead));
    } while (bytesRead > 0);
  } finally {
    fs.closeSync(descriptor);
  }
  return hash.digest('hex');
}

function findAttachment(rawFilesDir, attachmentId) {
  if (!fs.existsSync(rawFilesDir)) return null;
  const storedId = safeName(attachmentId, 'attachment', 180);
  const matches = fs.readdirSync(rawFilesDir, { withFileTypes: true })
    .filter(entry => entry.isFile() && (entry.name === storedId || entry.name.startsWith(`${storedId}.`)))
    .map(entry => path.join(rawFilesDir, entry.name));
  return matches.length === 1 ? matches[0] : null;
}

function extensionFor(source, originalName = null) {
  const originalExtension = originalName ? path.extname(originalName) : '';
  return (originalExtension || path.extname(source)).toLowerCase();
}

module.exports = { datePrefix, extensionFor, findAttachment, safeName, sha256 };
