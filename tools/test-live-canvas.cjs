const assert = require('node:assert/strict');
const http = require('node:http');
const https = require('node:https');

const origin = process.env.NOTIXER_LIVE_ORIGIN;
const hostToken = process.env.NOTIXER_LIVE_HOST;
const otherToken = process.env.NOTIXER_LIVE_OTHER;
const desktopToken = process.env.NOTIXER_LIVE_DESKTOP;
const sockets = [];

async function request(method, path, token) {
  return fetch(origin + path, {
    method,
    redirect: 'error',
    headers: {Authorization: `Bearer ${token}`},
    signal: AbortSignal.timeout(5000),
  });
}

function socketFor(path, role, token) {
  const url = new URL(path, origin);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  const socket = new WebSocket(url);
  socket.binaryType = 'arraybuffer';
  sockets.push(socket);
  const queue = [];
  let notify;
  const put = value => {
    queue.push(value);
    notify?.();
  };
  socket.addEventListener('open', () => socket.send(JSON.stringify({role, token})));
  socket.addEventListener('message', event => put(event.data));
  socket.addEventListener('close', () => put(null));
  socket.addEventListener('error', () => put(null));
  return {
    socket,
    async next() {
      const timeout = AbortSignal.timeout(5000);
      if (queue.length === 0) {
        await new Promise((resolve, reject) => {
          notify = resolve;
          timeout.addEventListener('abort', () => reject(timeout.reason), {once: true});
        });
      }
      notify = null;
      return queue.shift();
    },
  };
}

function browserUpgradeStatus(path) {
  const url = new URL(path, origin);
  const client = url.protocol === 'https:' ? https : http;
  return new Promise((resolve, reject) => {
    const request = client.get(url, {
      signal: AbortSignal.timeout(5000),
      headers: {
        Origin: origin,
        Connection: 'Upgrade',
        Upgrade: 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': Buffer.alloc(16).toString('base64'),
      },
    }, response => {
      response.resume();
      resolve(response.statusCode);
    });
    request.on('upgrade', (_, socket) => {
      socket.destroy();
      resolve(101);
    });
    request.on('error', reject);
  });
}

async function measureRelay(host, viewer) {
  const samples = [];
  for (let index = 0; index < 33; index++) {
    const frame = new Uint8Array(256);
    new DataView(frame.buffer).setUint32(0, index);
    const start = performance.now();
    host.socket.send(frame);
    assert.deepEqual(new Uint8Array(await viewer.next()), frame);
    if (index >= 3) samples.push(performance.now() - start);
  }
  samples.sort((a, b) => a - b);
  const p95 = samples[Math.ceil(samples.length * 0.95) - 1];
  const median = samples[samples.length / 2].toFixed(2);
  assert(p95 < 1000, 'Local relay p95 exceeded the CI regression ceiling');
  console.log(`Live Canvas relay only (30 frames): p50 ${median} ms, p95 ${p95.toFixed(2)} ms`);
}

async function main() {
  assert.equal((await request('POST', '/api/v1/live', 'invalid')).status, 401);
  assert.equal((await request('GET', '/api/v1/live', 'invalid')).status, 401);
  const result = await request('POST', '/api/v1/live', hostToken);
  assert.equal(result.status, 200);
  const broadcast = await result.json();
  assert.deepEqual(Object.keys(broadcast).sort(), ['account_only', 'id']);
  assert.equal(broadcast.account_only, true);
  const path = '/api/v1/live/' + broadcast.id;
  assert.deepEqual(await (await request('GET', '/api/v1/live', desktopToken)).json(), []);
  assert.equal((await request('DELETE', path, otherToken)).status, 404);
  assert.equal((await request('DELETE', path, desktopToken)).status, 404);

  let host = socketFor(path, 'host', hostToken);
  assert.deepEqual(JSON.parse(await host.next()), {viewers: 0});
  const discovered = await request('GET', '/api/v1/live', desktopToken);
  assert.equal(discovered.headers.get('Cache-Control'), 'no-store');
  const [session, ...others] = await discovered.json();
  assert.equal(others.length, 0);
  assert.deepEqual(Object.keys(session).sort(), ['host_device', 'id']);
  assert.equal(session.id, broadcast.id);
  assert.deepEqual(await (await request('GET', '/api/v1/live', hostToken)).json(), []);
  assert.deepEqual(await (await request('GET', '/api/v1/live', otherToken)).json(), []);
  assert.equal(await socketFor(path, 'host', otherToken).next(), 'denied');
  assert.equal(await socketFor(path, 'host', desktopToken).next(), 'denied');
  assert.equal(await socketFor(path, 'viewer', desktopToken).next(), 'denied');
  assert.equal(await socketFor(path, 'account-viewer', '0'.repeat(64)).next(), 'denied');
  assert.equal(await socketFor(path, 'account-viewer', otherToken).next(), 'denied');
  assert.equal(await browserUpgradeStatus(path), 403);

  const viewer = socketFor(path, 'account-viewer', desktopToken);
  assert.equal(await viewer.next(), 'joined');
  assert.deepEqual(JSON.parse(await host.next()), {viewers: 1});
  const frame = Uint8Array.from([2, 0, 7, 255, 6]);
  host.socket.send(frame);
  assert.deepEqual(new Uint8Array(await viewer.next()), frame);
  viewer.socket.send(Uint8Array.from([100]));
  assert.equal(await viewer.next(), null);
  assert.deepEqual(JSON.parse(await host.next()), {viewers: 0});

  const reconnected = socketFor(path, 'account-viewer', desktopToken);
  assert.equal(await reconnected.next(), 'joined');
  assert.deepEqual(JSON.parse(await host.next()), {viewers: 1});
  host.socket.send(frame);
  assert.deepEqual(new Uint8Array(await reconnected.next()), frame);

  // A host can resume immediately even while its old connection still exists.
  const previous = host;
  host = socketFor(path, 'host', hostToken);
  assert.deepEqual(JSON.parse(await host.next()), {viewers: 1});
  assert.equal(await previous.next(), null);
  host.socket.send(frame);
  assert.deepEqual(new Uint8Array(await reconnected.next()), frame);

  await measureRelay(host, reconnected);

  assert.equal((await request('DELETE', path, hostToken)).status, 204);
  assert.equal(await reconnected.next(), 'ended');
  assert.equal(await host.next(), 'ended');
  assert.equal(await socketFor(path, 'account-viewer', desktopToken).next(), null);
  assert.deepEqual(await (await request('GET', '/api/v1/live', desktopToken)).json(), []);
  console.log('PASS: private app broadcasts, isolation, relay, reconnect and termination');
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
}).finally(() => {
  for (const socket of sockets) socket.close();
});
