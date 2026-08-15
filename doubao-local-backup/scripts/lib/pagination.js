'use strict';

function uniqueStableIds(values) {
  return [...new Set((values || []).filter(value => typeof value === 'string' && value))];
}

function createPaginationGuard(maxPages = 10000) {
  if (!Number.isInteger(maxPages) || maxPages < 1) throw new Error('maxPages must be a positive integer');
  const seenIds = new Set();
  let pages = 0;
  let consecutiveEmptyGrowth = 0;

  return {
    addPage({ messageIds = [], hasMore = null, nextCursor = null }) {
      pages++;
      let added = 0;
      for (const id of uniqueStableIds(messageIds)) {
        if (!seenIds.has(id)) {
          seenIds.add(id);
          added++;
        }
      }
      consecutiveEmptyGrowth = added === 0 ? consecutiveEmptyGrowth + 1 : 0;
      let stopReason = null;
      if (pages >= maxPages) stopReason = 'maximum page guard reached';
      else if (hasMore === false) stopReason = 'provider reported completion';
      else if (!nextCursor && hasMore !== true) stopReason = 'no next cursor';
      else if (consecutiveEmptyGrowth >= 2) stopReason = 'two consecutive pages added no stable message IDs';
      return { added, pages, uniqueMessages: seenIds.size, stop: stopReason !== null, stopReason };
    },
    snapshot() {
      return { pages, consecutiveEmptyGrowth, messageIds: [...seenIds] };
    },
  };
}

module.exports = { createPaginationGuard, uniqueStableIds };
