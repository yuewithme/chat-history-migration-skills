'use strict';

const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const test = require('node:test');

const scripts = path.resolve(__dirname, '..');
const { PROFILE_PATHS, readArchiveProfile } = require('../lib/archive-profile');
const { atomicWriteJson } = require('../lib/atomic-json');
const { emptyCheckpoint, saveCheckpoint } = require('../lib/checkpoint');
const { buildConversationEnvelope } = require('../lib/doubao-adapter');
const { assertAllowedDownloadUrl, extractAttachmentCandidates } = require('../lib/doubao-attachments');
const { safeName, sha256 } = require('../lib/file-store');
const { createPaginationGuard } = require('../lib/pagination');
const { sanitizeForPersistence } = require('../lib/redaction');
const {
  initializeRawState,
  recordConversationFailure,
  saveAttachment,
  saveConversation,
  shouldFetchConversation,
} = require('../lib/raw-state');

function tempRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'doubao-backup-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function envelope(id, attachmentId, updatedAt = '2026-08-14T00:00:00.000Z') {
  return {
    archive_schema_version: 1,
    provider: 'doubao',
    conversation_id: id,
    collected_at: '2026-08-14T01:00:00.000Z',
    responses: [{ kind: 'conversation_info', cursor: null, next_cursor: null, response: { id } }],
    redactions: [],
    derived: {
      title: `Conversation ${id}`,
      created_at: '2026-08-13T00:00:00.000Z',
      updated_at: updatedAt,
      content_fingerprint: `version-${updatedAt}`,
      message_ids: [`message-${id}`],
      attachments: attachmentId ? [{
        attachment_id: attachmentId,
        message_id: `message-${id}`,
        original_name: 'document.pdf',
        mime_type: 'application/pdf',
        size_bytes: 12,
        kind: 'attachment',
      }] : [],
    },
  };
}

test('atomicWriteJson replaces a valid file without leaving temporary siblings', t => {
  const root = tempRoot(t);
  const target = path.join(root, 'state.json');
  atomicWriteJson(target, { version: 1 });
  atomicWriteJson(target, { version: 2 });
  assert.deepEqual(JSON.parse(fs.readFileSync(target, 'utf8')), { version: 2 });
  assert.deepEqual(fs.readdirSync(root), ['state.json']);
});

test('checkpoint rejects credential-shaped keys', t => {
  const root = tempRoot(t);
  const checkpoint = emptyCheckpoint();
  checkpoint.completed_conversations.example = { access_token: 'should-never-persist' };
  assert.throws(() => saveCheckpoint(path.join(root, 'checkpoint.json'), checkpoint), /Credential-shaped key/);
  assert.equal(fs.existsSync(path.join(root, 'checkpoint.json')), false);
});

