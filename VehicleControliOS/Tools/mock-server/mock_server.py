#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""车辆云 Mock 服务 —— 供 iOS 客户端联调，零第三方依赖（仅标准库）。

实现的接口（与 Sources/Services/VehicleAPI.swift 的占位契约一一对应）：
  GET  /oauth2/authorize                     授权页（PKCE，可 --auto-approve）
  POST /oauth2/authorize/approve             模拟用户点击「授权」
  POST /oauth2/token                         authorization_code / refresh_token
  GET  /v1/vehicles                          车辆列表
  GET  /v1/vehicles/{id}/status              状态快照
  POST /v1/vehicles/{id}/commands            指令下发（Idempotency-Key 去重）
  GET  /v1/vehicles/{id}/commands/{ticket}   指令回执（3 秒后转终态）
  POST /v1/push/subscriptions                设备令牌上报（204）
  GET  /v1/vehicles/{id}/stream              WebSocket 推送（可 --disable-ws 关闭）

用法：
  python mock_server.py                       # 监听 0.0.0.0:8000
  python mock_server.py --port 8000 --auto-approve
  python mock_server.py --disable-ws          # 强制客户端走轮询
  python mock_server.py --token-ttl 30        # 30 秒过期，用于测刷新链路
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import secrets
import socket
import struct
import sys
import threading
import time
import urllib.parse
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
COMMAND_TTL = 3.0          # 指令从受理到终态的模拟耗时（秒）
COMMAND_TIMEOUT = 45.0     # 超过该时长仍未完成则返回 expired

SEED_VEHICLES = [
    {
        "id": "VH0001",
        "vin": "LZ9DEMO0000000001",
        "display_name": "我的 C11",
        "model": "C11 智享版",
        "capabilities": ["lock", "trunk", "climate", "flash", "horn", "charging"],
    },
    {
        "id": "VH0002",
        "vin": "LZ9DEMO0000000002",
        "display_name": "家里那台 T03",
        "model": "T03 轻享版",
        "capabilities": ["lock", "climate", "flash"],
    },
]

SEED_LIVE = {
    "VH0001": {
        "locked": True,
        "trunk_open": False,
        "climate_on": False,
        "target": 22.0,
        "inside": 19.0,
        "charging": "idle",
        "percent": 78.0,
    },
    "VH0002": {
        "locked": True,
        "trunk_open": False,
        "climate_on": False,
        "target": 22.0,
        "inside": 21.5,
        "charging": "idle",
        "percent": 46.0,
    },
}


# ---------------------------------------------------------------- 工具函数

def iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_from(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_b64url(value: str) -> str:
    digest = hashlib.sha256(value.encode("utf-8")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def b64url_raw(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def fake_gateway_jwt(account_id: str, ttl: int = 21600) -> str:
    """构造三段式 JWT：客户端要从签名段派生 signKey，段数必须为 3。"""
    header = b64url_raw(json.dumps({"alg": "HS256", "typ": "JWT"}).encode("utf-8"))
    payload = b64url_raw(json.dumps(
        {"sub": account_id, "exp": int(time.time()) + ttl}).encode("utf-8"))
    signature = b64url_raw(secrets.token_bytes(32))
    return "%s.%s.%s" % (header, payload, signature)


def gateway_session_payload(account_id: str, ttl: int = 21600) -> dict:
    """新网关登录/续期的统一返回体。"""
    return {
        "code": 0,
        "data": {
            "accountId": account_id,
            "accessToken": fake_gateway_jwt(account_id, ttl),
            "refreshToken": secrets.token_hex(16),
            "tokenExpireTime": int(time.time() * 1000) + ttl * 1000,
            "signParam": {
                "r2": b64url_raw(secrets.token_bytes(32)),
                "r3": b64url_raw(secrets.token_bytes(32)),
            },
        },
    }


MOCK_SMS_CODE = "123456"

# 8x8 蓝色 PNG（1x1 太容易被当作坏图），base64 解码即字节流。
CHASSIS_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAFElEQVR4nGP8z8Dwn4GBgYGJAQQAOf0E90EZt1AAAAAASUVORK5CYII="
)


def _ctl_action(cmdid: str, state: dict) -> tuple[str, dict]:
    """官方 cmdid + state → Mock 内部动作名（模拟车端执行效果）。"""
    value = str(state.get("value", "")).lower()
    if cmdid == "110":
        return ("lock" if value == "lock" else "unlock"), {}
    if cmdid == "130":
        return ("trunk_open" if value == "true" else "trunk_close"), {}
    if cmdid == "120":
        return "flash_lights", {}
    if cmdid == "170":
        if str(state.get("operate", "")) == "off":
            return "climate_off", {}
        return "climate_on", {"target_celsius": str(state.get("temperature", "22"))}
    if cmdid == "193":
        return ("charge_start" if value == "start" else "charge_stop"), {}
    if cmdid == "230":
        return "window_close", {}
    return "noop", {}


def ws_text_frame(payload: bytes) -> bytes:
    """服务端 -> 客户端文本帧（不掩码）。"""
    header = bytearray([0x81])
    size = len(payload)
    if size < 126:
        header.append(size)
    elif size < 65536:
        header.append(126)
        header += struct.pack(">H", size)
    else:
        header.append(127)
        header += struct.pack(">Q", size)
    return bytes(header) + payload


# ---------------------------------------------------------------- 内存状态

class MockState:
    def __init__(self, fail_action: str | None, token_ttl: int):
        self.lock = threading.RLock()
        self.fail_action = fail_action
        self.token_ttl = token_ttl
        self.started_at = time.time()

        self.vehicles = {v["id"]: v for v in SEED_VEHICLES}
        self.live = {k: dict(v) for k, v in SEED_LIVE.items()}

        self.tickets: dict[str, dict] = {}
        self.idempotency: dict[tuple[str, str], str] = {}
        self.pending_auth: dict[str, dict] = {}
        self.codes: dict[str, dict] = {}
        self.access: dict[str, dict] = {}
        self.refresh: dict[str, dict] = {}

    # ---- OAuth

    def issue_code(self, params: dict) -> str:
        code = "ac_" + secrets.token_urlsafe(18)
        with self.lock:
            self.codes[code] = {
                "code_challenge": params.get("code_challenge", ""),
                "redirect_uri": params.get("redirect_uri", ""),
                "client_id": params.get("client_id", ""),
                "expires_at": time.time() + 300,
            }
        return code

    def issue_tokens(self, client_id: str | None = None) -> dict:
        access = "at_" + secrets.token_urlsafe(24)
        refresh = "rt_" + secrets.token_urlsafe(24)
        with self.lock:
            self.access[access] = {
                "refresh": refresh,
                "expires_at": time.time() + self.token_ttl,
            }
            self.refresh[refresh] = {"access": access}
        return {
            "access_token": access,
            "refresh_token": refresh,
            "expires_in": self.token_ttl,
            "token_type": "Bearer",
            "scope": "vehicle.read vehicle.control",
        }

    def rotate_tokens(self, refresh_token: str) -> dict | None:
        with self.lock:
            entry = self.refresh.pop(refresh_token, None)
            if not entry:
                return None
            self.access.pop(entry["access"], None)
        return self.issue_tokens()

    def is_valid_token(self, token: str) -> bool:
        with self.lock:
            entry = self.access.get(token)
            return bool(entry) and entry["expires_at"] > time.time()

    # ---- 车辆状态

    def snapshot(self, vehicle_id: str) -> dict:
        with self.lock:
            live = self.live[vehicle_id]
            elapsed_minutes = (time.time() - self.started_at) / 60.0
            percent = max(5.0, live["percent"] - int(elapsed_minutes / 10))
            return {
                "vehicle_id": vehicle_id,
                "captured_at": iso_now(),
                "battery": {
                    "percent": round(percent, 1),
                    "range_km": round(percent * 5.2, 1),
                    "charging": live["charging"],
                    "charge_limit_percent": 90,
                },
                "climate": {
                    "is_on": live["climate_on"],
                    "target_celsius": live["target"],
                    "inside_celsius": live["inside"],
                },
                "security": {
                    "is_locked": live["locked"],
                    "trunk_open": live["trunk_open"],
                    "windows_closed": True,
                },
                "location": {"latitude": 30.2741, "longitude": 120.1551},
            }

    # ---- 指令

    def create_ticket(
        self,
        vehicle_id: str,
        action: str,
        parameters: dict,
        idempotency_key: str,
    ) -> dict:
        with self.lock:
            if idempotency_key:
                cached = self.idempotency.get((vehicle_id, idempotency_key))
                if cached and cached in self.tickets:
                    return self.tickets[cached]

            ticket_id = "T-" + uuid.uuid4().hex[:12].upper()
            now = time.time()
            ticket = {
                "ticket_id": ticket_id,
                "vehicle_id": vehicle_id,
                "action": action,
                "parameters": parameters,
                "requested_at": iso_now(),
                "ready_at": now + COMMAND_TTL,
                "expires_at": now + COMMAND_TIMEOUT,
            }
            self.tickets[ticket_id] = ticket
            if idempotency_key:
                self.idempotency[(vehicle_id, idempotency_key)] = ticket_id

            self._apply_effect(vehicle_id, action, parameters)
            return ticket

    def _apply_effect(self, vehicle_id: str, action: str, parameters: dict) -> None:
        # 失败指令不改变车辆状态，便于验证「失败后状态保持不变」。
        if self.fail_action and action == self.fail_action:
            return
        live = self.live.get(vehicle_id)
        if not live:
            return
        if action == "lock":
            live["locked"] = True
        elif action == "unlock":
            live["locked"] = False
        elif action == "trunk_toggle":
            live["trunk_open"] = not live["trunk_open"]
        elif action == "trunk_open":
            live["trunk_open"] = True
        elif action == "trunk_close":
            live["trunk_open"] = False
        elif action == "climate_on":
            live["climate_on"] = True
            try:
                live["target"] = float(parameters.get("target_celsius", live["target"]))
            except (TypeError, ValueError):
                pass
        elif action == "climate_off":
            live["climate_on"] = False
        elif action == "charge_start":
            live["charging"] = "charging"
        elif action == "charge_stop":
            live["charging"] = "idle"

    def ticket_status(self, ticket: dict) -> str:
        now = time.time()
        if now < ticket["ready_at"]:
            return "dispatched"
        if self.fail_action and ticket["action"] == self.fail_action:
            return "failed"
        if now > ticket["expires_at"] + COMMAND_TIMEOUT:
            return "expired"
        return "succeeded"

    def ticket_summary(self, ticket: dict) -> dict:
        return {
            "ticket_id": ticket["ticket_id"],
            "status": self.ticket_status(ticket),
            "requested_at": ticket["requested_at"],
        }

    def receipt(self, ticket: dict) -> dict:
        status = self.ticket_status(ticket)
        finished = status in ("succeeded", "failed", "expired")
        return {
            "ticket_id": ticket["ticket_id"],
            "status": status,
            "failure_reason": (
                "车辆未连接充电枪（mock 固定失败，可用 --fail-action none 关闭）"
                if status == "failed"
                else None
            ),
            "completed_at": iso_from(ticket["ready_at"]) if finished else None,
        }


# ---------------------------------------------------------------- HTTP 处理

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "VehicleMock/1.0"

    state: MockState  # 由 main() 注入

    # ---- 基础响应

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: int, code: str, message: str) -> None:
        self._json(status, {"code": code, "message": message})

    def _html(self, status: int, html: str) -> None:
        body = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _redirect(self, location: str) -> None:
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _no_content(self) -> None:
        self.send_response(204)
        self.end_headers()

    # ---- 请求解析

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _form(self) -> dict:
        raw = self._read_body().decode("utf-8", errors="replace")
        parsed = urllib.parse.parse_qs(raw)
        return {k: v[0] for k, v in parsed.items()}

    def _auth_ok(self) -> bool:
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            self._error(401, "unauthorized", "缺少 Bearer 令牌")
            return False
        if not self.state.is_valid_token(header[7:].strip()):
            self._error(401, "token_expired", "令牌无效或已过期")
            return False
        return True

    def _pause(self) -> None:
        if self.server.options.latency > 0:
            time.sleep(self.server.options.latency)

    def log_message(self, fmt, *args):  # noqa: D102
        if getattr(self.server.options, "quiet", False):
            return
        sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    # ---- 路由

    def do_GET(self):  # noqa: N802
        self._pause()
        try:
            self._route_get()
        except Exception as exc:  # 兜底，避免连接被静默掐断
            self._error(500, "internal_error", repr(exc))

    def do_POST(self):  # noqa: N802
        self._pause()
        try:
            self._route_post()
        except Exception as exc:
            self._error(500, "internal_error", repr(exc))

    def _route_get(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        # ---- 车主服务 GET 端点（接口 12/14/17-19）
        if path == "/carownerservice/v3/api/healthyCharging/queryPushState":
            if self._auth_ok():
                self._json(200, {"code": 0, "data": "1"})
            return

        if path == "/carownerservice/v3/api/drivingrecord/mileage/energy/detail":
            if self._auth_ok():
                self._driving_detail()
            return

        if path == "/carownerservice/v3/api/drivingrecord/getLastNweeks100kmECAndRank":
            if self._auth_ok():
                self._json(200, {"code": 0, "data": {
                    "weekEc": [
                        {"week": "W-%d" % i, "ec": 12.5 + i * 0.7}
                        for i in range(1, 7)
                    ],
                    "rankPercent": 23.0,
                }})
            return

        if path == "/carownerservice/v3/api/chassis/query":
            if self._auth_ok():
                base = "http://" + (self.headers.get("Host") or "127.0.0.1:8000")
                self._json(200, {"code": 0, "result": 0, "data": {
                    "fileUrl": base + "/static/chassis-photo.png",
                    "uploadTime": int(time.time() * 1000) - 3600_000,
                }})
            return

        if path == "/static/chassis-photo.png":
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(CHASSIS_PNG)))
            self.end_headers()
            self.wfile.write(CHASSIS_PNG)
            return

        if path in ("/", "/healthz"):
            self._json(200, {
                "status": "ok",
                "time": iso_now(),
                "vehicles": list(self.state.vehicles.keys()),
                "fail_action": self.state.fail_action,
                "websocket": not self.server.options.disable_ws,
            })
            return

        if path == "/oauth2/authorize":
            self._authorize(query)
            return

        if path == "/app-user/applogin/compliance/sendmessagecode":
            self._send_sms_code(query)
            return

        if path == "/app/app-global-service/v1/vehicle/list":
            if self._auth_ok():
                self._vehicle_list()
            return

        if path == "/app/app-control-service/v3/api/appremotectl/query":
            if self._auth_ok():
                self._remote_ctl_query(query)
            return

        if path == "/app/app-global-service/v1/vehicle/getCarRoute":
            if self._auth_ok():
                vin = (query.get("vin") or [""])[0]
                base = "http://" + (self.headers.get("Host") or "127.0.0.1:8000")
                self._json(200, {"code": 0, "data": {
                    "appRegion": base,
                    "appCenter": base,
                    "vin": vin,
                }})
            return

        if path == "/v1/vehicles":
            if self._auth_ok():
                self._json(200, {"vehicles": list(self.state.vehicles.values())})
            return

        match = re.fullmatch(r"/v1/vehicles/([^/]+)/status", path)
        if match:
            vehicle_id = match.group(1)
            if vehicle_id not in self.state.vehicles:
                self._error(404, "vehicle_not_found", "车辆不存在")
                return
            if self._auth_ok():
                self._json(200, self.state.snapshot(vehicle_id))
            return

        match = re.fullmatch(r"/v1/vehicles/([^/]+)/commands/([^/]+)", path)
        if match:
            ticket = self.state.tickets.get(match.group(2))
            if not ticket:
                self._error(404, "ticket_not_found", "指令工单不存在")
                return
            if self._auth_ok():
                self._json(200, self.state.receipt(ticket))
            return

        match = re.fullmatch(r"/v1/vehicles/([^/]+)/stream", path)
        if match:
            if self._auth_ok():
                self._stream(match.group(1))
            return

        self._error(404, "not_found", "未知路径 %s" % path)

    def _route_post(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/oauth2/authorize/approve":
            state = self._form().get("state", "")
            self._approve(state)
            return

        if path == "/oauth2/token":
            self._token()
            return

        if path == "/app-user/applogin/check_login_with_phone":
            self._sms_login()
            return

        if path == "/base/base-user/account/v1/login":
            self._gateway_login()
            return

        if path == "/base/base-user/token/v1/refresh":
            self._gateway_refresh()
            return

        if path == "/app/app-signal-service/signal/info/query":
            if self._auth_ok():
                self._signal_query()
            return

        if path == "/app/app-control-service/v3/api/appremotectl":
            if self._auth_ok():
                self._remote_ctl()
            return

        if path == "/carownerservice/v3/api/appoperate/verifyoperatepwdnew":
            if self._auth_ok():
                self._verify_operate_pwd()
            return

        if path == "/carownerservice/v3/api/healthyCharging/control":
            if self._auth_ok():
                self._json(200, {"code": 0, "result": 0, "message": "设置成功"})
            return

        if path == "/v1/push/subscriptions":
            self._read_body()
            if self._auth_ok():
                self._no_content()
            return

        match = re.fullmatch(r"/v1/vehicles/([^/]+)/commands", path)
        if match:
            self._create_command(match.group(1))
            return

        self._error(404, "not_found", "未知路径 %s" % path)

    # ---- 官方账号登录（appuser 旧链路 + global-master 新网关）

    def _send_sms_code(self, query: dict) -> None:
        phone = (query.get("phoneNo") or [""])[0]
        if not phone:
            self._json(200, {"code": 100116, "result": 100116,
                             "message": "手机号格式非法", "data": None})
            return
        if phone.endswith("0000"):
            self._json(200, {"code": 100117, "result": 100117,
                             "message": "验证码发送过于频繁", "data": None})
            return
        # bizStyle=http：模拟部分端点的 HTTP 风格成功码 {"code":200}
        if (query.get("bizStyle") or [""])[0] == "http":
            self._json(200, {"code": 200, "result": 0,
                             "message": "操作成功", "data": None})
            return
        self._json(200, {"code": 0, "result": 0, "message": "请求成功", "data": None})

    def _sms_login(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        params = {k: (v[0] if v else "")
                  for k, v in urllib.parse.parse_qs(parsed.query).items()}
        if not params.get("phoneNoCiphertext"):
            self._json(200, {"code": 100116, "result": 100116,
                             "message": "手机号密文缺失", "data": None})
            return
        if params.get("smsCode") != MOCK_SMS_CODE:
            self._json(200, {"code": 100115, "result": 100115,
                             "message": "验证码错误或已失效", "data": None})
            return
        # 复刻服务端风控：os 必须是官方固定值 android，否则拒绝登录（100132）。
        if params.get("os") != "android":
            self._json(200, {"code": 100132, "result": 100132,
                             "message": "登录校验未通过", "data": None})
            return
        self._json(200, {
            "code": 0,
            "result": 0,
            "message": "请求成功",
            "data": {
                "appLoginVO": {
                    "accountId": "11987654321",
                    "token": secrets.token_hex(16),
                    "refreshToken": secrets.token_hex(16),
                    "tokenExpired": 21600,
                }
            },
        })

    def _gateway_login(self) -> None:
        raw = self._read_body()
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            body = {}
        security = body.get("security")
        if not security:
            self._json(200, {"code": 1001, "message": "缺少 security（旧 token）", "data": None})
            return
        account = str(body.get("identifier") or "11987654321")
        payload = gateway_session_payload(account)
        self._register_gateway_tokens(payload["data"])
        self._json(200, payload)

    def _gateway_refresh(self) -> None:
        raw = self._read_body()
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            body = {}
        if not body.get("refreshToken"):
            self._json(200, {"code": 401, "message": "refreshToken 无效", "data": None})
            return
        payload = gateway_session_payload("11987654321")
        self._register_gateway_tokens(payload["data"])
        self._json(200, payload)

    def _register_gateway_tokens(self, data: dict) -> None:
        """把新网关签发的 JWT 登记到令牌表，供业务接口 Bearer 校验。"""
        access = data.get("accessToken")
        refresh = data.get("refreshToken")
        if not access:
            return
        with self.state.lock:
            self.state.access[access] = {
                "refresh": refresh,
                "expires_at": time.time() + 21600,
            }

    def _verify_operate_pwd(self) -> None:
        form = self._form()
        if not form.get("vin") or not form.get("oprpwd"):
            self._json(200, {"code": 1001, "message": "vin 或 oprpwd 缺失"})
            return
        self._json(200, {"code": 0, "result": 0, "message": "操作密码正确"})

    def _driving_detail(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        params = {k: (v[0] if v else "") for k, v in
                  urllib.parse.parse_qs(parsed.query).items()}
        begin = int(params.get("begintime") or 0)
        # 7 天窗口（毫秒）返回逐日明细；更大窗口只返回总量。
        if begin and (int(time.time() * 1000) - begin) <= 8 * 86_400_000:
            self._json(200, {"code": 0, "data": {
                "totalMileage": 284.6, "totalEnergy": 41.2, "totalFuel": 0,
                "averageEnergy": 14.5,
                "detail": [
                    {"day": "2026-11-%02d" % day, "accumulatedMileage": 12.5 + day * 1.7}
                    for day in range(7, 14)
                ],
            }})
        else:
            self._json(200, {"code": 0, "data": {
                "totalMileage": 12845.6, "totalEnergy": 1820.4, "totalFuel": 0,
                "averageEnergy": 14.2, "detail": [],
            }})

    # ---- 官方业务接口（车辆 / 车况 / 控车）

    def _vehicle_list(self) -> None:
        vehicles = []
        for vehicle in self.state.vehicles.values():
            vehicles.append({
                "vin": vehicle["id"],
                "carType": vehicle.get("model", ""),
                "licensePlate": "沪A·D" + vehicle["id"][-4:],
                "vehicleName": vehicle.get("display_name", "我的车辆"),
                "nickName": vehicle.get("display_name", "")[:2],
                "isOwner": True,
                "funcConfig": {
                    "HVAC": {"temperature": {"min": 16, "max": 32}},
                    "FRIDGE": {"targetTemp": {"min": -6, "max": 15}},
                    "WINDOW": {"positions": ["front_left", "front_right"]},
                },
            })
        self._json(200, {"code": 0, "message": "请求成功", "data": vehicles})

    def _signal_map(self, vehicle_id: str) -> dict:
        live = self.state.live[vehicle_id]
        charging_map = {"idle": 0, "charging": 1, "complete": 2, "fault": 3}
        range_km = int(round(live["percent"] * 5.2))
        return {
            "1204": str(int(round(live["percent"]))),
            "100003": "%.1f" % live["percent"],
            "3257": str(range_km),
            "3260": str(range_km),
            "1149": str(charging_map.get(live["charging"], 0)),
            "1200": "45" if live["charging"] == "charging" else "0",
            "1318": "12845.6",
            "1319": "0",
            "1010": "P",
            "1944": "0",
            "1480": "1",
            "1298": "1" if live["locked"] else "0",
            "1281": "1" if live["trunk_open"] else "0",
            "1693": "0", "1694": "0", "1695": "0", "1696": "0",
            "1938": "1" if live["climate_on"] else "0",
            "2183": "%.1f" % live["target"],
            "1349": "%.1f" % live["inside"],
            "1941": "3",
            "2100": "0", "2101": "0", "1816": "0",
            "2646": "2.4", "2653": "2.4", "2660": "2.4", "2667": "2.4",
            "3724": "120.1551", "3725": "30.2741",
            "10709": "0", "10707": "4", "10708": "0",
        }

    def _signal_query(self) -> None:
        raw = self._read_body()
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            body = {}
        vin = str(body.get("vin") or "")
        if vin not in self.state.live:
            self._json(200, {"code": 404, "message": "车辆不存在", "data": None})
            return
        self._json(200, {"code": 0, "data": {"signalMap": self._signal_map(vin)}})

    def _remote_ctl(self) -> None:
        form = self._form()
        vin = form.get("carvin", "")
        if vin not in self.state.live:
            self._json(200, {"result": 404, "message": "车辆不存在"})
            return
        try:
            state = json.loads(form.get("state") or "{}")
        except json.JSONDecodeError:
            state = {}
        action, parameters = _ctl_action(form.get("cmdid", ""), state)
        ticket = self.state.create_ticket(vin, action, parameters, "")
        self._json(200, {"result": 0, "data": ticket["ticket_id"]})

    def _remote_ctl_query(self, query: dict) -> None:
        msg_id = (query.get("msgID") or [""])[0]
        ticket = self.state.tickets.get(msg_id)
        if not ticket:
            self._json(200, {"result": 404, "message": "指令不存在"})
            return
        if time.time() >= ticket["ready_at"]:
            self._json(200, {"result": 0, "data": "1"})
        else:
            self._json(200, {"result": 0, "data": "0"})

    # ---- OAuth

    def _authorize(self, query: dict) -> None:
        params = {k: (v[0] if v else "") for k, v in query.items()}
        if not params.get("redirect_uri"):
            self._error(400, "invalid_request", "缺少 redirect_uri")
            return

        state = params.get("state") or uuid.uuid4().hex
        params["state"] = state
        with self.state.lock:
            self.state.pending_auth[state] = params

        if self.server.options.auto_approve:
            self._approve(state)
            return

        self._html(200, AUTHORIZE_PAGE.format(
            client_id=params.get("client_id", ""),
            scope=params.get("scope", ""),
            redirect_uri=params.get("redirect_uri", ""),
            state=state,
        ))

    def _approve(self, state: str) -> None:
        with self.state.lock:
            params = self.state.pending_auth.pop(state, None)
        if not params:
            self._error(400, "invalid_state", "授权上下文不存在或已过期")
            return

        code = self.state.issue_code(params)
        redirect_uri = params.get("redirect_uri", "")
        separator = "&" if "?" in redirect_uri else "?"
        location = "%s%scode=%s&state=%s" % (
            redirect_uri,
            separator,
            urllib.parse.quote(code),
            urllib.parse.quote(state),
        )
        self._redirect(location)

    def _token(self) -> None:
        form = self._form()
        grant = form.get("grant_type", "")

        if grant == "authorization_code":
            code = form.get("code", "")
            with self.state.lock:
                stored = self.state.codes.pop(code, None)
            if not stored:
                self._error(400, "invalid_grant", "code 无效或已被使用")
                return
            if stored["expires_at"] < time.time():
                self._error(400, "invalid_grant", "code 已过期")
                return
            challenge = stored.get("code_challenge")
            if challenge:
                verifier = form.get("code_verifier", "")
                if sha256_b64url(verifier) != challenge:
                    self._error(400, "invalid_grant", "PKCE code_verifier 校验失败")
                    return
            self._json(200, self.state.issue_tokens(form.get("client_id")))
            return

        if grant == "refresh_token":
            tokens = self.state.rotate_tokens(form.get("refresh_token", ""))
            if not tokens:
                self._error(400, "invalid_grant", "refresh_token 无效")
                return
            self._json(200, tokens)
            return

        self._error(400, "unsupported_grant_type", "不支持的 grant_type：%s" % grant)

    # ---- 指令

    def _create_command(self, vehicle_id: str) -> None:
        body = self._read_body()
        if vehicle_id not in self.state.vehicles:
            self._error(404, "vehicle_not_found", "车辆不存在")
            return
        try:
            payload = json.loads(body or b"{}")
        except json.JSONDecodeError:
            self._error(400, "invalid_request", "请求体不是合法 JSON")
            return

        action = payload.get("action")
        if not action:
            self._error(400, "invalid_request", "缺少 action")
            return

        if not self._auth_ok():
            return

        ticket = self.state.create_ticket(
            vehicle_id=vehicle_id,
            action=action,
            parameters=payload.get("parameters") or {},
            idempotency_key=self.headers.get("Idempotency-Key", ""),
        )
        self._json(202, self.state.ticket_summary(ticket))

    # ---- WebSocket 推送

    def _stream(self, vehicle_id: str) -> None:
        if vehicle_id not in self.state.vehicles:
            self._error(404, "vehicle_not_found", "车辆不存在")
            return
        if self.server.options.disable_ws:
            self._error(501, "ws_disabled", "已用 --disable-ws 关闭 WebSocket")
            return

        key = self.headers.get("Sec-WebSocket-Key")
        upgrade = (self.headers.get("Upgrade") or "").lower()
        if upgrade != "websocket" or not key:
            self._error(400, "upgrade_required", "需要 WebSocket 握手")
            return

        accept = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode("ascii")).digest()
        ).decode("ascii")

        self.close_connection = True
        self.wfile.write((
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: %s\r\n\r\n" % accept
        ).encode("ascii"))
        self.wfile.flush()

        sock = self.connection
        interval = self.server.options.push_interval
        self.log_message("WS 已连接 vehicle=%s", vehicle_id)
        try:
            while True:
                snapshot = self.state.snapshot(vehicle_id)
                sock.sendall(ws_text_frame(json.dumps(snapshot, ensure_ascii=False).encode("utf-8")))
                if not self._drain(sock, interval):
                    break
        except OSError:
            pass
        finally:
            self.log_message("WS 已断开 vehicle=%s", vehicle_id)

    @staticmethod
    def _drain(sock: socket.socket, seconds: float) -> bool:
        """在推送间隔内读取客户端帧（close/ping），返回 False 表示连接已关闭。"""
        deadline = time.time() + seconds
        sock.settimeout(0.05)
        while time.time() < deadline:
            try:
                data = sock.recv(4096)
                if not data:
                    return False
            except socket.timeout:
                continue
            except OSError:
                return False
        return True


AUTHORIZE_PAGE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mock 授权</title>
<style>
  body {{ font-family: -apple-system, "PingFang SC", sans-serif; margin: 0; padding: 32px 24px;
         background: #f2f2f7; color: #1c1c1e; }}
  .card {{ background: #fff; border-radius: 16px; padding: 24px; box-shadow: 0 2px 12px rgba(0,0,0,.06); }}
  h1 {{ font-size: 20px; margin: 0 0 12px; }}
  dl {{ font-size: 13px; color: #6b6b70; margin: 16px 0; }}
  dt {{ margin-top: 8px; }}
  dd {{ margin: 2px 0 0; color: #1c1c1e; word-break: break-all; }}
  button {{ width: 100%; margin-top: 20px; padding: 14px; font-size: 16px; font-weight: 600;
            color: #fff; background: #0a84ff; border: 0; border-radius: 12px; }}
  .hint {{ font-size: 12px; color: #8e8e93; margin-top: 14px; line-height: 1.5; }}
</style>
</head>
<body>
  <div class="card">
    <h1>授权车辆控制</h1>
    <p style="font-size:14px;color:#3c3c43;">Mock 服务将向应用授予以下权限：</p>
    <dl>
      <dt>client_id</dt><dd>{client_id}</dd>
      <dt>scope</dt><dd>{scope}</dd>
      <dt>redirect_uri</dt><dd>{redirect_uri}</dd>
    </dl>
    <form method="post" action="/oauth2/authorize/approve">
      <input type="hidden" name="state" value="{state}">
      <button type="submit">授权并继续</button>
    </form>
    <div class="hint">这是本地 Mock 服务生成的页面，仅用于开发联调，不对应任何真实账号。</div>
  </div>
</body>
</html>
"""


# ---------------------------------------------------------------- 入口

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="车辆云 Mock 服务（iOS 客户端联调用）")
    parser.add_argument("--host", default="0.0.0.0", help="监听地址，真机调试用局域网 IP")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--fail-action", default="charge_start",
                        help="固定失败的 action（默认 charge_start；传 none 关闭）")
    parser.add_argument("--token-ttl", type=int, default=3600, help="access_token 有效期（秒）")
    parser.add_argument("--push-interval", type=float, default=2.0, help="WebSocket 推送间隔（秒）")
    parser.add_argument("--latency", type=float, default=0.0, help="每个请求附加延迟（秒），模拟弱网")
    parser.add_argument("--auto-approve", action="store_true", help="跳过授权页，直接回调")
    parser.add_argument("--disable-ws", action="store_true", help="关闭 WebSocket，强制走轮询")
    parser.add_argument("--quiet", action="store_true", help="不打印请求日志")
    args = parser.parse_args(argv)

    fail_action = None if (args.fail_action or "").lower() in ("none", "") else args.fail_action
    Handler.state = MockState(fail_action=fail_action, token_ttl=args.token_ttl)

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.options = args  # type: ignore[attr-defined]

    host = "127.0.0.1" if args.host in ("0.0.0.0", "") else args.host
    print("车辆云 Mock 服务已启动")
    print("  API      : http://%s:%d" % (host, args.port))
    print("  推送     : %s" % ("已关闭（轮询模式）" if args.disable_ws
                              else "ws://%s:%d/v1/vehicles/{id}/stream" % (host, args.port)))
    print("  车辆     : VH0001 / VH0002")
    print("  固定失败 : %s" % (fail_action or "未开启"))
    print("  令牌有效期: %ds" % args.token_ttl)
    print("  授权页   : http://%s:%d/oauth2/authorize" % (host, args.port))
    print("按 Ctrl+C 停止\n", flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
