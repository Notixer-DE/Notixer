"""Build and exercise an isolated Compose stack; never touches deployment volumes.

FLUTTER_BIN=/path/to/flutter python3 tools/test-sync-server.py
Adds a real two-device E2EE test when Flutter is available.
"""
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
from http.cookiejar import CookieJar
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
PROJECT = "noter-test-" + secrets.token_hex(5)


def main():
    env = dict(os.environ, POSTGRES_PASSWORD=secrets.token_hex(32))
    with tempfile.TemporaryDirectory(prefix="noter-compose-") as temporary:
        override = Path(temporary) / "compose.test.yaml"
        override.write_text(
            'services:\n  server:\n    ports: !override\n      - "127.0.0.1::5150"\n'
        )
        compose = ["docker", "compose", "-p", PROJECT, "-f", str(ROOT / "compose.yaml"),
                   "-f", str(override)]

        def run(*args, capture=True):
            return subprocess.run([*compose, *args], cwd=ROOT, env=env,
                                  check=True, text=True, capture_output=capture).stdout

        def account():
            return run("exec", "-T", "server", "noter-server", "admin",
                       "create-account").strip().split()[-1]

        def device(owner):
            output = run("exec", "-T", "server", "noter-server", "admin", "add-device", owner)
            return re.search(r"Device: ([0-9a-f-]+)", output)[1], re.search(r": ([0-9a-f]{64})", output)[1]

        def admin_users():
            return run("exec", "-T", "postgres", "psql", "-U", "noter", "-d", "noter",
                       "-Atc", "SELECT username FROM admin_users ORDER BY username").splitlines()

        try:
            run("up", "-d", "--build", "--wait", "--wait-timeout", "120", capture=False)
            address = run("port", "server", "5150").strip()
            base = f"http://{address}/api/v1"
            with urllib.request.urlopen(base + "/openapi.json", timeout=30) as response:
                assert response.headers.get_content_type() == "application/json"
                openapi = json.load(response)
            assert openapi == json.loads(run("exec", "-T", "server", "noter-server", "openapi"))
            assert openapi["openapi"].startswith("3.")
            assert openapi["paths"]["/api/v1/commits"]["post"]["security"] == [{"device_token": []}]
            assert openapi["paths"]["/admin/api/accounts/{id}/pairing"]["post"]["security"] == [{"admin_session": []}]
            assert "101" in openapi["paths"]["/api/v1/live/{id}"]["get"]["responses"]
            print("PASS: Loco routes generate the same OpenAPI contract over HTTP and CLI")
            assert admin_users() == [], "A fresh server should start without an admin account"
            init_admin = ("exec", "-T", "server", "noter-server", "admin", "init-admin")
            output = run(*init_admin)
            password = re.search(r"Admin password \(shown once; store securely\): ([0-9a-f]{64})", output)
            assert password is not None, "The initializer did not return a generated password"
            retry = subprocess.run([*compose, *init_admin], cwd=ROOT, env=env,
                                   text=True, capture_output=True)
            assert retry.returncode != 0 and "already exists" in retry.stderr + retry.stdout
            assert admin_users() == ["admin"]

            browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()))
            with browser.open(f"http://{address}/admin", timeout=30) as response:
                assert response.headers.get_content_type() == "text/html"
            login = urllib.request.Request(
                f"http://{address}/admin/api/login",
                data=json.dumps({"username": "admin", "password": password[1]}).encode(),
                headers={"Content-Type": "application/json"},
            )
            with browser.open(login, timeout=30) as response:
                assert json.load(response) == {"ok": True, "username": "admin"}
            with browser.open(f"http://{address}/admin/api/me", timeout=30) as response:
                assert json.load(response) == {"authenticated": True, "username": "admin"}
            print("PASS: explicit admin initialization, repeat protection, and authenticated login")

            owner, other = account(), account()
            aid, token = device(owner)
            device(owner)
            _, foreign = device(other)

            def create_pairing(owner, site=None):
                headers = {"Content-Type": "application/json"}
                if site:
                    headers["Sec-Fetch-Site"] = site
                req = urllib.request.Request(
                    f"http://{address}/admin/api/accounts/{owner}/pairing",
                    data=b"{}", headers=headers,
                )
                with browser.open(req, timeout=30) as response:
                    assert response.headers.get("Cache-Control") == "no-store"
                    return json.load(response)

            pairing_owner = account()
            first_pairing = create_pairing(pairing_owner)
            assert first_pairing["account"] == pairing_owner and first_pairing["needs_key"] is False
            try:
                create_pairing(pairing_owner, "same-site")
                raise AssertionError("Cross-origin pairing creation was accepted")
            except urllib.error.HTTPError as error:
                assert error.code == 403
            invite = create_pairing(pairing_owner)

            def redeem(code, expected_status, owner=pairing_owner, key="a" * 64):
                req = urllib.request.Request(
                    base + "/pairing/redeem",
                    data=json.dumps({"code": code, "account": owner, "key_check": key}).encode(),
                    headers={"Content-Type": "application/json"},
                )
                try:
                    with urllib.request.urlopen(req, timeout=30) as response:
                        assert response.status == expected_status
                        assert response.headers.get("Cache-Control") == "no-store"
                        return json.load(response)["token"]
                except urllib.error.HTTPError as error:
                    assert error.code == expected_status

            redeem(first_pairing["code"], 401)
            redeem(invite["code"], 401, owner=other)

            def concurrent_redeem():
                req = urllib.request.Request(
                    base + "/pairing/redeem",
                    data=json.dumps({"code": invite["code"], "account": pairing_owner,
                                     "key_check": "a" * 64}).encode(),
                    headers={"Content-Type": "application/json"},
                )
                try:
                    with urllib.request.urlopen(req, timeout=30) as response:
                        return response.status, json.load(response)["token"]
                except urllib.error.HTTPError as error:
                    return error.code, None

            with ThreadPoolExecutor(max_workers=2) as pool:
                outcomes = sorted(pool.map(lambda _: concurrent_redeem(), range(2)))
            assert [status for status, _ in outcomes] == [200, 401]
            paired_token = outcomes[0][1]

            def request(method, path, token=token, body=None, status=200):
                headers = {"Authorization": "Bearer " + token}
                if isinstance(body, dict):
                    body = json.dumps(body).encode()
                    headers["Content-Type"] = "application/json"
                req = urllib.request.Request(base + path, data=body, method=method, headers=headers)
                try:
                    with urllib.request.urlopen(req, timeout=30) as response:
                        actual, output = response.status, response.read()
                except urllib.error.HTTPError as error:
                    actual, output = error.code, error.read()
                assert actual == status, (method, path, actual, status, output[:300])
                return output

            assert json.loads(request("GET", "/session", token=paired_token))["account"] == pairing_owner
            request("PUT", "/key-check", token=paired_token, body={"value": "a" * 64}, status=204)
            next_invite = create_pairing(pairing_owner)
            assert next_invite["needs_key"] is True
            redeem(next_invite["code"], 409, key="c" * 64)
            assert redeem(next_invite["code"], 200)
            redeem(next_invite["code"], 401)
            with browser.open(f"http://{address}/admin/api/accounts", timeout=30) as response:
                listed = {entry["id"]: entry for entry in json.load(response)}
            assert listed[pairing_owner]["needs_key"] is True
            assert "key_check" not in listed[pairing_owner]
            assert len(listed[pairing_owner]["devices"]) == 2
            assert listed[other]["needs_key"] is False
            expired_invite = create_pairing(pairing_owner)
            run("exec", "-T", "postgres", "psql", "-U", "noter", "-d", "noter", "-c",
                "UPDATE pairing_codes SET expires_at = now() - interval '1 second'")
            redeem(expired_invite["code"], 401)
            print("PASS: pairing authority, one-time redemption, wrong key retry and expiry")

            request("GET", "/session", token="bad", status=401)
            request("PUT", "/key-check", body={"value": "a" * 64}, status=204)
            request("PUT", "/key-check", body={"value": "b" * 64}, status=409)
            payload = secrets.token_bytes(8192)
            blob = hashlib.sha256(payload).hexdigest()
            request("PUT", "/blobs/" + "0" * 64, body=payload, status=400)
            request("PUT", "/blobs/" + blob, body=payload, status=201)
            request("PUT", "/blobs/" + blob, body=payload, status=204)
            run("exec", "-T", "postgres", "psql", "-U", "noter", "-d", "noter",
                "-c", f"UPDATE accounts SET quota_bytes=8192 WHERE id='{owner}'")
            over_quota = secrets.token_bytes(32)
            request("PUT", "/blobs/" + hashlib.sha256(over_quota).hexdigest(),
                    body=over_quota, status=507)
            run("exec", "-T", "postgres", "psql", "-U", "noter", "-d", "noter",
                "-c", f"UPDATE accounts SET quota_bytes=107374182400 WHERE id='{owner}'")
            assert request("GET", "/blobs/" + blob) == payload
            request("GET", "/blobs/" + blob, token=foreign, status=404)
            manifest = base64.b64encode(secrets.token_bytes(64)).decode()
            commit = {"id": "c" * 64, "parents": [], "blobs": [blob], "manifest": manifest}
            request("POST", "/commits", token=foreign, body=commit, status=400)
            request("POST", "/commits", body=dict(commit, blobs=["d" * 64]), status=400)
            first = request("POST", "/commits", body=commit)
            assert json.loads(request("POST", "/commits", body=dict(commit,
                manifest=base64.b64encode(secrets.token_bytes(64)).decode()))) == json.loads(first)
            assert json.loads(request("GET", "/changes?after=0"))["cursor"] == 1

            # Concurrent publication must allocate a lossless, contiguous cursor.
            def publish(index):
                candidate = dict(commit, id=hashlib.sha256(str(index).encode()).hexdigest(), parents=[commit["id"]])
                request("POST", "/commits", body=candidate)
            with ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(publish, range(110)))
            page = json.loads(request("GET", "/changes?after=0"))
            assert len(page["items"]) == page["cursor"] == 100
            second = json.loads(request("GET", "/changes?after=100"))
            assert len(second["items"]) == 11 and second["cursor"] == 111
            assert json.loads(request("GET", "/changes?after=0", token=foreign))["items"] == []
            request("GET", "/changes?after=999", status=409)
            run("restart", "server")
            run("up", "-d", "--wait", "--wait-timeout", "60")
            # Docker may allocate a different ephemeral host port on restart.
            address = run("port", "server", "5150").strip()
            base = f"http://{address}/api/v1"
            assert request("GET", "/blobs/" + blob) == payload
            run("exec", "-T", "server", "noter-server", "admin", "revoke-device", aid)
            request("GET", "/session", status=401)
            print("PASS: auth, isolation, integrity, quota-safe retry, concurrent cursors, pagination, persistence, revocation")

            _, token_for_live = device(owner)
            subprocess.run(
                ["node", str(ROOT / "tools" / "test-live-canvas.cjs")],
                cwd=ROOT,
                env=dict(env, NOTIXER_LIVE_ORIGIN=f"http://{address}",
                         NOTIXER_LIVE_HOST=token_for_live, NOTIXER_LIVE_OTHER=foreign),
                check=True,
            )

            flutter = os.environ.get("FLUTTER_BIN")
            if flutter:
                live_owner = account()
                _, live_a = device(live_owner)
                _, live_b = device(live_owner)
                live_env = dict(env, NOTER_TEST_SERVER="http://" + address,
                                NOTER_TEST_ACCOUNT=live_owner,
                                NOTER_TEST_TOKEN_A=live_a, NOTER_TEST_TOKEN_B=live_b)
                subprocess.run([flutter, "test", "test/live_sync_test.dart"],
                               cwd=ROOT, env=live_env, check=True)
                dump = run("exec", "-T", "postgres", "pg_dump", "-U", "noter", "-d", "noter", "--data-only")
                assert all(title not in dump for title in ["E2EE secret title", "Tablet secret", "Laptop secret"])
                print("PASS: real Flutter E2EE and absence of plaintext titles in PostgreSQL dump")
            else:
                print("SKIP: real Flutter E2EE (set FLUTTER_BIN)")
        except Exception:
            # Logs contain no credentials or payloads by design.
            run("logs", "--no-color", "--since", "5m", capture=False)
            raise
        finally:
            # Only resources belonging to this random test project are removed.
            run("down", "--volumes", "--remove-orphans", capture=False)


if __name__ == "__main__":
    main()
