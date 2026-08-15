'use strict';

const SIGNED_QUERY_KEY = /^(x-amz-signature|x-signature|signature|sign|token|auth_key|authorization|expires?|x-expires|x-tos-signature)$/i;

function isSensitiveKey(value) {
  const normalized = String(value).replace(/[^a-z0-9]/gi, '').toLowerCase();
  return new Set([
    'authorization', 'cookie', 'setcookie', 'accesstoken', 'refreshtoken', 'sessiontoken',
    'csrftoken', 'password', 'secret', 'credentials', 'signedurl', 'downloadurl',
  ]).has(normalized);
}

function escapePointer(value) {
  return String(value).replace(/~/g, '~0').replace(/\//g, '~1');
}

function isEphemeralSignedUrl(value) {
  if (typeof value !== 'string' || !/^https?:\/\//i.test(value)) return false;
  try {
    const url = new URL(value);
    return [...url.searchParams.keys()].some(key => SIGNED_QUERY_KEY.test(key));
  } catch {
    return false;
  }
}

function sanitizeForPersistence(value) {
  const redactions = [];

  function visit(current, pointer) {
    if (Array.isArray(current)) return current.map((item, index) => visit(item, `${pointer}/${index}`));
    if (!current || typeof current !== 'object') {
      if (isEphemeralSignedUrl(current)) {
        redactions.push({ json_pointer: pointer || '/', reason: 'complete ephemeral signed URL removed' });
        return null;
      }
      return current;
    }
    const output = {};
    for (const [key, child] of Object.entries(current)) {
      const childPointer = `${pointer}/${escapePointer(key)}`;
      if (isSensitiveKey(key)) {
        output[key] = null;
        redactions.push({ json_pointer: childPointer, reason: 'authentication material removed' });
      } else {
        output[key] = visit(child, childPointer);
      }
    }
    return output;
  }

  return { value: visit(value, ''), redactions };
}

function sanitizeDiagnostic(value) {
  return String(value || '')
    .replace(/https?:\/\/[^\s"'<>]+/gi, '[redacted-url]')
    .replace(/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g, '[redacted-token]')
    .slice(0, 1000);
}

module.exports = { isEphemeralSignedUrl, isSensitiveKey, sanitizeDiagnostic, sanitizeForPersistence };
