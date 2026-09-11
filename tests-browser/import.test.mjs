import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { selectSite, importSelected } from '../browser-extension/import.mjs';

const tab = { id: 12, url: 'https://example.com/account?private=query', incognito: false };
const cookie = { name: 'fixture', value: 'synthetic', domain: 'example.com', path: '/', hostOnly: true,
  httpOnly: true, secure: true, sameSite: 'lax', storeId: '0', session: true };
function fixture({ granted = true, changed = false, cookies = [cookie] } = {}) {
  const calls = [];
  const api = {
    tabs: { get: async () => changed ? { ...tab, url: 'https://other.example/' } : tab },
    permissions: {
      contains: async p => { calls.push(['contains', p]); return false; },
      request: async p => { calls.push(['permission', p]); return granted; },
      remove: async p => { calls.push(['remove', p]); return true; }
    },
    cookies: { getAll: async p => { calls.push(['cookies', p]); return cookies; } },
    runtime: { sendNativeMessage: async (host, request) => { calls.push(['native', host, request]); return { success: true, sessions: [{ id: request.snapshot.id }] }; } }
  };
  return { api, calls };
}
test('selection never reads Cookies, rejects incognito and non-HTTPS', () => {
  assert.equal(selectSite(tab).origin, 'https://example.com');
  assert.throws(() => selectSite({ ...tab, incognito: true }));
  assert.throws(() => selectSite({ ...tab, url: 'file:///tmp/fixture' }));
});
test('exact-host permission precedes a selected-site read; transport is whitelisted and permission released', async () => {
  const { api, calls } = fixture();
  await importSelected(api, selectSite(tab), 'Synthetic fixture');
  assert.deepEqual(calls.map(c => c[0]), ['permission', 'cookies', 'native', 'remove']);
  assert.deepEqual(calls[0][1], { origins: ['https://example.com/*'] });
  assert.deepEqual(calls[1][1], { url: 'https://example.com/', path: '/' });
  assert.equal(calls[2][1], 'com.keykeeper.browser_sessions');
  assert.equal(calls[2][2].snapshot.cookies[0].value, cookie.value);
  assert.equal(calls[2][2].snapshot.cookies[0].storeId, undefined);
  assert.equal(calls[2][2].snapshot.origin.includes('private'), false);
});
test('deny and navigation race never read Cookies', async () => {
  for (const options of [{ granted: false }, { changed: true }]) {
    const { api, calls } = fixture(options);
    await assert.rejects(importSelected(api, selectSite(tab), 'Synthetic'));
    assert.equal(calls.some(c => c[0] === 'cookies'), false);
  }
});
test('unsupported, foreign, oversized and ambiguous input never reaches native host', async () => {
  for (const cookies of [[], [{ ...cookie, partitionKey: {} }], [{ ...cookie, sameSite: 'no_restriction' }],
    [{ ...cookie, domain: 'other.example' }], [{ ...cookie, value: 'x'.repeat(4097) }], [cookie, cookie]]) {
    const { api, calls } = fixture({ cookies });
    await assert.rejects(importSelected(api, selectSite(tab), 'Synthetic'));
    assert.equal(calls.some(c => c[0] === 'native'), false);
    assert.equal(calls.at(-1)[0], 'remove');
  }
});
test('existing exact permission is preserved and arbitrary native output is not returned', async () => {
  const { api, calls } = fixture();
  api.runtime.sendNativeMessage = async () => ({ success: true, unexpected: 'must-not-escape' });
  assert.deepEqual(await importSelected(api, selectSite(tab), 'Synthetic', true), { success: true });
  assert.equal(calls.some(c => c[0] === 'remove'), false);
});
test('manifest has no blanket initial site access, content injection or action-popup lifetime trap', () => {
  const manifest = JSON.parse(fs.readFileSync(new URL('../browser-extension/manifest.json', import.meta.url)));
  assert.deepEqual(manifest.permissions, ['activeTab', 'cookies', 'nativeMessaging']);
  assert.deepEqual(manifest.optional_host_permissions, ['https://*/*']);
  for (const key of ['host_permissions', 'content_scripts', 'externally_connectable', 'web_accessible_resources']) assert.equal(manifest[key], undefined);
  assert.equal(manifest.action.default_popup, undefined);
  assert.equal(manifest.incognito, 'not_allowed');
});
