# Notixer sync server

A self-hosted synchronization server for Notixer using Loco/Rust, PostgreSQL and Docker Compose. It runs without an external cloud service and is intended for self-hosting.

## Setup with Docker Compose

Compose uses `notixer` as both the PostgreSQL role and database name. PostgreSQL creates them when it initializes an empty volume. To start a fresh instance alongside an older installation, stop the old stack to free the host port, then use `docker compose -p notixer-fresh up -d --build --wait`. This creates separate database and file volumes while preserving the old volumes. Use `-p notixer-fresh` on subsequent Compose commands for that instance.

1. Create the configuration and set a random database password (hexadecimal characters) in `.env`:

   ```sh
   cp .env.example .env
   openssl rand -hex 32
   ```

   Never commit or share `.env`.

2. Start the server and check its health:

   ```sh
   docker compose config --quiet
   docker compose up -d --build --wait
   curl --fail http://127.0.0.1:5150/api/v1/health
   ```

3. Once the health check succeeds, initialize the dashboard administrator:

   ```sh
   docker compose exec server noter-server admin init-admin
   ```

   The command creates the `admin` account and displays a randomly generated password once. Save it and use it to sign in at `/admin`. If an administrator already exists, the command exits without overwriting the credentials.

4. The API binds to `127.0.0.1:5150` by default. To connect other devices, place a reverse proxy with a valid TLS certificate in front of it. Support streaming, request bodies of at least **4 MiB + 28 bytes**, and suitable upload timeouts. Avoid logging Authorization headers or request bodies, and configure rate limits.

   For deliberate LAN tests without TLS, enable **Allow HTTP for this new connection** in the app. Device tokens and connection metadata are then unencrypted in transit. Use HTTPS for production.

## Accounts and devices

Public registration is disabled. Manage sync accounts and device access in the dashboard or with the server CLI.

```sh
docker compose exec server noter-server admin create-account
docker compose exec server noter-server admin add-device ACCOUNT_UUID
```

`add-device` displays the device ID and a random 256-bit access token **once**. The server stores only its SHA-256 hash. Generate a separate token for each device and keep it secret.

### Pair Android with a QR code

1. In the admin dashboard at **/admin**, select an account and choose **Pair device by QR code**.
2. Check that the displayed HTTPS address is reachable from your Android device. For an existing vault, you can paste its recovery key into the dashboard form. The browser includes the key in the QR image locally. The server never receives the recovery key itself. If you leave the field blank, the app asks for the existing key after scanning.
3. In Notixer on Android, open **Self-hosted sync server → Scan pairing QR code**. Scan the code and confirm the server shown in the app.
4. For a new vault, Notixer generates the recovery key. Back it up when the app displays it. Each successful scan creates a separate device token in the Android keychain.

The code expires after five minutes and can be redeemed once. Generating a new code for the same account replaces the previous one. Treat the QR code as a secret, especially if it contains the recovery key. The dashboard also supports creating device tokens for manual setup.

### Connect a device

1. Open **Self-hosted sync server** in Notixer and enter the server address without a path and the device access token.
2. On the first device, generate a **Recovery key** and store a copy safely outside the device.
3. Connect and sync.
4. On additional devices, use a separate device token for the same account and the **same recovery key**.

Tokens and keys are stored in the system keychain (Android Keystore, Linux Secret Service, or Windows secure storage).

### Connect Notixer Web

Serve the extracted Notixer Web ZIP and the Sync API at the same HTTPS origin. Keep the sync server listening on loopback and forward its API routes through the same reverse proxy as the static site. This example assumes Caddy and Docker Compose are on the same host:

```caddyfile
notes.example.com {
    @notixer_backend path /api/v1/* /admin /admin/*
    handle @notixer_backend {
        reverse_proxy 127.0.0.1:5150
    }
    handle {
        root * /srv/notixer/web
        file_server
    }
}
```

1. Create a separate device token for the browser under your existing sync account.
2. Open **Sync** in the web app and enter the public server origin, device token and the recovery key from the installed app.
3. Select **Connect**, then **Sync now**. Repeat **Sync now** to upload local edits and fetch changes from other devices.

The browser keeps the credentials in the open tab. Enter them again after closing or reloading it. Keep a browser profile per vault and keep independent backups of the local library. For separate Web and API origins, the API reverse proxy must explicitly allow the Web origin on `/api/v1/*`, including `OPTIONS` preflight requests, `GET, PUT, POST`, and the `Authorization` and `Content-Type` headers. Use HTTPS for both origins.

### Share a Live Canvas

Install a server and Web build that include Live Canvas. Serve Notixer Web on the same HTTPS origin as the sync API using the reverse-proxy example above. The proxy must pass WebSocket upgrades on `/api/v1/live/*`. Caddy's `reverse_proxy` handles the upgrade automatically. Route creation and session termination through the same server instance as the WebSocket connections.

