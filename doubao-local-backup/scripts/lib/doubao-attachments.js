'use strict';

const crypto = require('crypto');
const fs = require('fs');
const https = require('https');
const path = require('path');
const { ensureDir } = require('./atomic-json');
const { safeName } = require('./file-store');

const ALLOWED_HOST = /(^|\.)(byteimg\.com|doubao\.com)$/i;

function mimeFromName(name, imageFormat = null) {
  const extension = path.extname(name || '').toLowerCase();
  const known = {
    '.pdf': 'application/pdf', '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', '.csv': 'text/csv',
    '.txt': 'text/plain', '.zip': 'application/zip', '.m4a': 'audio/mp4', '.mp3': 'audio/mpeg',
    '.wav': 'audio/wav', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
    '.webp': 'image/webp', '.gif': 'image/gif', '.mp4': 'video/mp4',
  };
  if (known[extension]) return known[extension];
  if (imageFormat) return `image/${String(imageFormat).toLowerCase().replace('jpg', 'jpeg')}`;
  return null;
}

function inferredImageName(format) {
  const normalized = String(format || 'jpg').toLowerCase().replace('jpeg', 'jpg');
  return `image.${/^[a-z0-9]+$/.test(normalized) ? normalized : 'jpg'}`;
}

function publicReference(candidate) {
  return {
    attachment_id: candidate.attachment_id,
    message_id: candidate.message_id || null,
    original_name: candidate.original_name || null,
    mime_type: candidate.mime_type || null,
    size_bytes: Number.isFinite(candidate.size_bytes) ? candidate.size_bytes : null,
    kind: candidate.kind,
    provider_md5: candidate.provider_md5 || null,
  };
}

function extractAttachmentCandidates(value) {
  const byId = new Map();

  function visit(current, messageId = null, depth = 0) {
    if (!current || typeof current !== 'object' || depth > 35) return;
    if (Array.isArray(current)) {
      for (const child of current) visit(child, messageId, depth + 1);
      return;
    }
    const currentMessageId = current.message_id || messageId;
    const attachments = current.attachment_block?.attachments;
    if (Array.isArray(attachments)) {
      for (const attachment of attachments) {
        const file = attachment?.file || null;
        const image = attachment?.image || null;
        const imageSource = image?.image_ori || image?.image_preview || image?.image_thumb || null;
        const id = attachment?.identifier || file?.uri || image?.uri;
        const url = file?.url || imageSource?.url || attachment?.src;
        if (typeof id !== 'string' || !id || (!file?.uri && !image?.uri && (typeof url !== 'string' || !url))) continue;
        const format = imageSource?.format || null;
        const originalName = file?.name || image?.name || (image ? inferredImageName(format) : null);
        const candidate = {
          attachment_id: id,
          message_id: currentMessageId || null,
          original_name: originalName,
          mime_type: mimeFromName(originalName, format),
          size_bytes: Number.isFinite(file?.size) ? file.size : null,
          kind: file ? 'file' : image ? 'image' : 'attachment',
          provider_md5: file?.md5 || image?.md5 || null,
          resource_uri: file?.uri || image?.uri || null,
          download_url: typeof url === 'string' && url ? url : null,
        };
        if (!byId.has(id)) byId.set(id, candidate);
        else {
          const existing = byId.get(id);
          existing.message_id ||= candidate.message_id;
          existing.original_name ||= candidate.original_name;
          existing.mime_type ||= candidate.mime_type;
          existing.size_bytes ??= candidate.size_bytes;
          existing.provider_md5 ||= candidate.provider_md5;
          existing.download_url ||= candidate.download_url;
        }
      }
    }
    for (const child of Object.values(current)) visit(child, currentMessageId, depth + 1);
  }

  visit(value);
  return [...byId.values()];
}

function assertAllowedDownloadUrl(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:') throw new Error('Attachment download URL must use HTTPS');
  if (!ALLOWED_HOST.test(url.hostname)) throw new Error(`Attachment host is not allowed: ${url.hostname}`);
  return url;
}

function fileDigest(file, algorithm) {
  const hash = crypto.createHash(algorithm);
  hash.update(fs.readFileSync(file));
  return hash.digest('hex');
}

function downloadOnce(url, target, redirectsLeft = 5) {
  return new Promise((resolve, reject) => {
    const parsed = assertAllowedDownloadUrl(url);
    const request = https.get(parsed, { headers: {
      'user-agent': 'Mozilla/5.0 doubao-local-backup/1.0',
      'referer': 'https://www.doubao.com/',
      'accept': '*/*',
    } }, response => {
      if ([301, 302, 303, 307, 308].includes(response.statusCode) && response.headers.location) {
        response.resume();
        if (redirectsLeft <= 0) return reject(new Error('Attachment download exceeded redirect limit'));
        const redirected = new URL(response.headers.location, parsed).toString();
        try { assertAllowedDownloadUrl(redirected); } catch (error) { return reject(error); }
        return downloadOnce(redirected, target, redirectsLeft - 1).then(resolve, reject);
      }
      if (response.statusCode !== 200) {
        response.resume();
        return reject(new Error(`Attachment download returned HTTP ${response.statusCode}`));
      }
      const output = fs.createWriteStream(target, { flags: 'wx' });
      let size = 0;
      response.on('data', chunk => { size += chunk.length; });
      response.on('error', reject);
      output.on('error', reject);
      output.on('finish', () => resolve({ size_bytes: size, content_type: response.headers['content-type'] || null }));
      response.pipe(output);
    });
    request.setTimeout(30000, () => request.destroy(new Error('Attachment download timed out')));
    request.on('error', reject);
  });
}

async function downloadAttachment(candidate, workingRoot = 'D:\\Doubao_Backup\\working\\downloads') {
  assertAllowedDownloadUrl(candidate.download_url);
  ensureDir(workingRoot);
  const target = path.join(workingRoot, `${safeName(candidate.attachment_id, 'attachment', 120)}.${process.pid}.${Date.now()}.partial`);
  try {
    const result = await downloadOnce(candidate.download_url, target);
    if (result.size_bytes === 0) throw new Error('Attachment download is zero bytes');
    if (candidate.size_bytes != null && candidate.size_bytes !== result.size_bytes) {
      throw new Error(`Attachment size mismatch: expected ${candidate.size_bytes}, received ${result.size_bytes}`);
    }
    if (candidate.kind === 'file' && candidate.provider_md5 && /^[a-f0-9]{32}$/i.test(candidate.provider_md5)) {
      const actual = fileDigest(target, 'md5');
      if (actual.toLowerCase() !== candidate.provider_md5.toLowerCase()) throw new Error('Attachment MD5 mismatch');
    }
    return { ...candidate, source_path: target, cleanup: true, downloaded_size_bytes: result.size_bytes, response_content_type: result.content_type };
  } catch (error) {
    if (fs.existsSync(target)) fs.rmSync(target, { force: true });
    throw error;
  }
}

module.exports = {
  assertAllowedDownloadUrl,
  downloadAttachment,
  extractAttachmentCandidates,
  publicReference,
};