test('safeName blocks traversal and Windows-invalid characters', () => {
  const value = safeName('..\\bad/<name>:*?');
  assert.equal(value.includes('..'), false);
  assert.equal(/[<>:"/\\|?*]/.test(value), false);
});

test('redaction removes authentication material and signed URLs with an audit trail', () => {
  const input = {
    title: 'keep me',
    access_token: 'secret',
    nested: { url: 'https://example.invalid/file.pdf?X-Amz-Signature=secret&Expires=1' },
  };
  const result = sanitizeForPersistence(input);
  assert.equal(result.value.title, 'keep me');
  assert.equal(result.value.access_token, null);
  assert.equal(result.value.nested.url, null);
  assert.deepEqual(result.redactions.map(item => item.json_pointer), ['/access_token', '/nested/url']);
});

test('redaction recognizes camelCase credential keys', () => {
  const result = sanitizeForPersistence({ accessToken: 'secret', csrfToken: 'secret', token_count: 42 });
  assert.equal(result.value.accessToken, null);
  assert.equal(result.value.csrfToken, null);
  assert.equal(result.value.token_count, 42);
});

test('redaction recognizes byteimg x-signature URLs', () => {
  const result = sanitizeForPersistence({ url: 'https://p3-flow-imagex-sign.byteimg.com/object?a=1&x-signature=secret&x-expires=1' });
  assert.equal(result.value.url, null);
  assert.equal(result.redactions[0].reason, 'complete ephemeral signed URL removed');
});

test('attachment extraction keeps stable metadata but isolates signed download URLs', () => {
  const candidates = extractAttachmentCandidates({
    message_id: 'm1',
    attachment_block: { attachments: [{
      identifier: 'file-1',
      file: { name: 'report.pdf', size: 10, md5: '0123456789abcdef0123456789abcdef', uri: 'uri-1', url: 'https://p3-flow-sign.byteimg.com/file?x-signature=s' },
    }] },
  });
  assert.equal(candidates.length, 1);
  assert.equal(candidates[0].attachment_id, 'file-1');
  assert.equal(candidates[0].message_id, 'm1');
  assert.equal(candidates[0].mime_type, 'application/pdf');
  assert.doesNotThrow(() => assertAllowedDownloadUrl(candidates[0].download_url));
  assert.throws(() => assertAllowedDownloadUrl('https://example.com/file'));
});

test('conversation envelope preserves response structure and records redaction paths', () => {
  const result = buildConversationEnvelope({
    conversationId: 'conversation-1',
    collectedAt: '2026-08-14T00:00:00.000Z',
    pages: [{ kind: 'chain_page', cursor: '1', nextCursor: null, response: { messages: [1], cookie: 'secret' } }],
    metadata: { messageIds: ['a', 'a', 'b'], attachments: [] },
  });
  assert.deepEqual(result.derived.message_ids, ['a', 'b']);
  assert.equal(result.responses[0].response.cookie, null);
  assert.equal(result.redactions[0].json_pointer, '/responses/0/response/cookie');
});

test('pagination guard stops on provider completion and repeated no-growth pages', () => {
  const completed = createPaginationGuard();
  assert.equal(completed.addPage({ messageIds: ['1'], hasMore: false, nextCursor: null }).stopReason, 'provider reported completion');

  const stagnant = createPaginationGuard();
  assert.equal(stagnant.addPage({ messageIds: ['1'], hasMore: true, nextCursor: 'a' }).stop, false);
  assert.equal(stagnant.addPage({ messageIds: ['1'], hasMore: true, nextCursor: 'b' }).stop, false);
  assert.equal(stagnant.addPage({ messageIds: ['1'], hasMore: true, nextCursor: 'c' }).stopReason, 'two consecutive pages added no stable message IDs');
});

test('raw state selects new and changed conversations and sanitizes failure diagnostics', t => {
  const root = tempRoot(t);
  const raw = path.join(root, 'state', 'raw');
  const state = initializeRawState(raw);
  assert.equal(shouldFetchConversation(state.checkpoint, { conversation_id: 'one', updated_at: 'v1' }).fetch, true);
  const legacy = path.join(raw, 'conversations', 'private-title__one.json');
  fs.writeFileSync(legacy, JSON.stringify(envelope('one', null, 'old')), 'utf8');
  saveConversation(raw, envelope('one', null, 'v1'));
  assert.equal(fs.existsSync(legacy), false);
  const updated = initializeRawState(raw);
  assert.equal(shouldFetchConversation(updated.checkpoint, { conversation_id: 'one', updated_at: 'v1' }).fetch, false);
  assert.equal(shouldFetchConversation(updated.checkpoint, { conversation_id: 'one', updated_at: 'v2' }).fetch, true);
  const failure = recordConversationFailure(raw, 'two', new Error('failed at https://example.invalid/file?token=secret'));
  assert.equal(failure.error.includes('secret'), false);
  assert.equal(failure.error.includes('http'), false);
});

test('raw state atomically stores non-empty attachments and records hashes', t => {
  const root = tempRoot(t);
  const raw = path.join(root, 'state', 'raw');
  const temporary = path.join(root, 'download.partial');
  fs.writeFileSync(temporary, 'attachment-content', 'utf8');
  const result = saveAttachment(raw, { attachment_id: 'file-1', original_name: 'report.pdf' }, temporary);
  assert.equal(fs.existsSync(result.path), true);
  assert.equal(result.sha256, sha256(result.path));
  const checkpoint = initializeRawState(raw).checkpoint;
  assert.equal(checkpoint.completed_attachments['file-1'].sha256, result.sha256);
});

test('verification rejects an empty candidate by default', t => {
  const root = tempRoot(t);
  const raw = path.join(root, 'state', 'raw');
  const candidate = path.join(root, 'working', 'empty');
  fs.mkdirSync(path.join(raw, 'conversations'), { recursive: true });
  execFileSync(process.execPath, [path.join(scripts, 'organize-backup.js'), '--raw', raw, '--out', candidate], { stdio: 'pipe' });
  assert.throws(() => execFileSync(process.execPath, [path.join(scripts, 'verify-backup.js'), '--raw', raw, '--final', candidate], { stdio: 'pipe' }));
  const verification = JSON.parse(fs.readFileSync(path.join(candidate, 'metadata', 'final-verification.json'), 'utf8'));
  assert.equal(verification.empty_backup, true);
  assert.equal(verification.passed, false);
});

test('raw export orchestration runs end-to-end with a synthetic fixture and skips unchanged data', t => {
  const root = tempRoot(t);
  const raw = path.join(root, 'state', 'raw');
  const attachment = path.join(root, 'fixture-attachment.pdf');
  const fixture = path.join(root, 'fixture.json');
  fs.writeFileSync(attachment, 'fixture-attachment', 'utf8');
  writeJson(fixture, {
    conversations: [{
      summary: { conversation_id: 'fixture-one', title: 'Fixture', updated_at: 'v1' },
      collected_at: '2026-08-14T00:00:00.000Z',
      pages: [{ kind: 'conversation_info', cursor: null, nextCursor: null, response: { id: 'fixture-one' } }],
      metadata: {
        title: 'Fixture',
        createdAt: '2026-08-13T00:00:00.000Z',
        updatedAt: 'v1',
        messageIds: ['m1'],
        attachments: [{ attachment_id: 'fixture-file', message_id: 'm1', original_name: 'fixture.pdf' }],
      },
      attachments: [{ attachment_id: 'fixture-file', original_name: 'fixture.pdf', source_path: attachment }],
    }],
  });

  const first = JSON.parse(execFileSync(process.execPath, [path.join(scripts, 'run-raw-export.js'), '--root', root, '--raw', raw, '--fixture', fixture], { encoding: 'utf8' }));
  assert.equal(first.saved, 1);
  assert.equal(first.attachments_saved, 1);
  const second = JSON.parse(execFileSync(process.execPath, [path.join(scripts, 'run-raw-export.js'), '--root', root, '--raw', raw, '--fixture', fixture], { encoding: 'utf8' }));
  assert.equal(second.saved, 0);
  assert.equal(second.skipped, 1);
});

test('backup initializer creates the fixed tree and a safe checkpoint', t => {
  const root = tempRoot(t);
  execFileSync(process.execPath, [path.join(scripts, 'init-backup.js'), '--root', root, '--profile', 'test'], { stdio: 'pipe' });
  for (const relative of ['state/raw/conversations', 'state/raw/files', 'working', 'final', 'logs', 'tool', 'reports', 'documents']) {
    assert.equal(fs.existsSync(path.join(root, relative)), true, relative);
  }
  const checkpoint = JSON.parse(fs.readFileSync(path.join(root, 'state', 'raw', 'checkpoint.json'), 'utf8'));
  assert.equal(checkpoint.provider, 'doubao');
  const profile = JSON.parse(fs.readFileSync(path.join(root, 'archive-profile.json'), 'utf8'));
  assert.equal(profile.source, 'doubao');
  assert.equal(profile.layout_version, 3);
  assert.deepEqual(profile.paths, PROFILE_PATHS);
  assert.equal(Object.values(profile.paths).some(value => path.isAbsolute(value)), false);
  assert.equal(readArchiveProfile(root, 'doubao').legacy, false);
});

test('profile layout rejects changed or escaping paths', t => {
  const root = tempRoot(t);
  execFileSync(process.execPath, [path.join(scripts, 'init-backup.js'), '--root', root, '--profile', 'test'], { stdio: 'pipe' });
  const markerPath = path.join(root, 'archive-profile.json');
  const profile = JSON.parse(fs.readFileSync(markerPath, 'utf8'));
  profile.paths.documents = '../outside';
  writeJson(markerPath, profile);
  assert.throws(() => readArchiveProfile(root, 'doubao'), /Invalid archive profile path/);
});

test('legacy adoption adds layout metadata without moving existing data', t => {
  const root = tempRoot(t);
  const sentinel = path.join(root, 'final', 'Doubao_Backup', 'conversations', 'existing.json');
  writeJson(sentinel, { provider: 'doubao' });
  execFileSync(process.execPath, [path.join(scripts, 'init-backup.js'), '--root', root, '--profile', 'primary', '--adopt-existing'], { stdio: 'pipe' });
  assert.equal(fs.existsSync(sentinel), true);
  assert.equal(fs.existsSync(path.join(root, 'documents')), true);
  const profile = readArchiveProfile(root, 'doubao').marker;
  assert.equal(profile.layout_version, 3);
  assert.deepEqual(profile.paths, PROFILE_PATHS);
});

test('layout 2 upgrades only when deprecated document directories are empty', t => {
  const root = tempRoot(t);
  execFileSync(process.execPath, [path.join(scripts, 'init-backup.js'), '--root', root, '--profile', 'primary'], { stdio: 'pipe' });
  const markerPath = path.join(root, 'archive-profile.json');
  const marker = JSON.parse(fs.readFileSync(markerPath, 'utf8'));
  marker.layout_version = 2;
  marker.paths = {
    chat_json: 'final/Doubao_Backup/conversations', original_files: 'final/Doubao_Backup/attachments/files',
    archive_metadata: 'final/Doubao_Backup/metadata', document_markdown: 'documents/markdown',
    document_json: 'documents/json', document_indexes: 'documents/indexes', state: 'state/raw',
    working: 'working', reports: 'reports', logs: 'logs', tool: 'tool',
  };
  writeJson(markerPath, marker);
  for (const relative of ['documents/markdown', 'documents/json', 'documents/indexes']) fs.mkdirSync(path.join(root, relative), { recursive: true });
  const existingDocument = path.join(root, 'documents', 'markdown', 'keep.md');
  fs.writeFileSync(existingDocument, '# keep\n', 'utf8');
  assert.throws(() => execFileSync(process.execPath, [path.join(scripts, 'init-backup.js'), '--root', root, '--profile', 'primary', '--upgrade-layout'], { stdio: 'pipe' }));
  assert.equal(JSON.parse(fs.readFileSync(markerPath, 'utf8')).layout_version, 2);
  fs.rmSync(existingDocument);
  execFileSync(process.execPath, [path.join(scripts, 'init-backup.js'), '--root', root, '--profile', 'primary', '--upgrade-layout'], { stdio: 'pipe' });
  const upgraded = readArchiveProfile(root, 'doubao').marker;
  assert.equal(upgraded.layout_version, 3);
  assert.deepEqual(upgraded.paths, PROFILE_PATHS);
  assert.equal(fs.existsSync(path.join(root, 'documents', 'markdown')), false);
});

test('organize, verify, publish, and rebuild preserve data and deduplicate attachments', t => {
  const root = tempRoot(t);
  const raw = path.join(root, 'state', 'raw');
  const working = path.join(root, 'working');
  const candidate = path.join(working, 'candidate-1');
  fs.mkdirSync(path.join(raw, 'conversations'), { recursive: true });
  fs.mkdirSync(path.join(raw, 'files'), { recursive: true });
  writeJson(path.join(raw, 'conversations', 'one.json'), envelope('one', 'attachment-a'));
  writeJson(path.join(raw, 'conversations', 'two.json'), envelope('two', 'attachment-b'));
  fs.writeFileSync(path.join(raw, 'files', 'attachment-a.pdf'), 'same-content', 'utf8');
  fs.writeFileSync(path.join(raw, 'files', 'attachment-b.pdf'), 'same-content', 'utf8');

  execFileSync(process.execPath, [path.join(scripts, 'organize-backup.js'), '--raw', raw, '--out', candidate], { stdio: 'pipe' });
  execFileSync(process.execPath, [path.join(scripts, 'verify-backup.js'), '--raw', raw, '--final', candidate], { stdio: 'pipe' });

  const manifest = JSON.parse(fs.readFileSync(path.join(candidate, 'attachments', 'manifest.json'), 'utf8'));
  assert.equal(manifest.files.length, 1);
  assert.deepEqual(new Set(manifest.files[0].attachment_ids), new Set(['attachment-a', 'attachment-b']));
  assert.equal(manifest.files[0].sha256, sha256(path.join(raw, 'files', 'attachment-a.pdf')));
  const verification = JSON.parse(fs.readFileSync(path.join(candidate, 'metadata', 'final-verification.json'), 'utf8'));
  assert.equal(verification.passed, true);

  execFileSync(process.execPath, [path.join(scripts, 'publish-backup.js'), '--root', root, '--candidate', candidate], { stdio: 'pipe' });
  const final = path.join(root, 'final', 'Doubao_Backup');
  assert.equal(fs.existsSync(final), true);
  assert.equal(fs.existsSync(candidate), false);

  execFileSync(process.execPath, [path.join(scripts, 'rebuild-incremental-state.js'), '--root', root], { stdio: 'pipe' });
  const checkpoint = JSON.parse(fs.readFileSync(path.join(raw, 'checkpoint.json'), 'utf8'));
  assert.deepEqual(new Set(Object.keys(checkpoint.completed_conversations)), new Set(['one', 'two']));
  assert.deepEqual(new Set(Object.keys(checkpoint.completed_attachments)), new Set(['attachment-a', 'attachment-b']));
  assert.equal(fs.existsSync(path.join(raw, 'files', 'attachment-a.pdf')), true);
  assert.equal(fs.existsSync(path.join(raw, 'files', 'attachment-b.pdf')), true);
});

test('verification fails without replacing final when an attachment is missing', t => {
  const root = tempRoot(t);
  const raw = path.join(root, 'state', 'raw');
  const candidate = path.join(root, 'working', 'candidate-bad');
  writeJson(path.join(raw, 'conversations', 'missing.json'), envelope('missing', 'absent-file'));

  execFileSync(process.execPath, [path.join(scripts, 'organize-backup.js'), '--raw', raw, '--out', candidate], { stdio: 'pipe' });
  assert.throws(() => execFileSync(process.execPath, [path.join(scripts, 'verify-backup.js'), '--raw', raw, '--final', candidate], { stdio: 'pipe' }));
  const verification = JSON.parse(fs.readFileSync(path.join(candidate, 'metadata', 'final-verification.json'), 'utf8'));
  assert.equal(verification.passed, false);
  assert.deepEqual(verification.failed_attachments.map(item => item.attachment_id), ['absent-file']);
  assert.throws(() => execFileSync(process.execPath, [path.join(scripts, 'publish-backup.js'), '--root', root, '--candidate', candidate], { stdio: 'pipe' }));
  assert.equal(fs.existsSync(path.join(root, 'final', 'Doubao_Backup')), false);
});
