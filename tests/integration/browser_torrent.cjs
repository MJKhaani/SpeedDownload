// Exercise the shared WebExtension background handlers without a live browser.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { TextEncoder } = require('node:util');
const { webcrypto } = require('node:crypto');
const handlers = {};
const messages = [];
const downloadActions = [];
const browser = {
  runtime: {
    onInstalled: { addListener() {} },
    async sendNativeMessage(_, request) {
      messages.push(request);
      return { version: 1, ok: true, dialog_opened: true };
    },
  },
  scripting: { async executeScript() { return [{ result: ['https://example.test/one.zip', 'https://example.test/two.zip'] }]; } },
  contextMenus: { onClicked: { addListener(handler) { handlers.click = handler; } } },
  downloads: {
    onCreated: { addListener(handler) { handlers.download = handler; } },
    async pause(id) { downloadActions.push(['pause', id]); },
    async cancel(id) { downloadActions.push(['cancel', id]); },
    async resume(id) { downloadActions.push(['resume', id]); },
  },
  action: { async setBadgeBackgroundColor() {}, async setBadgeText() {} },
  storage: { local: { async get() { return { automaticGrab: true }; }, async set() {} } },
};
const iconFolders = ['extensions/firefox', 'extensions/chrome'];
if (fs.existsSync('dist/SpeedDownload-Chrome-extension/manifest.json')) iconFolders.push('dist/SpeedDownload-Chrome-extension');
for (const folder of iconFolders) {
  const manifest = JSON.parse(fs.readFileSync(`${folder}/manifest.json`, 'utf8'));
  for (const size of [16, 32, 48, 128]) {
    const assets = folder === 'extensions/chrome' ? 'extensions/firefox' : folder;
    const icon = fs.readFileSync(`${assets}/${manifest.icons[size]}`);
    assert.equal(icon.readUInt32BE(16), size);
    assert.equal(icon.readUInt32BE(20), size);
    assert.equal(manifest.action.default_icon[size], manifest.icons[size]);
  }
}
vm.runInNewContext(fs.readFileSync('extensions/firefox/background.js', 'utf8'), { browser, URL, TextEncoder, crypto: webcrypto, console: { error() {} } });
(async () => {
  await handlers.click({ menuItemId: 'speed-download-link', linkUrl: 'https://example.test/test.torrent?token=example' }, { id: 1 });
  assert.equal(messages.pop().action, 'torrent');
  await handlers.click({ menuItemId: 'speed-download-link', linkUrl: 'magnet:?xt=urn:btih:' + 'a'.repeat(40) }, { id: 1 });
  assert.equal(messages.pop().action, 'torrent');
  await handlers.download({ id: 7, state: 'in_progress', url: 'https://example.test/download?id=7', filename: '/Downloads/test.torrent', mime: 'application/octet-stream' });
  assert.equal(messages.pop().action, 'torrent');
  assert.deepEqual(downloadActions.splice(0), [['pause', 7], ['cancel', 7]]);
  await handlers.download({ id: 8, state: 'in_progress', url: 'https://example.test/download?id=8', filename: '/Downloads/download', mime: 'application/x-bittorrent' });
  assert.equal(messages.pop().action, 'torrent');
  await handlers.click({ menuItemId: 'speed-download-link', linkUrl: 'https://example.test/file.zip' }, { id: 1 });
  assert.equal(messages.pop().action, 'add');
  const before = messages.length;
  await handlers.click({ menuItemId: 'speed-download-selection', frameId: 0 }, { id: 1 });
  assert.equal(messages.length, before + 1);
  const batch = messages.pop();
  assert.equal(batch.action, 'batch');
  assert.equal(batch.urls.length, 2);
  assert.ok(!fs.readFileSync('src/browser_host.zig', 'utf8').includes('ipc/client.zig'));
  browser.runtime.sendNativeMessage = async () => { throw new Error('Unavailable'); };
  downloadActions.length = 0;
  await handlers.download({ id: 9, state: 'in_progress', url: 'https://example.test/file.torrent', filename: 'file.torrent' });
  assert.deepEqual(downloadActions, [['pause', 9], ['resume', 9]]);
  console.log('PASS: client-only single/batch/torrent routing, filename/MIME interception, and browser fallback');
})().catch(error => { console.error(error); process.exitCode = 1; });
