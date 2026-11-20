#!/usr/bin/env node
// Exercise the actual dashboard script without a server, browser or dependencies.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const dashboard = fs.readFileSync(path.join(__dirname, '../server/admin-ui/src/dashboard.js'), 'utf8');
const script = dashboard
  .replace(/^import .* from 'vue';$/m, 'const { ref, computed, onMounted } = Vue;')
  .replace('export function', 'function') + '\napp = setupDashboard();';
let app, response = {ok: false, status: 500}, copySucceeds = false, removed = 0;
const context = {
  Vue: {
    ref: value => ({value}),
    computed: callback => ({get value() { return callback(); }}),
    onMounted: () => {},
  },
  fetch: async () => response,
  setTimeout: () => 0,
  navigator: {},
  document: {
    createElement: () => ({style: {}, select() {}, remove() { removed++; }}),
    body: {appendChild() {}},
    execCommand: () => copySucceeds,
  },
};
vm.runInNewContext(script, context, {filename: 'dashboard.js'});
app = context.app;
const lastToast = () => app.toasts.value.at(-1);
(async () => {
  app.authenticated.value = true;
  await app.loadAccounts();
  assert.equal(lastToast().type, 'danger');
  assert.equal(app.loading.value, false);
  await app.logout();
  assert.equal(app.authenticated.value, true, 'A failed logout must not claim success');
  assert.equal(lastToast().type, 'danger');
  response = {ok: true, status: 200};
  await app.logout();
  assert.equal(app.authenticated.value, false);
  app.copyText('example');
  assert.equal(lastToast().type, 'danger', 'A failed copy must not claim success');
  assert.equal(removed, 1);
  copySucceeds = true;
  app.copyText('example');
  assert.equal(lastToast().type, 'success');
  assert.equal(removed, 2);
  console.log('PASS: dashboard load, logout and clipboard error handling');
})().catch(error => { console.error(error); process.exitCode = 1; });
