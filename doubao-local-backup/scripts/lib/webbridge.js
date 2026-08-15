'use strict';

const http = require('http');

const HOST = '127.0.0.1';
const PORT = 10086;

function command(action, args, session = 'doubao-local-backup', timeoutMs = 20000) {
  const body = JSON.stringify({ action, args: args || {}, session });
  return new Promise((resolve, reject) => {
    const request = http.request({
      hostname: HOST,
      port: PORT,
      path: '/command',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
    }, response => {
      let data = '';
      response.setEncoding('utf8');
      response.on('data', chunk => { data += chunk; });
      response.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          if (!parsed.ok) {
            const detail = parsed.error;
            const message = typeof detail === 'string'
              ? detail
              : (detail?.message || detail?.error || `${action} failed (${Object.keys(detail || {}).join(', ') || 'no details'})`);
            reject(new Error(message));
          }
          else resolve(parsed.data);
        } catch (error) {
          reject(new Error(`Invalid WebBridge response for ${action}: ${error.message}`));
        }
      });
    });
    request.on('error', reject);
    request.setTimeout(timeoutMs, () => request.destroy(new Error(`WebBridge ${action} timed out after ${timeoutMs} ms`)));
    request.end(body);
  });
}

module.exports = { command };
