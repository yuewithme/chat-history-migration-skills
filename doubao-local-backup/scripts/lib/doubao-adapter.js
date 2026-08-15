'use strict';

const crypto = require('crypto');
const { command } = require('./webbridge');
const { sanitizeForPersistence } = require('./redaction');
const { createPaginationGuard, uniqueStableIds } = require('./pagination');
const { downloadAttachment, extractAttachmentCandidates, publicReference } = require('./doubao-attachments');

const SESSION = 'doubao-local-backup';
const CONTENT_TYPE = 'application/json; encoding=utf-8';
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

function buildConversationEnvelope({ conversationId, collectedAt = new Date().toISOString(), pages, metadata }) {
  if (typeof conversationId !== 'string' || !conversationId) throw new Error('conversationId is required');
  if (!Array.isArray(pages) || pages.length === 0) throw new Error('At least one captured response page is required');
  const responses = [];
  const redactions = [];
  for (const page of pages) {
    const sanitized = sanitizeForPersistence(page.response);
    const responseIndex = responses.length;
    responses.push({
      kind: page.kind,
      cursor: page.cursor ?? null,
      next_cursor: page.nextCursor ?? null,
      response: sanitized.value,
    });
    for (const item of sanitized.redactions) {
      redactions.push({ ...item, json_pointer: `/responses/${responseIndex}/response${item.json_pointer === '/' ? '' : item.json_pointer}` });
    }
  }
  return {
    archive_schema_version: 1,
    provider: 'doubao',
    conversation_id: conversationId,
    collected_at: collectedAt,
    responses,
    redactions,
    derived: {
      title: metadata?.title ?? null,
      created_at: metadata?.createdAt ?? null,
      updated_at: metadata?.updatedAt ?? null,
      content_fingerprint: metadata?.contentFingerprint ?? null,
      message_ids: uniqueStableIds(metadata?.messageIds),
      attachments: Array.isArray(metadata?.attachments) ? metadata.attachments : [],
      pagination: metadata?.pagination || null,
    },
  };
}

function collectNetworkRequests(value, output = [], seen = new Set()) {
  if (!value || typeof value !== 'object' || seen.has(value)) return output;
  seen.add(value);
  const url = value.url || value.request?.url;
  const requestId = value.requestId || value.request_id || value.id;
  if (url && requestId) output.push({ requestId: String(requestId), url: String(url) });
  for (const child of Object.values(value)) collectNetworkRequests(child, output, seen);
  return output;
}

function listBody(data) {
  return data?.downlink_body?.pull_recent_conv_chain_downlink_body || null;
}

function singleBody(data) {
  return data?.downlink_body?.pull_singe_chain_downlink_body || null;
}

function summaryFromCell(cell) {
  const conversation = cell?.conversation;
  if (!conversation?.conversation_id) return null;
  return {
    conversation_id: String(conversation.conversation_id),
    title: conversation.name ?? null,
    created_at: conversation.create_time ?? null,
    updated_at: conversation.update_time ?? null,
    content_fingerprint: conversation.conv_version ?? null,
    conversation_type: conversation.conversation_type ?? 3,
    raw_cell: cell,
  };
}

function messagesFromSingle(data) {
  return singleBody(data)?.messages || [];
}

async function pageFetch(url, requestBody) {
  const code = `(async () => {
    const response = await fetch(${JSON.stringify(url)}, {
      method: 'POST', credentials: 'include', headers: {'content-type':${JSON.stringify(CONTENT_TYPE)}},
      body: ${JSON.stringify(JSON.stringify(requestBody))}
    });
    const data = await response.json();
    return JSON.stringify({http_status:response.status,data});
  })()`;
  const result = await command('evaluate', { code }, SESSION, 300000);
  const value = typeof result.value === 'string' ? JSON.parse(result.value) : result.value;
  if (!value || value.http_status !== 200) throw new Error(`Doubao API returned HTTP ${value?.http_status ?? 'unknown'}`);
  if (value.data?.status_code) throw new Error(`Doubao API status ${value.data.status_code}: ${value.data.status_desc || 'unknown'}`);
  return value.data;
}

async function directPost(url, requestBody, transientContext) {
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      accept: 'application/json, text/plain, */*',
      'content-type': CONTENT_TYPE,
      cookie: transientContext.cookieHeader,
      origin: 'https://www.doubao.com',
      referer: transientContext.referer,
      'user-agent': transientContext.userAgent,
    },
    body: JSON.stringify(requestBody),
    signal: AbortSignal.timeout(300000),
  });
  if (response.status !== 200) throw new Error(`Doubao API returned HTTP ${response.status}`);
  const data = await response.json();
  if (data?.status_code) throw new Error(`Doubao API status ${data.status_code}: ${data.status_desc || 'unknown'}`);
  return data;
}

