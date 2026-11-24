// Data layer. The background script is the only writer — the list view sends it
// messages, so writes never race each other.
//
// The record model is ready for server sync from the start:
//   id         – UUID assigned locally (stable across devices)
//   url, title, favicon
//   createdAt  – ms since the epoch
//   updatedAt  – ms since the epoch; used to resolve conflicts (newer wins)
//   deletedAt  – null or the deletion time (a "tombstone", so the deletion can
//                propagate to the server and other devices)
//   dirty      – true while the change has not been sent to the server yet

const ITEMS_KEY = 'items';
const SYNC_KEY = 'sync';
const SETTINGS_KEY = 'settings';

let chain = Promise.resolve();

/** Runs read–modify–write operations one after another. */
function locked(fn) {
  const run = chain.then(fn);
  chain = run.catch(() => {});
  return run;
}

async function readAll() {
  const data = await browser.storage.local.get({ [ITEMS_KEY]: [] });
  return data[ITEMS_KEY];
}

function writeAll(items) {
  return browser.storage.local.set({ [ITEMS_KEY]: items });
}

function touch(item) {
  item.updatedAt = Date.now();
  item.dirty = true;
}

export function normalizeUrl(raw) {
  let parsed;
  try {
    parsed = new URL(String(raw).trim());
  } catch {
    throw new Error('Invalid page address.');
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error('Only http and https addresses can be saved.');
  }
  return parsed.href;
}

function cleanFavicon(raw) {
  return typeof raw === 'string' && /^(https?:|data:image\/)/i.test(raw) ? raw : '';
}

function cleanTitle(raw, url) {
  const title = String(raw ?? '').trim();
  return title || url;
}

/** Active (not deleted) items, newest first. */
export async function list() {
  const items = await readAll();
  return items
    .filter((item) => !item.deletedAt)
    .sort((a, b) => b.createdAt - a.createdAt);
}

/**
 * Adds a page. If the address is already on the list, refreshes its title and icon
 * instead of creating a duplicate.
 * @returns {Promise<{item: object, existed: boolean}>}
 */
export function save({ url, title, favicon }) {
  return locked(async () => {
    const href = normalizeUrl(url);
    const items = await readAll();
    const now = Date.now();
    let item = items.find((candidate) => candidate.url === href);
    const existed = Boolean(item && !item.deletedAt);

    if (item) {
      if (title) item.title = cleanTitle(title, href);
      if (cleanFavicon(favicon)) item.favicon = cleanFavicon(favicon);
      if (item.deletedAt) {
        item.deletedAt = null;
        item.createdAt = now;
      }
    } else {
      item = {
        id: crypto.randomUUID(),
        url: href,
        title: cleanTitle(title, href),
        favicon: cleanFavicon(favicon),
        createdAt: now,
        updatedAt: now,
        deletedAt: null,
        dirty: true,
      };
      items.push(item);
    }
    touch(item);
    await writeAll(items);
    return { item, existed };
  });
}

function mutate(id, change) {
  return locked(async () => {
    const items = await readAll();
    const item = items.find((candidate) => candidate.id === id);
    if (!item) throw new Error('Item not found.');
    change(item, items);
    touch(item);
    await writeAll(items);
    return item;
  });
}

export function update(id, patch) {
  return mutate(id, (item, items) => {
    if (patch.url !== undefined) {
      const href = normalizeUrl(patch.url);
      const clash = items.some(
        (other) => other.id !== id && !other.deletedAt && other.url === href,
      );
      if (clash) throw new Error('This address is already on the list.');
      if (href !== item.url) item.favicon = '';
      item.url = href;
    }
    if (patch.title !== undefined) item.title = cleanTitle(patch.title, item.url);
  });
}

export function remove(id) {
  return mutate(id, (item) => {
    item.deletedAt = Date.now();
  });
}

export function restore(id) {
  return mutate(id, (item) => {
    item.deletedAt = null;
  });
}

// ---------------------------------------------------------------------------
// Sync backend — used by lib/sync.js.
// ---------------------------------------------------------------------------

/** Records (tombstones included) waiting to be sent. */
export async function pending() {
  return (await readAll()).filter((item) => item.dirty);
}

/**
 * Marks records as sent. A record changed while being sent
 * (different updatedAt) stays "dirty". Sent tombstones are removed for good.
 * @param {Array<{id: string, updatedAt: number}>} sent
 */
export function markSynced(sent) {
  return locked(async () => {
    const stamps = new Map(sent.map((entry) => [entry.id, entry.updatedAt]));
    const items = await readAll();
    const kept = items.filter((item) => {
      if (stamps.get(item.id) !== item.updatedAt) return true;
      item.dirty = false;
      return !item.deletedAt;
    });
    await writeAll(kept);
  });
}

/** Merges records from the server: for each id the newer updatedAt wins. */
export function applyRemote(remoteItems) {
  return locked(async () => {
    const items = await readAll();
    const byId = new Map(items.map((item) => [item.id, item]));
    for (const remote of remoteItems) {
      const local = byId.get(remote.id);
      if (local && local.updatedAt >= remote.updatedAt) continue;
      if (!local && remote.deletedAt) continue;
      byId.set(remote.id, { ...remote, dirty: false });
    }

    // The same page saved independently on two devices has two different ids.
    // The older entry is kept (on a tie, the one with the smaller id), so every device
    // picks the same one; the others are deleted and that deletion goes to the server.
    const keepers = new Map();
    for (const item of byId.values()) {
      if (item.deletedAt) continue;
      const keeper = keepers.get(item.url);
      if (!keeper) {
        keepers.set(item.url, item);
        continue;
      }
      const itemWins =
        item.createdAt < keeper.createdAt ||
        (item.createdAt === keeper.createdAt && item.id < keeper.id);
      const loser = itemWins ? keeper : item;
      if (itemWins) keepers.set(item.url, item);
      loser.deletedAt = Date.now();
      touch(loser);
    }

    await writeAll([...byId.values()].filter((item) => !item.deletedAt || item.dirty));
  });
}

export async function getSyncState() {
  const data = await browser.storage.local.get({ [SYNC_KEY]: {} });
  return { cursor: null, lastSyncAt: null, lastError: null, ...data[SYNC_KEY] };
}

export async function patchSyncState(patch) {
  const state = { ...(await getSyncState()), ...patch };
  await browser.storage.local.set({ [SYNC_KEY]: state });
  return state;
}

/**
 * Prepares data for the first sync with a (new) server:
 * everything is queued for sending and pulling starts from the beginning.
 */
export function resetSync() {
  return locked(async () => {
    const items = await readAll();
    for (const item of items) item.dirty = true;
    await writeAll(items);
    await browser.storage.local.set({
      [SYNC_KEY]: { cursor: null, lastSyncAt: null, lastError: null },
    });
  });
}

// ---------------------------------------------------------------------------
// Settings (options page).
// ---------------------------------------------------------------------------

export async function getSettings() {
  const data = await browser.storage.local.get({ [SETTINGS_KEY]: {} });
  return { serverUrl: '', token: '', ...data[SETTINGS_KEY] };
}

export function setSettings(settings) {
  return browser.storage.local.set({ [SETTINGS_KEY]: settings });
}
