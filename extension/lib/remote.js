// Client for the PHP server (server/index.php). The server sends CORS headers,
// so the add-on does not need host permissions for any site.

const TIMEOUT_MS = 20000;

/** Normalizes the entered address into the form requests are sent to. */
export function normalizeServerUrl(raw) {
  const text = String(raw ?? '').trim();
  if (!text) return '';
  let parsed;
  try {
    parsed = new URL(text);
  } catch {
    throw new Error('Invalid server address.');
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error('The server address must start with https:// or http://.');
  }
  parsed.search = '';
  parsed.hash = '';
  // A directory address without a trailing "/" would end in a redirect that drops the POST.
  if (!parsed.pathname.endsWith('/') && !parsed.pathname.endsWith('.php')) {
    parsed.pathname += '/';
  }
  return parsed.href;
}

export function createProvider({ serverUrl, token }) {
  const endpoint = normalizeServerUrl(serverUrl);

  async function request(method, params, body) {
    const url = new URL(endpoint);
    for (const [key, value] of Object.entries(params ?? {})) {
      url.searchParams.set(key, value);
    }

    let response;
    try {
      response = await fetch(url, {
        method,
        headers: {
          'X-Schowek-Token': token ?? '',
          ...(body ? { 'Content-Type': 'application/json' } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
        cache: 'no-store',
        credentials: 'omit',
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
    } catch {
      throw new Error('Cannot connect to the server.');
    }

    let data = null;
    try {
      data = await response.json();
    } catch {
      // response is not JSON — handled below
    }
    if (response.status === 401) throw new Error('The server rejected the token.');
    if (!data || typeof data !== 'object') {
      throw new Error(`No Pouch server responds at this address (HTTP ${response.status}).`);
    }
    if (!response.ok || data.ok !== true) {
      throw new Error(typeof data.error === 'string' ? data.error : `Server error (HTTP ${response.status}).`);
    }
    return data;
  }

  return {
    async ping() {
      const data = await request('GET', { ping: '1' });
      if (data.app !== 'schowek') throw new Error('No Pouch server responds at this address.');
    },
    push(items) {
      return request('POST', null, { items });
    },
    async pull(cursor) {
      const data = await request('GET', { since: String(cursor ?? 0) });
      if (!Array.isArray(data.items)) throw new Error('Invalid server response.');
      return { items: data.items, cursor: data.cursor, more: data.more === true };
    },
  };
}
