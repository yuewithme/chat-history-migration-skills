'use strict';

const { command } = require('./lib/webbridge');

const SESSION = 'doubao-local-backup';
const URL = 'https://www.doubao.com/chat/';

(async () => {
  let tab;
  try {
    tab = await command('find_tab', { url: 'https://www.doubao.com', active: true }, SESSION);
  } catch {
    tab = await command('navigate', { url: URL, newTab: true, group_title: '豆包备份施工' }, SESSION);
  }

  const status = await command('evaluate', {
    code: `(() => {
      const visible = el => !!(el && (el.offsetWidth || el.offsetHeight || el.getClientRects().length));
      const loginControls = [...document.querySelectorAll('button,a')].filter(el => visible(el) && /^(登录|立即登录|扫码登录|手机号登录)$/.test((el.textContent || '').trim()));
      const chatLinks = [...document.querySelectorAll('a[href*="/chat/"]')];
      const conversationMarkers = document.querySelectorAll('[data-testid*="conversation"],[class*="conversation"],[class*="chat-list"]');
      return {
        origin: location.origin,
        pathname: location.pathname,
        title: document.title,
        ready_state: document.readyState,
        visible_login_controls: loginControls.length,
        chat_link_count: chatLinks.length,
        conversation_marker_count: conversationMarkers.length
      };
    })()`,
  }, SESSION);

  console.log(JSON.stringify({
    tab: { url: tab.url || URL, borrowed: tab.borrowed === true },
    page: status.value,
    requires_user_confirmation: true,
  }, null, 2));
})().catch(error => {
  console.error(`Doubao probe failed: ${error.message}`);
  process.exitCode = 1;
});
