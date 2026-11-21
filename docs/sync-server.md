# Notixer sync server

A self-hosted synchronization server for Notixer using Loco/Rust, PostgreSQL and Docker Compose. It runs without an external cloud service and is intended for self-hosting.

## Setup with Docker Compose

Compose uses `notixer` as both the PostgreSQL role and database name. PostgreSQL creates them when it initializes an empty volume. To keep an existing database, follow the [in-place upgrade](#upgrade-a-database-initialized-as-noter). To start a fresh instance alongside an older installation, stop the old stack to free the host port, then use `docker compose -p notixer-fresh up -d --build --wait`. This creates separate database and file volumes while preserving the old volumes. Use `-p notixer-fresh` on subsequent Compose commands for that instance.

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

## Upgrade a database initialized as `noter`

PostgreSQL creates the configured role and database when it initializes an empty volume. If an upgrade logs `Role "notixer" does not exist`, the existing volume may still have the `noter` role and database. That leaves the sync API unreachable through the reverse proxy and can produce HTTP 502 for both sync and Live Canvas.

Run these commands in the directory for the existing Compose project. If you used `-p` to select that project, use the same option on every command. Keep the database and blob volumes attached. Stop the sync server, back up the existing database, and rename its database and role in one transaction.

```sh
(
  set -euC
  umask 077
  docker compose stop server
  docker compose exec -T postgres pg_dump -U noter -d noter -Fc > noter-before-rename.dump
  docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U noter -d postgres <<'SQL'
BEGIN;
ALTER DATABASE noter RENAME TO notixer;
CREATE ROLE notixer_rename_helper NOLOGIN SUPERUSER;
SET SESSION AUTHORIZATION notixer_rename_helper;
ALTER ROLE noter RENAME TO notixer;
RESET SESSION AUTHORIZATION;
DROP ROLE notixer_rename_helper;
COMMIT;
SQL
)
```

The temporary role allows PostgreSQL to rename the authenticated role within the transaction. The rename preserves database contents, ownership and the SCRAM password used by the standard Compose setup. Keep the same `POSTGRES_PASSWORD` in `.env`. If it was changed or the database used an MD5 password, connect with `docker compose exec postgres psql -X -U notixer -d postgres`, run `\password notixer` with the password from `.env`, and quit with `\q`.

After the transaction succeeds, start the updated server and verify the local API.

```sh
docker compose up -d --build --wait
curl --fail http://127.0.0.1:5150/api/v1/health
```

Existing dashboard and sync accounts are retained.

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
3. In Notixer on Android, open **More → Settings → Sync → Scan pairing QR code**. Scan the code and confirm the server shown in the app.
4. For a new vault, Notixer generates the recovery key. Back it up when the app displays it. Each successful scan creates a separate device token in the Android keychain.

The code expires after five minutes and can be redeemed once. Generating a new code for the same account replaces the previous one. Treat the QR code as a secret, especially if it contains the recovery key. The dashboard also supports creating device tokens for manual setup.

### Connect a device

1. Open **More → Settings → Sync** in Notixer and enter the server address without a path and the device access token.
2. On the first device, generate a **Recovery key** and store a copy safely outside the device.
3. Connect and sync.
4. On additional devices, use a separate device token for the same account and the **same recovery key**.

Tokens and keys are stored in the system keychain (Android Keystore, Linux Secret Service, or Windows secure storage).

### Share a Live Canvas

Update the sync server and the Android, Linux or Windows app. Connect each device to the same sync account with its own device token and the same recovery key.

1. On Android, open **More → Live Canvas → Share live**.
2. On Linux or Windows, select **Watch live** in the banner above the workspace. The banner appears within a few seconds, including while a document is open. Use **Presentation mode** to give the drawing the full app window.
3. On Android, select **Stop sharing** to disconnect the viewers. Use **Save to library** to keep the drawing as a regular notebook.

Live Canvas uses stylus pressure from the drawing preferences. The stylus side button and eraser end temporarily erase. Set the color and stroke width in pixels separately for the pen and marker. The pixel value refers to the page at 96 pixels per inch and stays the same when zooming. Use the zoom controls, pinch or scroll to zoom. Drag with a finger in navigation mode, or with two fingers while finger drawing is enabled. On desktop, drag the page or use the trackpad. Use **Lasso selection** to circle strokes. Drag inside the selection to move it, pull an edge or corner handle to resize it, or use the rotation handle to turn it. You can also delete the selection. The completed edit is streamed to viewers and can be undone.

The proxy must forward `/api/v1/live` and WebSocket upgrades on `/api/v1/live/*`. Caddy's `reverse_proxy` handles upgrades automatically. Send all Live Canvas traffic to the same sync server instance. Sessions are kept in memory, expire after two hours and allow up to 12 viewers. The sync server relays encrypted drawing messages. Live Canvas connections require a native app and a device token for the host's sync account.

#### Verify Live Canvas latency

The Docker integration check measures WebSocket relay latency from frame send to receive in one process. This measures the relay and does not include Android input, encryption before send, or desktop rendering.

To check the 150 ms end-to-end target from [issue #31](https://github.com/Notixer-DE/Notixer/issues/31):

1. Open Live Canvas on an Android device and select **Watch live** in the Linux or Windows app. Put both displays in the same camera shot. Record at a known frame rate, preferably 120 fps or higher.
2. On the same Wi-Fi network and with the relay reachable on the LAN, draw 30 short strokes. Keep the stylus down for at least half a second each time.
3. For each stroke, count frames from visible stylus contact to the first ink visible in the desktop app. Convert the count to milliseconds with `1000 × frames / fps`. Sort the 30 samples and record the 29th value as p95. The target is p95 ≤ 150 ms, with every stroke visible before pointer-up.
4. Repeat with a remote relay and record its p95 separately. Record the device models, OS versions and Notixer build numbers, network topology, relay location, and recording frame rate alongside the measurements.

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
