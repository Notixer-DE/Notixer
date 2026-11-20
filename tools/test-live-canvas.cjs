const assert = require('node:assert/strict');

const origin = process.env.NOTIXER_LIVE_ORIGIN;
const hostToken = process.env.NOTIXER_LIVE_HOST;
const otherToken = process.env.NOTIXER_LIVE_OTHER;
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
  url.protocol = 'ws:';
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

async function main() {
  assert.equal((await request('POST', '/api/v1/live', 'invalid')).status, 401);
  const result = await request('POST', '/api/v1/live', hostToken);
  assert.equal(result.status, 200);
  const {id, invite} = await result.json();
  const path = '/api/v1/live/' + id;
  assert.equal((await request('DELETE', path, otherToken)).status, 404);
  let host = socketFor(path, 'host', hostToken);
  assert.deepEqual(JSON.parse(await host.next()), {viewers: 0});
  assert.equal(await socketFor(path, 'host', otherToken).next(), 'denied');
  assert.equal(await socketFor(path, 'viewer', '0'.repeat(64)).next(), 'denied');

  const viewer = socketFor(path, 'viewer', invite);
  assert.equal(await viewer.next(), 'joined');
  assert.deepEqual(JSON.parse(await host.next()), {viewers: 1});
  const frame = Uint8Array.from([2, 0, 7, 255, 6]);
  host.socket.send(frame);
  assert.deepEqual(new Uint8Array(await viewer.next()), frame);
  viewer.socket.send(Uint8Array.from([100]));
  assert.equal(await viewer.next(), null);
  assert.deepEqual(JSON.parse(await host.next()), {viewers: 0});

  const reconnected = socketFor(path, 'viewer', invite);
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

  assert.equal((await request('DELETE', path, hostToken)).status, 204);
  assert.equal(await reconnected.next(), 'ended');
  assert.equal(await host.next(), 'ended');
  assert.equal(await socketFor(path, 'viewer', invite).next(), null);
  console.log('PASS: live session roles, frame relay, reconnect and revocation');
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
}).finally(() => {
  for (const socket of sockets) socket.close();
});
