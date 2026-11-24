const FALLBACK_ICON = browser.runtime.getURL('icons/globe.svg');
const TOAST_MS = 6000;

const listEl = document.getElementById('items');
const emptyEl = document.getElementById('empty');
const countEl = document.getElementById('count');
const searchEl = document.getElementById('search');
const toastEl = document.getElementById('toast');
const toastText = document.getElementById('toast-text');
const toastUndo = document.getElementById('toast-undo');
const rowTemplate = document.getElementById('row');
const pagerEl = document.getElementById('pager');
const pageInfoEl = document.getElementById('page-info');
const prevPageEl = document.getElementById('prev-page');
const nextPageEl = document.getElementById('next-page');

// Set on the options page; 0 means pagination is disabled.
const PAGE_SIZE_KEY = 'pageSize';

let items = [];
let pageSize = 0;
let page = 1;
let editingId = null;
let refreshPending = false;
let isPopup = true;
let toastTimer = null;
let undoId = null;

const send = (message) => browser.runtime.sendMessage(message);

function plural(count) {
  return count === 1 ? '1 link' : `${count} links`;
}

function displayUrl(url) {
  return url.replace(/^https?:\/\//, '').replace(/\/$/, '');
}

async function refresh() {
  if (editingId) {
    refreshPending = true;
    return;
  }
  refreshPending = false;
  items = await send({ type: 'list' });
  render();
}

function render() {
  const query = searchEl.value.trim().toLowerCase();
  const visible = query
    ? items.filter(
        (item) =>
          item.title.toLowerCase().includes(query) || item.url.toLowerCase().includes(query),
      )
    : items;

  const pageCount = pageSize > 0 ? Math.max(1, Math.ceil(visible.length / pageSize)) : 1;
  page = Math.min(Math.max(page, 1), pageCount);
  const shown = pageSize > 0 ? visible.slice((page - 1) * pageSize, page * pageSize) : visible;

  listEl.replaceChildren(...shown.map(buildRow));
  countEl.textContent = items.length ? plural(items.length) : '';

  pagerEl.hidden = pageCount <= 1;
  pageInfoEl.textContent = `Page ${page} of ${pageCount}`;
  prevPageEl.disabled = page <= 1;
  nextPageEl.disabled = page >= pageCount;

  emptyEl.hidden = visible.length > 0;
  emptyEl.textContent = items.length
    ? 'Nothing matches your search.'
    : 'The list is empty. Click the bookmark icon in the address bar to save the current page.';
}

function buildRow(item) {
  const row = rowTemplate.content.firstElementChild.cloneNode(true);
  const view = row.querySelector('.view');
  const link = row.querySelector('.link');
  const favicon = row.querySelector('.favicon');
  const editor = row.querySelector('.editor');
  const error = row.querySelector('.error');

  link.href = item.url;
  link.title = item.url;
  row.querySelector('.title').textContent = item.title;
  row.querySelector('.url').textContent = displayUrl(item.url);

  favicon.addEventListener('error', () => {
    if (favicon.src !== FALLBACK_ICON) favicon.src = FALLBACK_ICON;
  });
  favicon.src = item.favicon || FALLBACK_ICON;

  // In the popup a link won't open a tab on its own — we do it manually.
  const open = (event) => {
    if (!isPopup || event.button > 1) return;
    event.preventDefault();
    const background = event.button === 1 || event.ctrlKey || event.metaKey;
    browser.tabs.create({ url: item.url, active: !background });
    if (!background) window.close();
  };
  link.addEventListener('click', open);
  link.addEventListener('auxclick', open);

  const closeEditor = () => {
    editingId = null;
    editor.hidden = true;
    view.hidden = false;
    if (refreshPending) refresh();
  };

  row.querySelector('.edit').addEventListener('click', () => {
    if (editingId) return;
    editingId = item.id;
    editor.elements.title.value = item.title;
    editor.elements.url.value = item.url;
    error.hidden = true;
    view.hidden = true;
    editor.hidden = false;
    editor.elements.title.focus();
    editor.elements.title.select();
  });

  row.querySelector('.cancel').addEventListener('click', closeEditor);

  editor.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      closeEditor();
    }
  });

  editor.addEventListener('submit', async (event) => {
    event.preventDefault();
    try {
      await send({
        type: 'update',
        id: item.id,
        patch: { title: editor.elements.title.value, url: editor.elements.url.value },
      });
      refreshPending = true;
      closeEditor();
    } catch (failure) {
      error.textContent = failure.message;
      error.hidden = false;
    }
  });

  row.querySelector('.delete').addEventListener('click', async () => {
    await send({ type: 'remove', id: item.id });
    showUndo(item);
  });

  return row;
}

function showUndo(item) {
  undoId = item.id;
  toastText.textContent = `Deleted: ${item.title}`;
  toastEl.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(hideToast, TOAST_MS);
}

function hideToast() {
  toastEl.hidden = true;
  undoId = null;
}

toastUndo.addEventListener('click', async () => {
  const id = undoId;
  hideToast();
  if (id) await send({ type: 'restore', id });
});

searchEl.addEventListener('input', () => {
  page = 1;
  if (!editingId) render();
});

function goToPage(next) {
  if (editingId) return;
  page = next;
  render();
  listEl.scrollTop = 0;
  if (!isPopup) window.scrollTo(0, 0);
}

prevPageEl.addEventListener('click', () => goToPage(page - 1));
nextPageEl.addEventListener('click', () => goToPage(page + 1));

function setPageSize(value) {
  const size = Number(value);
  pageSize = Number.isInteger(size) && size > 0 ? size : 0;
}

document.getElementById('open-tab').addEventListener('click', () => {
  browser.tabs.create({ url: browser.runtime.getURL('list/list.html') });
  window.close();
});

document.getElementById('open-options').addEventListener('click', () => {
  browser.runtime.openOptionsPage();
  if (isPopup) window.close();
});

// Opening the list is a good moment to pull changes from the server;
// new items will appear on their own thanks to the listener below.
send({ type: 'sync' }).catch(() => {});

browser.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local') return;
  if (changes[PAGE_SIZE_KEY]) {
    setPageSize(changes[PAGE_SIZE_KEY].newValue);
    page = 1;
    if (!changes.items && !editingId) render();
  }
  if (changes.items) refresh();
});

browser.tabs.getCurrent().then((tab) => {
  isPopup = !tab;
  if (!isPopup) document.documentElement.classList.add('tab');
});

browser.storage.local
  .get({ [PAGE_SIZE_KEY]: 0 })
  .then((data) => setPageSize(data[PAGE_SIZE_KEY]))
  .catch(() => {})
  .finally(refresh);