async function plainPost(url, requestBody) {
  const code = `(async () => {
    const response = await fetch(${JSON.stringify(url)}, {
      method: 'POST', credentials: 'include', headers: {'content-type':'application/json'},
      body: ${JSON.stringify(JSON.stringify(requestBody))}
    });
    return JSON.stringify({http_status:response.status,data:await response.json()});
  })()`;
  const result = await command('evaluate', { code }, SESSION, 60000);
  const value = typeof result.value === 'string' ? JSON.parse(result.value) : result.value;
  if (!value || value.http_status !== 200) throw new Error(`Doubao resource API returned HTTP ${value?.http_status ?? 'unknown'}`);
  const codeValue = value.data?.code ?? value.data?.status_code ?? 0;
  if (codeValue) throw new Error(`Doubao resource API status ${codeValue}`);
  return value.data;
}

async function directPlainPost(url, requestBody, transientContext) {
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      accept: 'application/json, text/plain, */*',
      'content-type': 'application/json',
      cookie: transientContext.cookieHeader,
      origin: 'https://www.doubao.com',
      referer: transientContext.referer,
      'user-agent': transientContext.userAgent,
    },
    body: JSON.stringify(requestBody),
    signal: AbortSignal.timeout(300000),
  });
  if (response.status !== 200) throw new Error(`Doubao resource API returned HTTP ${response.status}`);
  const data = await response.json();
  const codeValue = data?.code ?? data?.status_code ?? 0;
  if (codeValue) throw new Error(`Doubao resource API status ${codeValue}`);
  return data;
}

class DoubaoLiveAdapter {
  constructor() {
    this.initialized = false;
    this.listEndpoint = null;
    this.listRequestTemplate = null;
    this.initialListResponse = null;
    this.summaries = new Map();
  }

  async initialize() {
    if (this.initialized) return;
    try {
      await command('find_tab', { url: 'https://www.doubao.com/chat/' }, SESSION);
    } catch {
      await command('navigate', {
        url: 'https://www.doubao.com/chat/',
        newTab: true,
        group_title: '豆包备份与周轮询',
      }, SESSION);
      await sleep(3000);
    }
    try { await command('network', { cmd: 'stop' }, SESSION, 5000); } catch {}
    await command('network', { cmd: 'start' }, SESSION);
    await command('cdp', { method: 'Page.reload', params: { ignoreCache: false } }, SESSION, 5000);
    await sleep(6000);
    const listed = await command('network', { cmd: 'list', filter: '/im/chain/recent_conv' }, SESSION);
    const candidates = [...new Map(collectNetworkRequests(listed)
      .filter(item => new URL(item.url).pathname === '/im/chain/recent_conv')
      .map(item => [item.requestId, item])).values()].reverse().slice(0, 10);
    const candidateErrors = [];
    for (const candidate of candidates) {
      try {
        const detail = await command('network', { cmd: 'detail', requestId: candidate.requestId }, SESSION);
        const body = listBody(detail.body);
        if (!body || !Array.isArray(body.cells) || body.cells.length === 0) continue;
        const post = await command('cdp', { method: 'Network.getRequestPostData', params: { requestId: candidate.requestId } }, SESSION);
        this.listEndpoint = detail.url;
        this.listRequestTemplate = JSON.parse(post.postData);
        this.initialListResponse = detail.body;
        break;
      } catch (error) { candidateErrors.push(String(error.message || error).slice(0, 200)); }
    }
    if (!this.initialListResponse) {
      throw new Error(`Could not capture a usable Doubao recent-conversation request (candidates=${candidates.length}; errors=${candidateErrors.join(' | ') || 'none'})`);
    }
    this.initialized = true;
  }

