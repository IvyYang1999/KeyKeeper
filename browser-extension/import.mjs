// Secret-bearing objects stay in this call's memory, never DOM, storage or logs.
export class ImportError extends Error { constructor(code) { super(code); this.code = code; } }
const fail = code => { throw new ImportError(code); };
const size = value => new TextEncoder().encode(value).length;
const validHost = host => host.length <= 253 && host.split('.').every(part => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(part));
export function selectSite(tab) {
  let url;
  try { url = new URL(tab.url); } catch { fail('site'); }
  if (tab.incognito || !Number.isInteger(tab.id) || url.protocol !== 'https:' || url.username || url.password || !validHost(url.hostname)) fail('site');
  return { tabId: tab.id, origin: url.origin, host: url.hostname, permission: { origins: [`https://${url.hostname}/*`] } };
}
function convertCookies(cookies, site) {
  if (!Array.isArray(cookies) || cookies.length < 1 || cookies.length > 64) fail('unsupported');
  const names = new Set();
  return cookies.map(c => {
    const domain = typeof c.domain === 'string' ? c.domain.replace(/^\./, '') : '';
    if (c.partitionKey || c.path !== '/' || !validHost(domain)
        || !(domain === site.host || (!c.hostOnly && site.host.endsWith('.' + domain)))
        || (c.hostOnly && c.domain.startsWith('.')) || typeof c.hostOnly !== 'boolean'
        || typeof c.secure !== 'boolean' || typeof c.httpOnly !== 'boolean'
        || typeof c.name !== 'string' || !/^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,256}$/.test(c.name)
        || typeof c.value !== 'string' || size(c.value) > 4096 || !/^[\x21\x23-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E]*$/.test(c.value)
        || !['lax', 'strict', 'unspecified'].includes(c.sameSite) || names.has(c.name)
        || ((c.name.startsWith('__Host-') || c.name.startsWith('__Secure-')) && !c.secure)
        || (c.name.startsWith('__Host-') && !c.hostOnly)
        || (c.expirationDate !== undefined && (!Number.isFinite(c.expirationDate) || c.expirationDate <= Date.now() / 1000))) fail('unsupported');
    names.add(c.name);
    return { name: c.name, value: c.value, domain: c.domain, path: '/', hostOnly: c.hostOnly,
      secure: c.secure, httpOnly: c.httpOnly, sameSite: c.sameSite, expirationDate: c.expirationDate ?? null };
  });
}
export async function importSelected(api, site, label, previouslyGranted = false) {
  if (typeof label !== 'string' || !label.trim() || size(label) > 160 || /[\x00-\x1F\x7F]/.test(label)) fail('label');
  // Call synchronously from the click handler, before any await: Chrome requires a user gesture.
  const permission = api.permissions.request(site.permission);
  let acquired = false;
  try {
    if (!await permission) fail('denied');
    acquired = !previouslyGranted;
    const current = selectSite(await api.tabs.get(site.tabId));
    if (current.origin !== site.origin) fail('changed');
    const cookies = convertCookies(await api.cookies.getAll({ url: site.origin + '/', path: '/' }), site);
    const snapshot = { id: crypto.randomUUID(), origin: site.origin, label: label.trim(), cookies };
    const request = { action: 'save', snapshot };
    if (size(JSON.stringify(request)) > 131072) fail('unsupported');
    const response = await api.runtime.sendNativeMessage('com.keykeeper.browser_sessions', request);
    if (response?.success !== true) fail(response?.errorCode === 'denied' ? 'denied' : response?.errorCode === 'unsupported' ? 'unsupported' : 'uncertain');
    // Intentionally discard the response's other fields, including any unexpected data.
    return { success: true };
  } catch (error) {
    if (error instanceof ImportError) throw error;
    fail('uncertain');
  } finally {
    if (acquired) {
      try { if (!await api.permissions.remove(site.permission)) fail('permission'); }
      catch { fail('permission'); }
    }
  }
}
