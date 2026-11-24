import * as store from './lib/store.js';
import { scheduleSync, syncNow, whenIdle } from './lib/sync.js';
import { normalizeServerUrl } from './lib/remote.js';

const SYNC_ALARM = 'sync';
const SYNC_PERIOD_MINUTES = 15;

function armSyncAlarm() {
  browser.alarms.create(SYNC_ALARM, { periodInMinutes: SYNC_PERIOD_MINUTES });
}

browser.runtime.onStartup.addListener(() => {
  armSyncAlarm();
  syncNow();
});

browser.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === SYNC_ALARM) syncNow();
});

/** Saves settings from the options page; changing the server or token restarts sync from scratch. */
async function configure({ serverUrl, token }) {
  const next = {
    serverUrl: normalizeServerUrl(serverUrl),
    token: String(token ?? '').trim(),
  };
  await whenIdle();
  const previous = await store.getSettings();
  await store.setSettings(next);
  if (next.serverUrl !== previous.serverUrl || next.token !== previous.token) {
    await store.resetSync();
  }
  return { settings: next, result: await syncNow() };
}

const BADGE_OK = '#0e9f97';
const BADGE_ERROR = '#c0392b';
const BADGE_MS = 1600;

browser.runtime.onInstalled.addListener(async () => {
  armSyncAlarm();
  await browser.menus.removeAll();
  browser.menus.create({
    id: 'open-list',
    title: 'Open list in a tab',
    contexts: ['action'],
  });
  browser.menus.create({
    id: 'save-link',
    title: 'Save link to Pouch',
    contexts: ['link'],
  });
});

function flash(tabId, text, color) {
  browser.action.setBadgeBackgroundColor({ color, tabId });
  browser.action.setBadgeTextColor({ color: '#ffffff', tabId });
  browser.action.setBadgeText({ text, tabId });
  setTimeout(() => {
    browser.action.setBadgeText({ text: null, tabId }).catch(() => {});
  }, BADGE_MS);
}

async function saveAndFlash(tabId, page) {
  try {
    await store.save(page);
    flash(tabId, '✓', BADGE_OK);
    scheduleSync();
    return true;
  } catch (error) {
    console.warn('Not saved:', error.message);
    flash(tabId, '!', BADGE_ERROR);
    return false;
  }
}

// Clicking the address bar icon (or the keyboard shortcut) saves the current page.
// The icon switches to "saved" until the user navigates to another page.
browser.pageAction.onClicked.addListener(async (tab) => {
  const saved = await saveAndFlash(tab.id, {
    url: tab.url,
    title: tab.title,
    favicon: tab.favIconUrl,
  });
  if (saved) {
    browser.pageAction.setIcon({ tabId: tab.id, path: 'icons/saved.svg' });
    browser.pageAction.setTitle({ tabId: tab.id, title: 'Saved to Pouch' });
  }
});

browser.menus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === 'open-list') {
    browser.tabs.create({ url: browser.runtime.getURL('list/list.html') });
  } else if (info.menuItemId === 'save-link') {
    saveAndFlash(tab?.id, { url: info.linkUrl, title: info.linkText });
  }
});

// Requests from the list view.
browser.runtime.onMessage.addListener((message) => {
  switch (message?.type) {
    case 'list':
      return store.list();
    case 'update':
      return changed(store.update(message.id, message.patch));
    case 'remove':
      return changed(store.remove(message.id));
    case 'restore':
      return changed(store.restore(message.id));
    case 'sync':
      return syncNow();
    case 'configure':
      return configure(message.settings);
    case 'status':
      return Promise.all([store.getSettings(), store.getSyncState()]).then(
        ([settings, state]) => ({ settings, state }),
      );
    default:
      return undefined;
  }
});

async function changed(operation) {
  const result = await operation;
  scheduleSync();
  return result;
}