  async discoverConversations(options = {}) {
    await this.initialize();
    const maximumPages = Number.isInteger(options.maxPages) && options.maxPages > 0 ? options.maxPages : 10000;
    const summaries = new Map();
    let data = this.initialListResponse;
    let pages = 0;
    let previousCursor = null;
    while (data) {
      pages++;
      const body = listBody(data);
      if (!body) throw new Error('Doubao list response is missing pull_recent_conv_chain_downlink_body');
      for (const cell of body.cells || []) {
        const summary = summaryFromCell(cell);
        if (summary) summaries.set(summary.conversation_id, summary);
      }
      if (pages >= maximumPages) break;
      if (body.has_more === false || !body.next_conv_version) break;
      if (body.next_conv_version === previousCursor) throw new Error('Doubao list pagination cursor repeated');
      if (pages >= 10000) throw new Error('Doubao list maximum page guard reached');
      previousCursor = body.next_conv_version;
      const request = structuredClone(this.listRequestTemplate);
      request.sequence_id = crypto.randomUUID();
      const uplink = request.uplink_body.pull_recent_conv_chain_uplink_body;
      uplink.conv_version = Number(body.next_conv_version);
      uplink.direction = 1;
      uplink.option.need_coco_conversation = false;
      uplink.option.need_coco_bot = false;
      let nextPage = null;
      let lastError = null;
      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          nextPage = await pageFetch(this.listEndpoint, request);
          lastError = null;
          break;
        } catch (error) {
          lastError = error;
          if (attempt < 2) await sleep(500 * (2 ** attempt) + Math.floor(Math.random() * 150));
        }
      }
      if (!nextPage) throw lastError || new Error('Doubao list page request failed');
      data = nextPage;
      await sleep(120);
    }
    this.summaries = summaries;
    return [...summaries.values()].map(summary => ({
      conversation_id: summary.conversation_id,
      title: summary.title,
      created_at: summary.created_at,
      updated_at: summary.updated_at,
      content_fingerprint: summary.content_fingerprint,
    }));
  }

  async captureOfficialSingleRequest(conversationId) {
    try { await command('network', { cmd: 'stop' }, SESSION, 5000); } catch {}
    await command('network', { cmd: 'start' }, SESSION);
    await command('navigate', { url: `https://www.doubao.com/chat/${encodeURIComponent(conversationId)}` }, SESSION, 30000);
    await sleep(6000);
    const listed = await command('network', { cmd: 'list', filter: '/im/chain/single' }, SESSION, 30000);
    const candidates = [...new Map(collectNetworkRequests(listed)
      .filter(item => new URL(item.url).pathname === '/im/chain/single')
      .map(item => [item.requestId, item])).values()].reverse().slice(0, 20);
    const errors = [];
    for (const candidate of candidates) {
      try {
        const post = await command('cdp', { method: 'Network.getRequestPostData', params: { requestId: candidate.requestId } }, SESSION, 30000);
        const request = JSON.parse(post.postData);
        const uplink = request?.uplink_body?.pull_singe_chain_uplink_body;
        if (String(uplink?.conversation_id || '') !== conversationId) continue;
        const responsePayload = await command('cdp', {
          method: 'Network.getResponseBody',
          params: { requestId: candidate.requestId },
        }, SESSION, 300000);
        const responseText = responsePayload.base64Encoded
          ? Buffer.from(responsePayload.body, 'base64').toString('utf8')
          : responsePayload.body;
        const response = JSON.parse(responseText);
        if (!singleBody(response)) continue;
        const cookieResult = await command('cdp', {
          method: 'Network.getCookies',
          params: { urls: [candidate.url] },
        }, SESSION, 30000);
        const userAgentResult = await command('evaluate', { code: 'navigator.userAgent' }, SESSION, 30000);
        return {
          endpoint: candidate.url,
          request,
          response,
          transientContext: {
            cookieHeader: (cookieResult.cookies || []).map(cookie => `${cookie.name}=${cookie.value}`).join('; '),
            referer: `https://www.doubao.com/chat/${encodeURIComponent(conversationId)}`,
            userAgent: String(userAgentResult.value || ''),
          },
        };
      } catch (error) {
        errors.push(String(error.message || error).slice(0, 200));
      }
    }
    throw new Error(`Could not capture the current Doubao single-conversation request (candidates=${candidates.length}; errors=${errors.join(' | ') || 'none'})`);
  }

  async collectConversation(conversationId, options = {}) {
    await this.initialize();
    const summary = this.summaries.get(conversationId);
    if (!summary) throw new Error('Conversation is not present in the discovered list');
    const captured = await this.captureOfficialSingleRequest(conversationId);
    const endpoint = captured.endpoint;
    const requestTemplate = captured.request;
    const transientContext = captured.transientContext;
    this.transientContext = transientContext;
    const capturedUplink = requestTemplate?.uplink_body?.pull_singe_chain_uplink_body;
    if (!capturedUplink) throw new Error('Captured Doubao single request has no expected uplink body');
    let anchorIndex = Number(capturedUplink.anchor_index ?? 999999);
    let capturedData = captured.response;
    const pageSize = Number.isInteger(options.pageSize) && options.pageSize >= 1 && options.pageSize <= 20
      ? options.pageSize
      : 20;
    const guard = createPaginationGuard(5000);
    const pages = [{ kind: 'conversation_info', cursor: null, nextCursor: null, response: summary.raw_cell }];
    const messageIds = [];
    let finalPagination = null;

    for (;;) {
      const request = structuredClone(requestTemplate);
      request.sequence_id = crypto.randomUUID();
      const uplink = request.uplink_body.pull_singe_chain_uplink_body;
      uplink.conversation_id = conversationId;
      uplink.conversation_type = summary.conversation_type || uplink.conversation_type || 3;
      uplink.anchor_index = Number(anchorIndex);
      uplink.direction = 1;
      uplink.limit = pageSize;
      let data = capturedData;
      let lastError = null;
      if (!data) {
        for (let attempt = 0; attempt < 3; attempt++) {
          try {
            data = await directPost(endpoint, request, transientContext);
            lastError = null;
            break;
          } catch (error) {
            lastError = error;
            if (attempt < 2) await sleep(300 * (2 ** attempt) + Math.floor(Math.random() * 100));
          }
        }
      }
      if (!data) throw lastError || new Error('Doubao single-conversation request failed');
      const body = singleBody(data);
      if (!body) throw new Error('Doubao single response is missing pull_singe_chain_downlink_body');
      const ids = messagesFromSingle(data).map(message => message?.message_id).filter(Boolean).map(String);
      messageIds.push(...ids);
      pages.push({ kind: 'chain_page', cursor: String(anchorIndex), nextCursor: body.next_index ?? null, response: data });
      if (process.env.DOUBAO_PROGRESS === '1' && (pages.length === 2 || (pages.length - 1) % 25 === 0)) {
        process.stderr.write(`[doubao] conversation pages=${pages.length - 1} messages=${messageIds.length}\n`);
      }
      const result = guard.addPage({ messageIds: ids, hasMore: body.has_more, nextCursor: body.next_index });
      finalPagination = { ...result, next_index: body.next_index ?? null };
      if (result.stop) break;
      anchorIndex = Number(body.next_index);
      capturedData = null;
      await sleep(120);
    }

    const candidates = await this.resolveAttachmentCandidates(extractAttachmentCandidates(pages.map(page => page.response)));
    const downloaded = [];
    if (options.downloadAttachments !== false) {
      for (const candidate of candidates) {
        try {
          downloaded.push(await downloadAttachment(candidate));
        } catch (error) {
          downloaded.push({ ...publicReference(candidate), download_error: error.message });
        }
      }
    }

    return {
      collected_at: new Date().toISOString(),
      pages,
      metadata: {
        title: summary.title,
        createdAt: summary.created_at,
        updatedAt: summary.updated_at,
        contentFingerprint: summary.content_fingerprint,
        messageIds,
        attachments: candidates.map(publicReference),
        pagination: finalPagination,
      },
      attachments: downloaded,
      attachment_candidates: candidates,
    };
  }

  async resolveAttachmentCandidates(candidates) {
    await this.initialize();
    const endpoint = new URL(this.listEndpoint);
    endpoint.pathname = '/alice/message/get_file_url';
    const resolvedByUri = new Map();
    for (const kind of ['file', 'image']) {
      const items = candidates.filter(item => item.kind === kind && item.resource_uri);
      for (let offset = 0; offset < items.length; offset += 50) {
        const batch = items.slice(offset, offset + 50);
        const data = this.transientContext
          ? await directPlainPost(endpoint.toString(), { uris: batch.map(item => item.resource_uri), type: kind }, this.transientContext)
          : await plainPost(endpoint.toString(), { uris: batch.map(item => item.resource_uri), type: kind });
        for (const item of data?.data?.file_urls || []) {
          const url = item.main_url || item.back_url;
          if (item.uri && url) resolvedByUri.set(item.uri, url);
        }
      }
    }
    return candidates.map(candidate => ({
      ...candidate,
      download_url: resolvedByUri.get(candidate.resource_uri) || candidate.download_url,
    }));
  }
}

let live = null;

async function discoverConversations(options = {}) {
  live = new DoubaoLiveAdapter();
  return live.discoverConversations(options);
}

async function fetchConversationPage(conversationId, options = {}) {
  if (!live) throw new Error('discoverConversations must run before fetching conversation details');
  return live.collectConversation(conversationId, options);
}

async function extractAttachmentReferences(value) {
  return extractAttachmentCandidates(value).map(publicReference);
}

module.exports = {
  buildConversationEnvelope,
  discoverConversations,
  extractAttachmentReferences,
  fetchConversationPage,
  DoubaoLiveAdapter,
};
