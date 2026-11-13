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

        # ---- 官方账号登录链路（RSA 手机号 → 短信登录 → 网关凭证交换 → 续期）
        status, _, body = request(
            "GET", "/app-user/applogin/compliance/sendmessagecode?phoneNo=MOCKCIPHER")
        envelope = json.loads(body)
        check("send sms 200", status == 200, str(status))
        check("send sms code=0", envelope.get("code") == 0, body[:80])

        status, _, body = request(
            "GET", "/app-user/applogin/compliance/sendmessagecode"
                   "?phoneNo=MOCKCIPHER&bizStyle=http")
        http_style = json.loads(body)
        check("send sms http-style code=200",
              http_style.get("code") == 200 and http_style.get("result") == 0, body[:80])

        status, _, body = request(
            "GET", "/app-user/applogin/compliance/sendmessagecode?phoneNo=MOCK0000")
        check("send sms throttle 100117", json.loads(body).get("code") == 100117, body[:80])

        status, _, body = request(
            "POST", "/app-user/applogin/check_login_with_phone"
                    "?phoneNoCiphertext=MOCKCIPHER&smsCode=000000&deviceID=d1&os=ios")
        check("sms login wrong code 100115", json.loads(body).get("code") == 100115, body[:80])

        # 风控复刻：os 非 android 必须被拒绝（100132 触发条件回归）。
        status, _, body = request(
            "POST", "/app-user/applogin/check_login_with_phone"
                    "?phoneNoCiphertext=MOCKCIPHER&smsCode=123456&deviceID=d1&os=ios")
        check("sms login os=ios rejected 100132",
              json.loads(body).get("code") == 100132, body[:80])

        status, _, body = request(
            "POST", "/app-user/applogin/check_login_with_phone"
                    "?phoneNoCiphertext=MOCKCIPHER&smsCode=123456&deviceID=d1&os=android")
        login = json.loads(body)
        legacy = (login.get("data") or {}).get("appLoginVO") or {}
        check("sms login ok", login.get("code") == 0 and bool(legacy.get("token")), body[:100])

        status, _, body = request(
            "POST", "/base/base-user/account/v1/login",
            body=json.dumps({
                "identifier": legacy.get("accountId"),
                "identifierType": "1",
                "security": legacy.get("token"),
            }),
            headers={"Content-Type": "application/json"},
        )
        gateway = json.loads(body)
        data = gateway.get("data") or {}
        access = data.get("accessToken") or ""
        check("gateway exchange ok", gateway.get("code") == 0, body[:100])
        check("gateway jwt has 3 segments", access.count(".") == 2, access[:40])
        check("gateway carries signParam",
              bool((data.get("signParam") or {}).get("r2")), body[:120])
        check("gateway expire is ms", (data.get("tokenExpireTime") or 0) > 10 ** 12)

        status, _, body = request(
            "POST", "/base/base-user/token/v1/refresh",
            body=json.dumps({"refreshToken": data.get("refreshToken")}),
            headers={"Content-Type": "application/json"},
        )
        refreshed = json.loads(body)
        check("gateway refresh ok", refreshed.get("code") == 0, body[:100])
        check("refresh rotates accessToken",
              (refreshed.get("data") or {}).get("accessToken") != access)

        # ---- 官方业务接口（车辆列表 / signalMap / 控车下发与轮询）
        gw_headers = {"Authorization": "Bearer " + (refreshed.get("data") or {}).get("accessToken", "")}

        status, _, body = request("GET", "/app/app-global-service/v1/vehicle/list",
                                  headers=gw_headers)
        vehicles = (json.loads(body).get("data") or [])
        check("official vehicle list ok", status == 200 and len(vehicles) >= 2, body[:120])
        check("official vehicle list has vin",
              bool(vehicles and vehicles[0].get("vin")), str(vehicles[:1])[:120])

        status, _, body = request(
            "POST", "/app/app-signal-service/signal/info/query",
            body=json.dumps({"vin": vehicles[0]["vin"]}),
            headers=dict(gw_headers, **{"Content-Type": "application/json"}),
        )
        signal_map = ((json.loads(body).get("data") or {}).get("signalMap") or {})
        check("signalMap returned", status == 200 and bool(signal_map), body[:120])
        check("signalMap has soc+range",
              "1204" in signal_map and "3257" in signal_map, str(list(signal_map))[:120])

        control_form = urllib.parse.urlencode({
            "cmdid": "110",
            "carvin": vehicles[0]["vin"],
            "state": json.dumps({"value": "lock"}),
            "timespan": "1",
            "nonce": "1",
            "deviceID": "smoke",
        })
        status, _, body = request(
            "POST", "/app/app-control-service/v3/api/appremotectl", body=control_form,
            headers=dict(gw_headers,
                         **{"Content-Type": "application/x-www-form-urlencoded"}),
        )
        sent = json.loads(body)
        msg_id = (sent.get("data") or "")
        check("remote control accepted", sent.get("result") == 0 and bool(msg_id), body[:120])

        status, _, body = request(
            "GET", "/app/app-control-service/v3/api/appremotectl/query?msgID=" + str(msg_id),
            headers=gw_headers,
        )
        polled = json.loads(body)
        check("remote control poll ok",
              polled.get("result") == 0 and str(polled.get("data")) in ("0", "1"), body[:120])

        # ---- 车主服务（接口 6/12/14/17-19）
        status, _, body = request(
            "POST", "/carownerservice/v3/api/appoperate/verifyoperatepwdnew",
            body="vin=LP1&oprpwd=CIPHER", headers=dict(
                gw_headers, **{"Content-Type": "application/x-www-form-urlencoded"}))
        verify = json.loads(body)
        check("operate pwd verify ok", verify.get("code") == 0, body[:80])

        status, _, body = request(
            "POST", "/carownerservice/v3/api/healthyCharging/control",
            body="vin=LP1&carvin=LP1&state=1&targetSoc=80", headers=dict(
                gw_headers, **{"Content-Type": "application/x-www-form-urlencoded"}))
        check("charge limit accepted", json.loads(body).get("code") == 0, body[:80])

        status, _, body = request(
            "GET", "/carownerservice/v3/api/healthyCharging/queryPushState?vin=LP1&carvin=LP1",
            headers=gw_headers)
        check("charge push state ok", json.loads(body).get("data") == "1", body[:80])

        status, _, body = request(
            "GET", "/carownerservice/v3/api/drivingrecord/mileage/energy/detail"
                   "?begintime=%d&endtime=%d&vin=LP1" % (
                       int(time.time() * 1000) - 7 * 86_400_000, int(time.time() * 1000)),
            headers=gw_headers)
        driving = (json.loads(body).get("data") or {})
        check("driving detail ok",
              bool(driving.get("detail")) and bool(driving.get("totalMileage")), body[:120])

        status, _, body = request(
            "GET", "/carownerservice/v3/api/drivingrecord/getLastNweeks100kmECAndRank?carvin=LP1",
            headers=gw_headers)
        weekly = (json.loads(body).get("data") or {})
        check("weekly energy ok",
              len(weekly.get("weekEc") or []) == 6 and "rankPercent" in weekly, body[:120])

        status, _, body = request(
            "GET", "/carownerservice/v3/api/chassis/query?vin=LP1&timespan=1&nonce=1"
                   "&deviceID=smoke&signStr=1", headers=gw_headers)
        photo = (json.loads(body).get("data") or {})
        check("parking photo meta ok", bool(photo.get("fileUrl")), body[:120])
        status, _, body = request("GET", "/static/chassis-photo.png")
        check("parking photo download ok",
              status == 200 and body[:4] == b"\x89PNG", "bytes=%d" % len(body))

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
