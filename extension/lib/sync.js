// Sync with a self-hosted server (address and token from the add-on options).
// With no address set, everything works locally only.
//
// Flow: push local changes (deletions included), then pull changes
// from the server since the last stored cursor.

import * as store from './store.js';
import { createProvider } from './remote.js';

const DEBOUNCE_MS = 2000;
const PUSH_BATCH = 50;

let timer = null;
let running = null;

/** Syncs shortly after a change — several quick changes go out in one request. */
export function scheduleSync() {
  clearTimeout(timer);
  timer = setTimeout(syncNow, DEBOUNCE_MS);
}

/** Waits for the running sync to finish (if one is running). */
export function whenIdle() {
  return running ?? Promise.resolve();
}

/**
 * Never throws; returns
 * {enabled: false} or {enabled: true, ok, error?, lastSyncAt?}.
 */
export function syncNow() {
  running ??= runSync().finally(() => {
    running = null;
  });
  return running;
}

async function runSync() {
  const settings = await store.getSettings();
  if (!settings.serverUrl) return { enabled: false };

  try {
    const provider = createProvider(settings);

    const outgoing = await store.pending();
    for (let start = 0; start < outgoing.length; start += PUSH_BATCH) {
      const batch = outgoing.slice(start, start + PUSH_BATCH);
      await provider.push(batch.map(({ dirty, ...record }) => record));
      await store.markSynced(batch);
    }

    let page;
    do {
      const { cursor } = await store.getSyncState();
      page = await provider.pull(cursor);
      await store.applyRemote(page.items);
      await store.patchSyncState({ cursor: page.cursor });
    } while (page.more);

    const lastSyncAt = Date.now();
    await store.patchSyncState({ lastSyncAt, lastError: null });
    return { enabled: true, ok: true, lastSyncAt };
  } catch (error) {
    console.warn('Sync failed:', error);
    await store.patchSyncState({ lastError: error.message });
    return { enabled: true, ok: false, error: error.message };
  }
}
