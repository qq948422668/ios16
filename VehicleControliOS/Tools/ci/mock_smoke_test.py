#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Mock 服务契约回归测试（零依赖，CI 里跑在 ubuntu runner 上）。

客户端代码是照着这份契约写的，所以契约本身必须有测试兜底：
改了 mock 或改了客户端调用约定，这里会先红。

  python Tools/ci/mock_smoke_test.py
退出码 0 = 全部通过。
"""

from __future__ import annotations

import base64
import hashlib
import http.client
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVER_DIR = ROOT / "Tools" / "mock-server"
PORT = 8123
HOST = "127.0.0.1"
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

failures: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print("PASS  %s" % name)
    else:
        print("FAIL  %s  %s" % (name, detail))
        failures.append(name)


def request(method: str, path: str, body=None, headers=None):
    connection = http.client.HTTPConnection(HOST, PORT, timeout=8)
    connection.request(method, path, body=body, headers=headers or {})
    response = connection.getresponse()
    data = response.read()
    header_map = {k.lower(): v for k, v in response.getheaders()}
    status = response.status
    connection.close()
    return status, header_map, data


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def read_exact(sock: socket.socket, size: int) -> bytes:
    buffer = b""
    while len(buffer) < size:
        chunk = sock.recv(size - len(buffer))
        if not chunk:
            raise OSError("websocket closed")
        buffer += chunk
    return buffer


def main() -> int:
    log_path = Path(tempfile.gettempdir()) / "mock_server_ci.log"
    log_file = open(log_path, "wb")
    server = subprocess.Popen(
        [sys.executable, "-X", "utf8", "mock_server.py", "--port", str(PORT), "--quiet",
         "--token-ttl", "600"],
        cwd=str(SERVER_DIR), stdout=log_file, stderr=subprocess.STDOUT,
    )

    try:
        ready = False
        for _ in range(60):
            try:
                if request("GET", "/healthz")[0] == 200:
                    ready = True
                    break
            except OSError:
                pass
            time.sleep(0.25)
        check("mock server boots", ready)
        if not ready:
            raise SystemExit(1)

        verifier = "smoke-verifier-" + "x" * 40
        challenge = b64url(hashlib.sha256(verifier.encode()).digest())
        query = urllib.parse.urlencode({
            "response_type": "code",
            "client_id": "ios-mock-client",
            "redirect_uri": "com.vehiclecontrol.app://oauth/callback",
            "scope": "vehicle.read vehicle.control",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": "st-123",
        })
        status, _, body = request("GET", "/oauth2/authorize?" + query)
        check("authorize page 200", status == 200, str(status))
        check("authorize page renders form", b"/oauth2/authorize/approve" in body)

        status, headers, _ = request(
            "POST", "/oauth2/authorize/approve", body="state=st-123",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        location = headers.get("location", "")
        check("approve returns 302", status == 302, str(status))
        check("redirect uses app scheme",
              location.startswith("com.vehiclecontrol.app://oauth/callback?code="), location[:80])
        code = urllib.parse.parse_qs(urllib.parse.urlparse(location).query).get("code", [""])[0]
        check("authorization code issued", bool(code))

        form = urllib.parse.urlencode({
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": "com.vehiclecontrol.app://oauth/callback",
            "client_id": "ios-mock-client",
        })
        status, _, body = request(
            "POST", "/oauth2/token", body=form,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        tokens = json.loads(body)
        check("token exchange 200", status == 200, body[:120].decode("utf-8", "replace"))
        check("access_token present", str(tokens.get("access_token", "")).startswith("at_"))
        check("expires_in numeric", isinstance(tokens.get("expires_in"), int))

        auth = {"Authorization": "Bearer " + tokens["access_token"]}

        status, _, body = request("GET", "/v1/vehicles")
        check("missing token -> 401", status == 401, str(status))
        check("401 uses error envelope", b"code" in body)

        status, _, body = request("GET", "/v1/vehicles", headers=auth)
        vehicles = json.loads(body)["vehicles"]
        check("vehicle list 200", status == 200)
        check("two vehicles seeded", len(vehicles) == 2, str(len(vehicles)))
        check("capability filtering data present",
              "trunk" in vehicles[0]["capabilities"] and "trunk" not in vehicles[1]["capabilities"])

        status, _, body = request("GET", "/v1/vehicles/VH0001/status", headers=auth)
        snapshot = json.loads(body)
        check("snapshot 200", status == 200)
        check("snapshot shape",
              snapshot["battery"]["percent"] > 0 and "is_locked" in snapshot["security"])
        check("vehicle starts locked", snapshot["security"]["is_locked"] is True)

        payload = json.dumps({"action": "unlock", "parameters": {}})
        command_headers = dict(auth, **{"Idempotency-Key": "idem-1",
                                        "Content-Type": "application/json"})
        status, _, body = request("POST", "/v1/vehicles/VH0001/commands",
                                  body=payload, headers=command_headers)
        ticket = json.loads(body)
        check("command accepted 202", status == 202, str(status))
        check("ticket starts non-terminal", ticket["status"] in ("dispatched", "pending"),
              ticket.get("status"))
        ticket_id = ticket["ticket_id"]

        status, _, body = request("POST", "/v1/vehicles/VH0001/commands",
                                  body=payload, headers=command_headers)
        check("idempotency replays same ticket", json.loads(body)["ticket_id"] == ticket_id)

        receipt = {}
        for _ in range(20):
            time.sleep(0.5)
            _, _, body = request("GET", "/v1/vehicles/VH0001/commands/" + ticket_id, headers=auth)
            receipt = json.loads(body)
            if receipt["status"] in ("succeeded", "failed", "expired"):
                break
        check("receipt reaches succeeded", receipt.get("status") == "succeeded", str(receipt))
        check("completed_at filled", bool(receipt.get("completed_at")))

        _, _, body = request("GET", "/v1/vehicles/VH0001/status", headers=auth)
        check("command effect applied", json.loads(body)["security"]["is_locked"] is False)

        fail_headers = dict(auth, **{"Idempotency-Key": "idem-2",
                                     "Content-Type": "application/json"})
        _, _, body = request("POST", "/v1/vehicles/VH0001/commands",
                             body=json.dumps({"action": "charge_start", "parameters": {}}),
                             headers=fail_headers)
        fail_ticket = json.loads(body)["ticket_id"]
        time.sleep(3.6)
        _, _, body = request("GET", "/v1/vehicles/VH0001/commands/" + fail_ticket, headers=auth)
        failed = json.loads(body)
        check("failure path returns failed", failed["status"] == "failed", failed["status"])
        check("failure_reason present", bool(failed["failure_reason"]))
        _, _, body = request("GET", "/v1/vehicles/VH0001/status", headers=auth)
        check("failed command leaves state unchanged",
              json.loads(body)["battery"]["charging"] == "idle")

        status, _, _ = request(
            "POST", "/v1/push/subscriptions",
            body=json.dumps({"device_token": "abc", "platform": "ios", "bundle_id": "x"}),
            headers=dict(auth, **{"Content-Type": "application/json"}),
        )
        check("push subscription 204", status == 204, str(status))

        form = urllib.parse.urlencode({
            "grant_type": "refresh_token",
            "refresh_token": tokens["refresh_token"],
            "client_id": "ios-mock-client",
        })
        status, _, body = request("POST", "/oauth2/token", body=form,
                                  headers={"Content-Type": "application/x-www-form-urlencoded"})
        rotated = json.loads(body)
        check("refresh 200", status == 200, str(status))
        status, _, _ = request("GET", "/v1/vehicles",
                               headers={"Authorization": "Bearer " + rotated["access_token"]})
        check("rotated token works", status == 200, str(status))

        sock = socket.create_connection((HOST, PORT), timeout=8)
        key = base64.b64encode(os.urandom(16)).decode()
        handshake = (
            "GET /v1/vehicles/VH0001/stream HTTP/1.1\r\n"
            "Host: %s:%d\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "Authorization: Bearer %s\r\n\r\n"
        ) % (HOST, PORT, key, rotated["access_token"])
        sock.sendall(handshake.encode())

        head = b""
        while b"\r\n\r\n" not in head:
            chunk = sock.recv(1)
            if not chunk:
                break
            head += chunk
        check("websocket 101", head.startswith(b"HTTP/1.1 101"), head[:40].decode("latin1"))
        expected = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode()).digest()
        ).decode()
        check("sec-websocket-accept correct", expected.encode() in head)

        header = read_exact(sock, 2)
        length = header[1] & 0x7F
        if length == 126:
            length = struct.unpack(">H", read_exact(sock, 2))[0]
        elif length == 127:
            length = struct.unpack(">Q", read_exact(sock, 8))[0]
        frame = json.loads(read_exact(sock, length))
        check("ws frame is snapshot", frame.get("vehicle_id") == "VH0001", str(frame)[:80])
        check("ws frame carries battery", "battery" in frame)
        sock.close()

    finally:
        server.terminate()
        try:
            server.wait(timeout=8)
        except subprocess.TimeoutExpired:
            server.kill()
        log_file.close()

    print()
    if failures:
        print("FAILED %d check(s): %s" % (len(failures), ", ".join(failures)))
        print("--- server log ---")
        print(log_path.read_text(encoding="utf-8", errors="replace")[-2000:])
        return 1

    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
