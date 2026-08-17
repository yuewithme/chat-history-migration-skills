'use strict';

const fs = require('fs');
const path = require('path');

function arg(name, fallback = null) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const toolArg = arg('--tool');
if (!toolArg) throw new Error('Usage: node patch-exporter.js --tool <export-chatgpt-dir>');
const tool = path.resolve(toolArg);
const downloaderTarget = path.join(tool, 'lib', 'downloader.js');
if (!fs.existsSync(downloaderTarget)) throw new Error(`Missing exporter file: ${downloaderTarget}`);

let source = fs.readFileSync(downloaderTarget, 'utf8');
const downloaderEol = source.includes('\r\n') ? '\r\n' : '\n';
source = source.replace(/\r\n/g, '\n');
let changed = false;

if (!source.includes('dictation_asset_format: messageMetadata.dictation_asset_format')) {
  const anchor = '    const content = node.message.content;\n    const conversationId = conversationData.id || conversationData.conversation_id;';
  const replacement = `    const content = node.message.content;\n    const messageMetadata = node.message.metadata || {};\n    const conversationId = conversationData.id || conversationData.conversation_id;\n\n    // Voice dictation audio lives in message metadata, not message content.\n    if (messageMetadata.dictation_asset_pointer) {\n      const fileId = messageMetadata.dictation_asset_pointer.replace(/^(sediment|file-service):\\/\\//, '');\n      if (fileId) files.push({\n        fileId, conversationId, type: 'attachment',\n        metadata: { dictation_asset_format: messageMetadata.dictation_asset_format || null },\n        sizeBytes: null,\n      });\n    }`;
  if (!source.includes(anchor)) throw new Error('Upstream downloader structure changed near conversation metadata; review manually');
  source = source.replace(anchor, replacement);
  changed = true;
}

if (!source.includes("parsedUrl.hostname === 'chatgpt.com'")) {
  const anchor = '  const headers = accessToken ? createApiHeaders(accessToken) : {};';
  const replacement = `  // Never forward account credentials to an API-supplied third-party host.\n  const parsedUrl = new URL(downloadUrl);\n  if (parsedUrl.protocol !== 'https:') {\n    throw new Error(\`Refusing non-HTTPS file download URL: \${parsedUrl.protocol}\`);\n  }\n  const isChatGptHost = parsedUrl.hostname === 'chatgpt.com' || parsedUrl.hostname.endsWith('.chatgpt.com');\n  const headers = accessToken && isChatGptHost ? createApiHeaders(accessToken) : {};`;
  if (!source.includes(anchor)) throw new Error('Upstream download authorization structure changed; review manually');
  source = source.replace(anchor, replacement);
  changed = true;
}

if (changed) fs.writeFileSync(downloaderTarget, source.replace(/\n/g, downloaderEol), 'utf8');

function patchFile(relativePath, marker, transforms) {
  const target = path.join(tool, relativePath);
  if (!fs.existsSync(target)) throw new Error(`Missing exporter file: ${target}`);
  let text = fs.readFileSync(target, 'utf8');
  if (text.includes(marker)) return false;
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  text = text.replace(/\r\n/g, '\n');
  for (const [anchor, replacement] of transforms) {
    if (!text.includes(anchor)) throw new Error(`Upstream structure changed in ${relativePath}; review manually`);
    text = text.replace(anchor, replacement);
  }
  fs.writeFileSync(target, text.replace(/\n/g, eol), 'utf8');
  return true;
}

const apiChanged = patchFile('lib/api.js', '_needs_update: true', [
  [
    `          if (!existingIndex.has(conv.id)) {
            // Tag so downstream can distinguish if needed.
            existingIndex.set(conv.id, { ...conv, _archived: isArchived });
            newCount++;
            pageNewCount++;
          }`,
    `          const previous = existingIndex.get(conv.id);
          if (!previous) {
            // Tag so downstream can distinguish if needed.
            existingIndex.set(conv.id, { ...conv, _archived: isArchived });
            newCount++;
            pageNewCount++;
          } else if ((previous.update_time ?? null) !== (conv.update_time ?? null)) {
            existingIndex.set(conv.id, { ...previous, ...conv, _archived: isArchived, _needs_update: true });
            newCount++;
            pageNewCount++;
          }`,
  ],
  [
    `        for (const conv of data.items) {
          if (!conversations.find(c => c.id === conv.id)) {
            conversations.push(conv);
          }
        }`,
    `        for (const conv of data.items) {
          const existingPosition = conversations.findIndex(c => c.id === conv.id);
          if (existingPosition < 0) {
            conversations.push(conv);
          } else if ((conversations[existingPosition].update_time ?? null) !== (conv.update_time ?? null)) {
            conversations[existingPosition] = { ...conversations[existingPosition], ...conv, _needs_update: true };
          }
        }`,
  ],
]);

const exporterChanged = patchFile('lib/exporter.js', 'const isSelectiveUpdate = conv._needs_update === true', [
  [
    '    if (!CONFIG.updateExisting) {\n      if (progress.downloadedIds.includes(conv.id)) {',
    `    const isSelectiveUpdate = conv._needs_update === true;
    if (!CONFIG.updateExisting && !isSelectiveUpdate) {
      if (progress.downloadedIds.includes(conv.id)) {`,
  ],
  [
    `    const isUpdate = CONFIG.updateExisting && (
      progress.downloadedIds.includes(conv.id) ||
      (fs.existsSync(PATHS.jsonDir) && fs.readdirSync(PATHS.jsonDir).filter(f => f.includes(shortId)).length > 0)
    );`,
    `    const isUpdate = isSelectiveUpdate || (CONFIG.updateExisting && (
      progress.downloadedIds.includes(conv.id) ||
      (fs.existsSync(PATHS.jsonDir) && fs.readdirSync(PATHS.jsonDir).filter(f => f.includes(shortId)).length > 0)
    ));`,
  ],
  [
    `      if (!progress.downloadedIds.includes(conv.id)) {
        progress.downloadedIds.push(conv.id);
      }
      saveProgress(progress);`,
    `      if (!progress.downloadedIds.includes(conv.id)) {
        progress.downloadedIds.push(conv.id);
      }
      delete conv._needs_update;
      saveIndex(conversationIndex);
      saveProgress(progress);`,
  ],
  [
    `    if (!CONFIG.updateExisting && projProgress.downloadedIds.includes(conv.id)) {
      skipCount++;
      continue;
    }

    const isUpdate = CONFIG.updateExisting && projProgress.downloadedIds.includes(conv.id);`,
    `    const isSelectiveUpdate = conv._needs_update === true;
    if (!CONFIG.updateExisting && !isSelectiveUpdate && projProgress.downloadedIds.includes(conv.id)) {
      skipCount++;
      continue;
    }

    const isUpdate = isSelectiveUpdate || (CONFIG.updateExisting && projProgress.downloadedIds.includes(conv.id));`,
  ],
  [
    `      if (!projProgress.downloadedIds.includes(conv.id)) {
        projProgress.downloadedIds.push(conv.id);
      }
      saveProgress(progress);`,
    `      if (!projProgress.downloadedIds.includes(conv.id)) {
        projProgress.downloadedIds.push(conv.id);
      }
      delete conv._needs_update;
      fs.writeFileSync(projectConvIndexFile, JSON.stringify(conversations, null, 2));
      saveProgress(progress);`,
  ],
]);

const patched = changed || apiChanged || exporterChanged;
console.log(patched ? 'Applied security, dictation, and selective-update patches' : 'All exporter patches already present');
