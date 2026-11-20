# Notixer sync server

A self-hosted synchronization server for Notixer using Loco/Rust, PostgreSQL and Docker Compose. It runs without an external cloud service and is intended for self-hosting.

## Setup with Docker Compose

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
    handle /api/v1/* {
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
# Use pg_dump for PostgreSQL and back up noter_files at the same point in time.
docker compose up -d server
```

The database dump and `noter_files` belong together. Keep them separate from the client recovery key.

- Before updating, take a backup. Then run `docker compose up -d --build --wait`. Migrations run automatically; destructive rollbacks are disabled.
- `docker compose down` preserves volumes. **`docker compose down -v` permanently deletes all server data.**

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