On Android, connect the sync server, then open **Library actions → Live Canvas → Share live**. Copy the viewer link and open it in a browser. A session can have up to 12 viewers and expires after two hours. **Stop sharing** revokes the invitation and disconnects the viewers. Use **Save to library** to keep the drawing as a regular notebook.

The link grants access to the drawing for that session. Share it with the intended viewers only. The server relays encrypted drawing messages and holds the session in memory. The saved notebook uses the ordinary Notixer library and sync.

#### Verify Live Canvas latency

The Docker integration check measures WebSocket relay latency from frame send to receive in one process. This measures the relay and does not include Android input, encryption before send, or browser rendering.

To check the 150 ms end-to-end target from [issue #31](https://github.com/Notixer-DE/Notixer/issues/31):

1. Open Live Canvas on an Android device and open its viewer link in Chromium. Put both displays in the same camera shot. Record at a known frame rate, preferably 120 fps or higher.
2. On the same Wi-Fi network and with the relay reachable on the LAN, draw 30 short strokes. Keep the stylus down for at least half a second each time.
3. For each stroke, count frames from visible stylus contact to the first ink visible in Chromium. Convert the count to milliseconds with `1000 × frames / fps`. Sort the 30 samples and record the 29th value as p95. The target is p95 ≤ 150 ms, with every stroke visible before pointer-up.
4. Repeat with a remote relay and record its p95 separately. Record the phone model, Android and Chromium versions, network topology, relay location, and recording frame rate alongside the measurements.

### Revoke a lost device

```sh
docker compose exec server noter-server admin revoke-device DEVICE_UUID
```

Revocation blocks new requests from that device. It does not delete data already downloaded or rotate the vault key. If the vault key is compromised, create a new account with a new key.

Disconnecting in the app only removes local credentials; revoke the device on the server to block its token.

## Encryption and storage

- A random 32-byte vault key is generated on the client. Keys are derived with HKDF-HMAC-SHA-256; AES-256-GCM encrypts data and authenticates metadata through AAD.
- Documents, titles, tags, folder names, application metadata and study history are encrypted.
- The server can see account/device identifiers, encrypted block sizes, revision relationships and order, and access/network metadata.
- PostgreSQL (`postgres_data`) stores accounts, token hashes, the journal and encrypted revision manifests. `noter_files` stores encrypted 4-MiB blocks. Default account quota: 100 GiB and 1,000,000 revisions.

## Backups and updates

For a consistent backup, briefly stop the server and back up the database and file volume **together**:

```sh
docker compose stop server
docker compose exec -T postgres pg_dump -U notixer -d notixer > notixer.sql
# Back up noter_files at the same point in time.
docker compose up -d server
```

The database dump and `noter_files` belong together. Keep them separate from the client recovery key.

- Before updating, take a backup. Then run `docker compose up -d --build --wait`. Migrations run automatically; destructive rollbacks are disabled.
- `docker compose down` preserves volumes. **`docker compose down -v` permanently deletes all server data.**

## OpenAPI contract

The server generates its OpenAPI document from the same annotated handlers that register the Loco.rs routes. It describes the sync, pairing, Live Canvas and admin HTTP endpoints, including bearer-token and admin-cookie authentication. The Live Canvas entry describes the WebSocket handshake and the first authentication message.

Download the JSON from a running server:

```sh
curl --fail http://127.0.0.1:5150/api/v1/openapi.json -o notixer-openapi.json
```

Export it directly from the server image, including when PostgreSQL is stopped:

```sh
docker compose run --rm --no-deps -T server openapi > notixer-openapi.json
```

The specification only describes the API. Data endpoints retain their existing authentication.

## Admin frontend development

The admin dashboard lives under `server/admin-ui`. It uses Vue single-file components and Vite. Docker builds and bundles the assets automatically. When building or testing the Rust server directly, build the dashboard first:

```sh
npm ci --prefix server/admin-ui
npm run build --prefix server/admin-ui
```

Use `npm run dev --prefix server/admin-ui` for frontend development with the sync server running on port 5150. When using an HTTPS reverse proxy, forward `X-Forwarded-Proto: https` so the admin session cookie gets the `Secure` flag.

## Checks

```sh
cargo fmt --manifest-path server/Cargo.toml --check
cargo test --manifest-path server/Cargo.toml --locked
cargo clippy --manifest-path server/Cargo.toml --locked --all-targets -- -D warnings
```

Run the complete Compose integration test with two Flutter clients using:

```sh
FLUTTER_BIN=/path/to/flutter python3 tools/test-sync-server.py
```
