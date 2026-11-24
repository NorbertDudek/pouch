const form = document.getElementById('form');
const urlEl = document.getElementById('server-url');
const tokenEl = document.getElementById('token');
const toggleEl = document.getElementById('toggle-token');
const saveEl = document.getElementById('save');
const insecureEl = document.getElementById('insecure');
const statusEl = document.getElementById('status');
const pageSizeEl = document.getElementById('page-size');

const send = (message) => browser.runtime.sendMessage(message);

// Page size is a display preference only, so the options page stores it directly
// (the background script stays the only writer of the saved links).
const PAGE_SIZE_KEY = 'pageSize';
const PAGE_SIZES = ['0', '10', '20', '50'];

pageSizeEl.addEventListener('change', () => {
  browser.storage.local.set({ [PAGE_SIZE_KEY]: Number(pageSizeEl.value) });
});

browser.storage.local.get({ [PAGE_SIZE_KEY]: 0 }).then((data) => {
  const value = String(data[PAGE_SIZE_KEY]);
  pageSizeEl.value = PAGE_SIZES.includes(value) ? value : '0';
});

function setStatus(kind, text) {
  statusEl.className = kind;
  statusEl.textContent = text;
}

function formatTime(timestamp) {
  return new Date(timestamp).toLocaleString('en-US', { dateStyle: 'medium', timeStyle: 'short' });
}

function updateInsecureWarning() {
  let insecure = false;
  try {
    const url = new URL(urlEl.value.trim());
    const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
    insecure = url.protocol === 'http:' && !local;
  } catch {
    // empty or incomplete address — no warning
  }
  insecureEl.hidden = !insecure;
}

function showState(settings, state) {
  if (!settings.serverUrl) {
    setStatus('muted', 'Sync is off — links are kept in this browser only.');
  } else if (state.lastError) {
    setStatus('error', `Last attempt failed: ${state.lastError}`);
  } else if (state.lastSyncAt) {
    setStatus('ok', `Last sync: ${formatTime(state.lastSyncAt)}`);
  } else {
    setStatus('muted', 'Not synced yet.');
  }
}

urlEl.addEventListener('input', updateInsecureWarning);

toggleEl.addEventListener('click', () => {
  const reveal = tokenEl.type === 'password';
  tokenEl.type = reveal ? 'text' : 'password';
  toggleEl.textContent = reveal ? 'Hide' : 'Show';
});

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  saveEl.disabled = true;
  setStatus('muted', 'Saving and connecting to the server…');
  try {
    const { settings, result } = await send({
      type: 'configure',
      settings: { serverUrl: urlEl.value, token: tokenEl.value },
    });
    urlEl.value = settings.serverUrl;
    updateInsecureWarning();
    if (!result.enabled) {
      setStatus('muted', 'Saved. Sync is off — links are kept in this browser only.');
    } else if (result.ok) {
      setStatus('ok', `Saved. Synced: ${formatTime(result.lastSyncAt)}`);
    } else {
      setStatus('error', `Saved, but sync failed: ${result.error}`);
    }
  } catch (error) {
    setStatus('error', error.message);
  } finally {
    saveEl.disabled = false;
  }
});

const { settings, state } = await send({ type: 'status' });
urlEl.value = settings.serverUrl;
tokenEl.value = settings.token;
updateInsecureWarning();
showState(settings, state);
