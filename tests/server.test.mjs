import test from 'node:test';
import assert from 'node:assert/strict';
import { startServer, allowedPath } from '../scripts/serve.mjs';
import { validateBrowserConfig } from '../scripts/config.mjs';

test('route allowlist rejects traversal, dotfiles and non-portal files', () => {
  for (const input of ['/.env', '/package.json', '/supabase/config.toml', '/scripts/config.mjs', '/%2e%2e/.env', '/src/%2e%2e/.env', '/src/..\\.env']) assert.equal(allowedPath(input), null);
  assert.equal(allowedPath('/src/main.js'), 'src/main.js');
});
test('static server serves the portal and refuses configuration files and traversal', async t => {
  const server = await startServer({ port: 0 });
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    let page;
    try { page = await fetch(base); }
    catch (error) { if (error.cause?.code === 'EACCES') { t.skip('This runtime denies localhost connections; run this integration test in CI.'); return; } throw error; }
    assert.equal(page.status, 200); assert.match(await page.text(), /PaySME Vouchers/);
    const source = await fetch(base + '/src/main.js'); assert.match(source.headers.get('content-type'), /javascript/);
    for (const input of ['/.env', '/package.json', '/supabase/config.toml', '/scripts/config.mjs', '/%2e%2e/.env', '/src/%2e%2e/.env']) assert.equal((await fetch(base + input)).status, 404);
    assert.equal((await fetch(base, { method: 'POST' })).status, 405);
    assert.equal(allowedPath('/src/%2e%2e/.env'), null);
    assert.equal(allowedPath('/src/..\\.env'), null);
  } finally { await new Promise(resolve => server.close(resolve)); }
});
test('browser configuration refuses secret keys, cross-project JWTs and URL credentials', () => {
  const token = claims => `header.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.signature`;
  assert.throws(() => validateBrowserConfig('https://demo.supabase.co', 'sb_secret_never_ship'));
  assert.throws(() => validateBrowserConfig('https://demo.supabase.co', token({ role: 'service_role' })));
  assert.throws(() => validateBrowserConfig('https://demo.supabase.co', token({ role: 'anon', ref: 'other' })));
  assert.throws(() => validateBrowserConfig('https://user:pass@demo.supabase.co', 'sb_publishable_demo'));
  assert.equal(validateBrowserConfig('https://demo.supabase.co', token({ role: 'anon', ref: 'demo' })).supabaseUrl, 'https://demo.supabase.co');
});
