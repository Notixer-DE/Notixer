# Notixer-Sync-Server

Selbst gehosteter Synchronisationsserver für Notixer (Loco/Rust, PostgreSQL, Docker Compose) ohne externe Cloud-Abhängigkeiten, ausgelegt für den Eigenbetrieb.

## Einrichtung (Docker Compose)

1. Konfigurationsdatei anlegen und ein zufälliges Datenbankpasswort (Hex-Zeichen) in `.env` setzen:

   ```sh
   cp .env.example .env
   openssl rand -hex 32
   ```

   `.env` niemals committen oder weitergeben.

2. Server starten und Gesundheit prüfen:

   ```sh
   docker compose config --quiet
   docker compose up -d --build --wait
   curl --fail http://127.0.0.1:5150/api/v1/health
   ```

3. **TLS / Reverse Proxy:** Die API bindet standardmäßig ausschließlich auf `127.0.0.1:5150`. Für den Zugriff von anderen Geräten einen Reverse Proxy mit gültigem TLS-Zertifikat davorschalten (Streaming, mindestens `4 MiB + 28 Bytes` Request-Body und passende Upload-Timeouts erlauben; `Authorization`-Header und Bodies nicht protokollieren; Rate-Limits einrichten).

   Für lokale LAN-Tests ohne TLS lässt sich in der App beim Einrichten explizit **HTTP für diese neue Verbindung erlauben** aktivieren. Dabei werden Geräte-Tokens und Verbindungsmetadaten nicht transportverschlüsselt – für produktive Nutzung immer HTTPS verwenden.

## Konten und Geräte verwalten

Die Registrierung ist geschlossen und erfolgt ausschließlich über die Server-CLI:

```sh
docker compose exec server noter-server admin create-account
docker compose exec server noter-server admin add-device ACCOUNT_UUID
```

`add-device` gibt die Geräte-ID und einen zufälligen 256-Bit-Zugangstoken **einmalig** aus (auf dem Server wird nur der SHA-256-Hash gespeichert). Für jedes Gerät ein eigenes Token erzeugen und geheim halten.

### Gerät in der App verbinden

1. In Notixer **Eigener Sync-Server** öffnen, Serveradresse (ohne Pfad) und Geräte-Token eingeben.
2. Auf dem ersten Gerät einen **Wiederherstellungsschlüssel** erzeugen und sicher außerhalb des Geräts aufbewahren.
3. Verbinden und synchronisieren.
4. Auf weiteren Geräten jeweils ein eigenes Geräte-Token desselben Kontos und **denselben** Wiederherstellungsschlüssel verwenden.

Tokens und Schlüssel werden ausschließlich im System-Schlüsselbund (Android Keystore / Linux Secret Service / Windows) gespeichert.

### Gerät sperren (bei Verlust)

```sh
docker compose exec server noter-server admin revoke-device DEVICE_UUID
```

Der Widerruf blockiert neue Anfragen dieses Geräts, löscht aber keine bereits heruntergeladenen Daten und rotiert nicht den Tresorschlüssel. Bei Kompromittierung des Tresorschlüssels muss ein neues Konto mit neuem Schlüssel eingerichtet werden.

## Verschlüsselung & Datensicherheit

- **End-to-End-Verschlüsselung:** Zufälliger 32-Byte-Tresorschlüssel auf dem Endgerät, Schlüsselableitung über HKDF-HMAC-SHA-256 und Verschlüsselung mit AES-256-GCM (inkl. authentifizierter Metadaten via AAD).
- **Geschützt:** Dokumente, Titel, Tags, Ordnernamen, fachliche Metadaten und Lernverläufe.
- **Für den Server sichtbar:** Konten-/Gerätekennungen, verschlüsselte Blockgrößen, Revisionsbeziehungen, Reihenfolge sowie Zugriffs- und Netzwerkmetadaten.
- **Speicher:** PostgreSQL (`postgres_data`) verwaltet Konten, Token-Hashes, Journal und verschlüsselte Revisionsmanifeste; `noter_files` speichert die auf dem Client verschlüsselten 4-MiB-Blöcke. Standardkontingent: 100 GiB und 1.000.000 Revisionen pro Konto.

## Backup & Updates

Für ein konsistentes Backup Server kurz anhalten, Datenbank und Dateivolume **gemeinsam** sichern und anschließend neu starten:

```sh
docker compose stop server
# PostgreSQL per pg_dump sichern und zeitgleich Volume noter_files sichern
docker compose up -d server
```

Datenbank-Dump und `noter_files` gehören zusammen und müssen getrennt vom Client-Wiederherstellungsschlüssel aufbewahrt werden.

- **Updates:** Nach vorherigem Backup `docker compose up -d --build --wait` ausführen (Migrationen laufen automatisch; destruktive Rollbacks sind deaktiviert).
- **Achtung:** `docker compose down` behält die Volumes; **`docker compose down -v` löscht alle Serverdaten unwiderruflich**.

## Tests

```sh
cargo fmt --manifest-path server/Cargo.toml --check
cargo test --manifest-path server/Cargo.toml --locked
cargo clippy --manifest-path server/Cargo.toml --locked --all-targets -- -D warnings
```

Für einen vollständigen Ende-zu-Ende-Integrationstest mit Compose und zwei Flutter-Clients:

```sh
FLUTTER_BIN=/pfad/zu/flutter python3 tools/test-sync-server.py
```
