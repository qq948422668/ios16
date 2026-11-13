# VehicleControl（iOS 16）

车联网远程车控客户端框架：官方账号短信直连登录（零网页）、车辆状态实时推送（WebSocket 优先 /
轮询兜底）、异步指令下发与回执轮询、Keychain 凭证存储。SwiftUI + async/await，最低 iOS 16。

> **重要前提**：`VehicleAPI` 里的 path、`action` 取值、`Vehicle` / `VehicleSnapshot` 字段名
> 仍是**待替换的占位契约**；登录链路已按官方协议实现，见 §2「官方账号登录」。

---

## 1.5 官方接口移植对照表（v1.3.0）

| 能力 | 官方接口 | 代码落点 | 鉴权 |
|---|---|---|---|
| 车辆列表 | `GET /app/app-global-service/v1/vehicle/list` | `VehicleAPI.listVehicles` | 网关 HMAC + Bearer |
| 动态路由 | `GET /app/app-global-service/v1/vehicle/getCarRoute?vin=` | 文档同域，未单独发请求 | 同上 |
| 实时车况 | `POST /app/app-signal-service/signal/info/query` `{"vin"}` | `VehicleAPI.snapshot` → `VehicleSnapshot(vehicleId:signalMap:)` | 同上 |
| 控车下发 | `POST /app/app-control-service/v3/api/appremotectl`（form） | `RemoteVehicleService.send` | 网关 HMAC + `oppwd` AES |
| 控车轮询 | `GET /app/app-control-service/v3/api/appremotectl/query?msgID=` | `VehicleAPI.controlQuery`，首次 1s 后 500ms、上限 24s | 同上 |

signalMap 权威 ID 已按文档 §5.1 全量解码：`1204/100003`（电量）、`3257/3260`（续航）、`1149/1200`
（充电状态与倒计时）、`1318/1319/1010/1480`（里程/车速/挡位/EPB）、`1298/1281`（门锁/尾门）、
`1693–1696`（车窗）、`1938/2183/1349/1941`（空调）、`2100/2101/1816`（座椅/方向盘）、
`2646/2653/2660/2667`（胎压）、`3724/3725`（GCJ-02 坐标）、`10709/10707/10708`（冰箱）。

控车 cmdid 矩阵已落地 14 个入口：`110` 锁/解锁、`130` 尾门开/关、`120` 鸣笛闪灯、
`170` 空调开关/极速降温/极速升温/前挡除霜、`230` 关窗、`193` 充电 start/finish。

> 操作密码（4 位）仅存 Keychain，控车时按 `AES-128-CBC(md5Short(token[0..32]) / md5Short(token[32..64]))`
> 加密后作为 `oppwd` 提交，缺失时指令仍会下发，由车端决定是否拒绝。

---

## 2. 官方账号登录（接口直连，不加载网页）

登录在应用内直接调用官方接口完成，不再打开 `ASWebAuthenticationSession` 或 WebView。
主域：`https://appuser.leapmotor.cn`（旧链路）与
`https://app-gw-global-master.leapmotor.com`（新网关）。

### 2.1 请求序列

| 步骤 | 请求 | 说明 |
|---|---|---|
| ① 发送验证码 | `GET {appUserHost}/app-user/applogin/compliance/sendmessagecode?phoneNo={RSA密文}` | 手机号 `RSA/ECB/PKCS1Padding` 加密后 Base64URL 去填充 |
| ② 短信登录 | `POST {appUserHost}/app-user/applogin/check_login_with_phone?phoneNoCiphertext=…&smsCode=…&deviceID=…&smDeviceId=…&os=ios&pageUrl=…&timespan=…&nonce=…&signStr=…` | 业务参数全在 Query，Body 为空；`signStr = MD5(ASCII升序拼串)[8..<24]` 大写 |
| ③ 换网关凭证 | `POST {gatewayHost}/base/base-user/account/v1/login`，body `{"identifier","identifierType":"1","security":旧token}` | 未登录态签名 `sign = SHA256(signBase)` |
| ④ 续期 | `POST {gatewayHost}/base/base-user/token/v1/refresh`，body `{"refreshToken"}` | 已登录态 `sign = HmacSHA256(signKey, signBase)` |

公共头（参与签名）：`acceptLanguage=zh-CN`、`channel=1`、`deviceId`（32 位 hex）、
`deviceType=ios`、`nonce`、`source=leapmotor`、`timestamp`（毫秒）、`version`，
签名结果放 `sign`，并附 `x-api-signature-version: 2.0`。

### 2.2 参数与结果解析

- `phoneNo` / `phoneNoCiphertext`：RSA 密文（`LeapCrypto.encryptPhone`）；
- `smsCode`：6 位数字验证码；`deviceID`：`DeviceIdentity` 持久化的稳定 UUID；
- ③ 返回 `data.accessToken`（JWT）、`data.refreshToken`、`data.tokenExpireTime`（毫秒）、
  `data.signParam{r2,r3}`；
- `signKey[i] = JWT签名段[i] ⊕ base64url(r2)[i] ⊕ base64url(r3)[i]`（取最短长度）。

### 2.3 状态保存与跳转

登录成功后 `TokenPair` 写入 Keychain（双令牌 + signKey + accountId），
`SessionStore.state = .signedIn`，`RootView` 随状态切换到 `VehicleListView`。
续期提前 5 分钟触发；401/403 会强制续期一次，续期失败则清除会话回到登录页。

### 2.4 失败提示

| 场景 | 提示 |
|---|---|
| 手机号非法 | 请输入 11 位中国大陆手机号 |
| `code=100115` | 短信验证码错误或已失效，请重新获取 |
| `code=100117` | 验证码发送过于频繁，请 60 秒后再试（自动进入冷却） |
| `code=100116` | 手机号格式不正确 |
| HTTP 401/403 | 登录凭证已失效，请重新登录 |
| 网络/解析异常 | 网络异常，请检查网络后重试 / 登录响应解析失败 |

Mock 服务已同步实现上述端点：验证码恒为 `123456`，手机号以 `0000` 结尾触发 100117 频控。

---

## 1. 接口清单（占位契约）

| # | 功能 | Method | Path（占位） | 鉴权 | 请求 | 响应模型 |
|---|------|--------|--------------|------|------|----------|
| 1 | 车辆列表 | GET | `/v1/vehicles` | Bearer | — | `{ vehicles: [Vehicle] }` |
| 2 | 车辆状态 | GET | `/v1/vehicles/{vehicle_id}/status` | Bearer | — | `VehicleSnapshot` |
| 3 | 指令下发 | POST | `/v1/vehicles/{vehicle_id}/commands` | Bearer + `Idempotency-Key` | `{ action, parameters }` | `CommandTicket` |
| 4 | 指令回执 | GET | `/v1/vehicles/{vehicle_id}/commands/{ticket_id}` | Bearer | — | `CommandReceipt` |
| 5 | 状态推送 | WSS | `/v1/vehicles/{vehicle_id}/stream` | Bearer（Header） | — | 每帧一个 `VehicleSnapshot` |
| 6 | 授权页 | GET | `{authorization_endpoint}` | — | `response_type=code&client_id&redirect_uri&scope&code_challenge&code_challenge_method=S256&state` | 302 → `redirect_uri?code=...` |
| 7 | 换取令牌 | POST | `{token_endpoint}` | — | `application/x-www-form-urlencoded`：`grant_type=authorization_code&code&code_verifier&redirect_uri&client_id` | `TokenResponse` |
| 8 | 刷新令牌 | POST | `{token_endpoint}` | — | `grant_type=refresh_token&refresh_token&client_id` | `TokenResponse` |
| 9 | 上报推送令牌 | POST | `/v1/push/subscriptions` | Bearer | `{ device_token, platform, bundle_id }` | 204 / `{}` |
| 10 | 推送回执 | APNs | 由服务端下发 | — | `aps` + `cmd_result` | 见 §5 |

`VehicleSnapshot` 结构（`JSONCoding` 统一做 snake_case ↔ camelCase）：

```json
{
  "vehicle_id": "VH123456",
  "captured_at": "2026-11-12T07:21:03Z",
  "battery":  { "percent": 78, "range_km": 412, "charging": "idle", "charge_limit_percent": 90 },
  "climate":  { "is_on": false, "target_celsius": 22, "inside_celsius": 19 },
  "security": { "is_locked": true, "trunk_open": false, "windows_closed": true },
  "location": { "latitude": 30.27, "longitude": 120.15 }
}
```

`action` 占位取值：`lock` / `unlock` / `trunk_toggle` / `climate_on` / `climate_off` /
`flash_lights` / `horn` / `charge_start` / `charge_stop`。
指令为**异步链路**：`POST` 返回 2xx 只代表云端已受理，业务成功与否以回执
`status ∈ {succeeded, failed, expired}` 为准。

---

## 2. 与 Android 侧逻辑的对应关系

| Android 常见实现 | 本框架对应 | 说明 |
|---|---|---|
| OkHttp / Retrofit 接口声明 | `APIRequest<Response>` + `VehicleAPI` | 泛型即响应模型，Endpoint 目录集中管理 |
| OkHttp Interceptor 注入 token | `APIClient.build()` | 统一注入 `Authorization: Bearer` |
| Authenticator 401 重试 | `APIClient.send()` 单次刷新重放 | 刷新合并由 `AuthService` actor 保证 |
| SharedPreferences / MMKV 存 token | `KeychainTokenStore` | `AfterFirstUnlock + ThisDeviceOnly` |
| EventBus / LiveData 回调 | `AsyncStream<VehicleStreamEvent>` | SwiftUI 侧 `@Published` 消费 |
| 定时轮询 Handler | `HybridVehicleStream` | WebSocket 优先，断链降级 3s 轮询 |
| 指令结果轮询 | `awaitReceipt(for:vehicleId:)` | 1.2s 起、1.5× 退避、上限 5s、总超时 45s |
| 全局 Toast / Snackbar | `CommandPhase` + `CommandBanner` | submitting/running/succeeded/failed 四态 |

关键改写要点：

1. **凭证安全**：无 `client_secret` 落包，走 PKCE（S256）；token 进 Keychain，且
   `refresh_token` 轮换时用 actor 串行化，避免并发刷新把旧 refresh_token 用废。
2. **指令幂等**：`POST /commands` 使用 `RetryPolicy.none`，不参与网络层自动重试；
   每次下发带唯一 `Idempotency-Key`，用户手动重试时才需要复用同一个 key。
3. **状态一致性**：指令成功后主动 `refresh()` 一次，纠正推送延迟导致的状态滞后。
4. **错误分层**：`APIError` 区分传输 / 鉴权 / 业务码 / 解码 / 指令失败，UI 只显示
   `userMessage`，日志保留结构信息。
5. **登录承载**：直接调用官方账号接口（手机号 + 短信验证码），不打开网页、
   不内嵌 WebView；密码类凭据不落盘。
6. **前后台**：`URLSession` 配 `waitsForConnectivity`；如需后台刷新再补
   `BGAppRefreshTask`（当前仅前台流式刷新）。

目录：

```
VehicleControliOS/
├── project.yml                  # XcodeGen 工程描述
└── Sources/
    ├── App/                     # 入口、组合根、根视图
    ├── Core/Config/             # AppEnvironment（域名/ClientID/重定向）
    ├── Core/Networking/         # Endpoint、APIClient、错误、编解码
    ├── Core/Auth/               # PKCE、Keychain、AuthService、会话状态
    ├── Models/                  # Vehicle / Snapshot / Command / Ticket
    ├── Services/                # 接口目录、车控服务、状态推送
    └── Features/                # 登录、车辆列表、车控面板
```

---

## 3. 构建与打包流程（必须 macOS）

iOS 应用只能在 macOS 上用 Xcode 工具链编译、签名；Windows 环境无法产出可安装 IPA。

### 3.1 生成工程

```bash
brew install xcodegen          # 一次性
cd VehicleControliOS
xcodegen generate              # 产出 VehicleControl.xcodeproj
open VehicleControl.xcodeproj
```

在 target `VehicleControl` → Signing & Capabilities 选择你的 Team，Bundle Identifier 改成
自有域名（同时改 `project.yml` 与 `Info.plist` 的 `CFBundleURLSchemes`）。

### 3.2 模拟器验证

```bash
xcodebuild -project VehicleControl.xcodeproj -scheme VehicleControl \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

### 3.3 归档与导出 IPA

```bash
xcodebuild -project VehicleControl.xcodeproj -scheme VehicleControl \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/VehicleControl.xcarchive archive
```

`ExportOptions.plist`（Ad Hoc 示例）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>ad-hoc</string>
  <key>teamID</key><string>YOUR_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>stripSwiftSymbols</key><true/>
  <key>compileBitcode</key><false/>
  <key>provisioningProfiles</key>
  <dict>
    <key>com.vehiclecontrol.app</key>
    <string>YOUR_PROFILE_NAME</string>
  </dict>
</dict>
</plist>
```

```bash
xcodebuild -exportArchive \
  -archivePath build/VehicleControl.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/ipa
# 产物：build/ipa/VehicleControl.ipa
```

安装到设备需要满足以下任一条件：设备 UDID 已登记在该 Ad Hoc 描述文件中；
或走 App Store Connect / TestFlight（`method` 改 `app-store`，上传后由 TestFlight 分发）。

### 3.4 CI（无 Mac 本机时）

GitHub Actions `macos-14` runner 可直接跑上面三条命令，证书与描述文件用
`apple-actions/import-codesign-certs` + base64 密钥注入，产物用 `actions/upload-artifact` 取回。

---

## 4. 指令回执：推送优先 + 轮询兜底

轮询是**兜底**，不是主路径。`CommandReceiptResolving` 把策略抽象出来：

| 实现 | 使用条件 | 行为 |
|---|---|---|
| `PollingReceiptResolver` | `pushEnabled = false` | 纯轮询，模拟器可直接跑 |
| `PushFirstReceiptResolver` | `pushEnabled = true` | 先等 APNs 推送（默认最多 10s），超时退回轮询 |

链路：`POST /commands` → 拿到 `ticket_id` → 在 `CommandInbox` 上挂起等待 →
服务端指令状态变更时推 APNs → `AppDelegate` 解析 payload → `PushCoordinator` →
`inbox.deliver()` 唤醒等待者。推送**先于**等待到达时先入缓冲，避免时序竞争丢结果。

服务端推送 payload 约定（字段名需与你方 APNs 模板对齐）：

```json
{
  "aps": { "alert": { "title": "车控指令", "body": "后备箱已解锁" }, "sound": "default" },
  "cmd_result": { "ticket_id": "T-20261112-0001", "status": "succeeded" }
}
```

要点：

- 只有 `status.isTerminal`（`succeeded` / `failed` / `expired`）才投递，其余忽略，防止半途状态误判成功。
- `CommandInbox` 是 `actor`：等待与投递在不同线程也不会丢唤醒；超时用独立 `Task` 到点 resume，且 `removeValue` 保证不会二次 resume。
- 推送失败/用户关闭通知**不影响功能**：10 秒后自动退回轮询，UI 无感知。
- 需在 Xcode → Signing & Capabilities 勾选 **Push Notifications**（生成 `aps-environment` 权限），
  并在 Apple Developer 后台为 Bundle ID 开启该能力；否则 `registerForRemoteNotifications` 会失败并静默降级。

## 5. 后台刷新（BGAppRefreshTask）

`BackgroundRefresher` 在启动期注册 `com.vehiclecontrol.app.refresh`，每次执行：
拉车辆列表 → 逐台拉快照 → 写入 `SnapshotCache`（Caches 目录）→ 立刻提交下一次请求（15 分钟后为最早时间点）。
车控页 `start()` 会先用缓存渲染，网络结果到达后覆盖，冷启动不再白屏。

必读限制：

- iOS 把它当作**机会**而非定时器：通常 ≥15 分钟，低电量模式或用户关闭「后台 App 刷新」时不执行。
- 因此**不要**用后台任务承载车控指令的可靠性，指令终态仍由「推送 + 轮询」保证。
- 已在 `project.yml` 声明 `UIBackgroundModes: [fetch, remote-notification]` 与
  `BGTaskSchedulerPermittedIdentifiers`；模拟器上 `BGTaskScheduler.submit` 会抛错，已在代码里 catch。

---

## 6. 接入清单（改动点）

| 位置 | 需要替换 |
|---|---|
| `Sources/Core/Config/AppEnvironment.swift` | `apiBaseURL`、`streamBaseURL`、授权/令牌端点、`clientID`、`redirectURI`、`scopes` |
| `project.yml` + `Info.plist` | `PRODUCT_BUNDLE_IDENTIFIER`、`CFBundleURLSchemes`（与 redirectURI scheme 一致）、`DEVELOPMENT_TEAM` |
| `Sources/Services/VehicleAPI.swift` | 各 path、`Idempotency-Key` 头名（若规范不同） |
| `Sources/Models/VehicleSnapshot.swift` | 字段名与嵌套结构 |
| `Sources/Models/VehicleCommand.swift` | `action` 与 `parameters` 取值、能力枚举 |
| `Sources/Models/CommandTicket.swift` | 回执状态机取值 |
| `Sources/Services/CommandInbox.swift` | APNs payload 字段名（`cmd_result` / `ticket_id` / `status` / `failure_reason`） |
| `Sources/Services/VehicleAPI.swift` | 推送令牌上报路径 `/v1/push/subscriptions` |
| `Sources/Services/BackgroundRefresher.swift` | 后台任务标识符（需与 `project.yml` 的 `BGTaskSchedulerPermittedIdentifiers` 一致） |
| `Sources/Core/Config/AppEnvironment.swift` | `pushEnabled`：开启前必须先在 Xcode 勾选 Push Notifications 能力 |

若官方接口使用非 Bearer 的自研签名（如 `X-Sign` + 时间戳 + HMAC），只需在
`APIClient.build()` 里追加签名头；`canonical` 串建议单独抽成 `RequestSigner`，
避免污染业务层。

---

## 7. GitHub Actions 自动构建

工作流位于仓库根：`.github/workflows/ios-build.yml`。

**位置说明**：文件里的 `env.PROJECT_DIR: VehicleControliOS` 表示工程在仓库中的相对路径。
如果仓库根就是本目录（`VehicleControliOS/`），把 `.github/` 整个目录拷到仓库根，
并把 `PROJECT_DIR` 改成 `.`，同时把 `paths` 过滤器里的 `VehicleControliOS/**` 改成 `**`。

触发条件：

| 事件 | 条件 | 行为 |
|---|---|---|
| `push` | `main` / `develop`，改动 `VehicleControliOS/**` 或工作流本身 | 无签名编译 + 归档（有密钥则出 IPA） |
| `push` | 标签 `v*` | 同上，并把 IPA 挂到 GitHub Release |
| `pull_request` | 指向 `main` / `develop` | 仅无签名编译，作为合并门禁 |
| `workflow_dispatch` | 手动 | 可选 `export_method`（development / ad-hoc / app-store / enterprise） |

需要的 Repository secrets（缺任何一个都会自动降级为「无签名产物」）：

| Secret | 内容 |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | `.p12` 分发证书的 base64（`base64 -i cert.p12 \| pbcopy`） |
| `P12_PASSWORD` | 导出 p12 时设置的密码 |
| `KEYCHAIN_PASSWORD` | CI 临时钥匙串密码，任意随机串 |
| `PROVISIONING_PROFILE_BASE64` | `.mobileprovision` 的 base64 |
| `APPLE_TEAM_ID` | 10 位 Team ID |

产物：

| Artifact | 内容 | 保留 |
|---|---|---|
| `VehicleControl-ipa-<run_number>` | 签名后的 `.ipa` | 30 天 |
| `VehicleControl-unsigned-<run_number>` | 无签名 `VehicleControl.app` 压缩包 + 各阶段 `xcodebuild` 日志 | 14 天 |

每次提交自动打包：推到 `main`/`develop` 即触发（`paths` 过滤避免文档类改动白跑）；
PR 只跑编译门禁、不消耗签名凭证；打 `v1.2.0` 标签会额外生成 Release 并附 IPA。
`concurrency` 已关闭 `cancel-in-progress`（连续提交保留全部运行，避免出包被取消）。

注意：`macos-15` runner 按 **10 倍**分钟数计费，每次运行约 5–8 分钟（≈50–80 分钟额度），
私有仓库请留意配额；公开仓库免费。

---

## 8. 本地 Mock 联调（不依赖官方接口）

`Tools/mock-server/mock_server.py` 用 **Python 标准库**实现了 §1 的全部占位接口，
零第三方依赖，可直接在 macOS / Windows / Linux 上跑。

### 启动

```bash
cd Tools/mock-server
python mock_server.py            # 0.0.0.0:8000
python mock_server.py --auto-approve          # 跳过授权页，直接回调
python mock_server.py --disable-ws            # 关闭 WebSocket，强制走轮询
python mock_server.py --token-ttl 30          # 30 秒过期，用于验证刷新链路
python mock_server.py --fail-action none      # 关闭固定失败
python mock_server.py --latency 1.2           # 模拟弱网
```

### 让 App 指向它

Xcode → Scheme → Run → Arguments 添加启动参数：

| 场景 | 参数 |
|---|---|
| 模拟器 | `-useMockBackend` |
| 真机（同一局域网） | `-useMockBackend -mockBaseURL http://192.168.x.x:8000` |

`AppEnvironment.current` 在 DEBUG 下读到该参数即切换到 `localMock`，
并把 `http` 自动推导为 `ws` 用于推送。真机需在 Mac 上用局域网 IP 启动服务，
并允许 macOS 防火墙放行；`Info.plist` 已加 `NSAllowsLocalNetworking`（仅放行本地网络）。

### Mock 行为

| 项 | 说明 |
|---|---|
| 车辆 | `VH0001`（全能力）、`VH0002`（缺 trunk / horn / charging，用于验证能力过滤） |
| 授权 | 标准 PKCE(S256) 校验；授权页为本地生成的 HTML，点「授权并继续」后 302 到 `com.vehiclecontrol.app://oauth/callback?code=...` |
| 令牌 | `expires_in` 可配；refresh_token 轮换，旧 token 立即失效 |
| 指令 | `202` 受理 → 3 秒后转终态；支持 `Idempotency-Key` 去重（同 key 返回同一 ticket） |
| 状态联动 | `lock/unlock/trunk_toggle/climate_*/charge_*` 会改变快照，成功后 UI 立即反映 |
| 固定失败 | 默认 `charge_start` 返回 `failed`（"车辆未连接充电枪"），且**不改变**车辆状态，用于验证失败态 UI |
| 推送 | `wss://.../v1/vehicles/{id}/stream` 每 2 秒推一帧快照 |
| 错误信封 | 401/400 均返回 `{"code","message"}`，与 `APIErrorEnvelope` 对齐 |

### 契约回归测试（CI 用）

```bash
python Tools/ci/mock_smoke_test.py     # 自行拉起服务、跑完 30+ 断言、退出即清理
```

覆盖：授权页 → 302 回调 → PKCE 换令牌 → 无令牌 401 → 车辆列表 → 快照 →
指令 202 → 幂等重放 → 回执 3s 转 succeeded → 状态联动 → 固定失败路径 →
failed 后状态不变 → 推送令牌 204 → refresh 轮换 → WebSocket 101 + 帧解析。

---

## 9. 云端 Mac 编译（本机无法编译时的执行路径）

本机是 Windows，没有 `xcodebuild`，所有编译只能发生在云端 macOS。三条可用路径：

| 方案 | 免费额度 | 适用 | 配置文件 |
|---|---|---|---|
| GitHub Actions `macos-15` | 公开仓库免费；私有仓库 2000 分钟/月（macOS 按 10 倍算 = 约 200 分钟） | 代码已在 GitHub | `.github/workflows/ios-build.yml`（已就绪） |
| Codemagic | 500 分钟/月 | 需要更快反馈或额度不够 | `codemagic.yaml`（已就绪） |
| Xcode Cloud | 25 小时/月 | 有付费开发者账号，想顺路发 TestFlight | 需在 Xcode 内配置，非 YAML |
| MacStadium / 云厂商 macOS 实例 | 按小时计费 | 长期、要图形界面调试 | 无 |

### 一条命令跑完全程（`Tools/ci/autopilot.py`）

| 命令 | 行为 |
|---|---|
| `python Tools/ci/autopilot.py --check-only` | 只体检：环境 + 两道门禁，不写任何文件 |
| `python Tools/ci/autopilot.py --plan` | 体检 + 列出待上传文件（应恰好 43 个，全部在白名单内） |
| `python Tools/ci/autopilot.py` | 体检 + 门禁 + `git init`/commit（缺凭据时以 78 退出，不留半成品） |
| `GITHUB_REPO=owner/name GITHUB_TOKEN=xxx python Tools/ci/autopilot.py` | 继续推送 → 触发 → 轮询 → 失败自动抽 `error:` |

设计要点：

- **幂等**：每步先检测再动作，重复执行安全。
- **不落凭据**：token 只拼进一次性 push URL，不进 `.git/config`，remote 会被还原成无凭据地址。
- **无 git 也能跑**：本机若没有 git（或下载被网络策略阻断），自动改走 Git Data API
  （blob → tree → commit → ref），不依赖客户端。
- **失败可交付**：`error:` 行去重后写入仓库根 `compile-errors.txt`，可直接贴回来定位。
- **退出码**：`0` 全部完成 / `1` 门禁失败 / `2` 提交或发布失败 / `78` 缺凭据。

唯一无法自动化的一步是**凭据签发**：Fine-grained token，限定该仓库，
权限 `Contents: Read and write` + `Workflows: Read and write`（少了 Workflows 会被拒收
`.github/workflows/`）。Apple 侧同理：分发证书与描述文件必须由账号所有者申请，
`autopilot` 只负责把它们装进钥匙串并完成签名。

### 执行顺序（每次提交都一样）

```
lint（ubuntu，约 40 秒）            build（macos-15，约 6–8 分钟）
├─ swift_static_check.py            ├─ brew install xcodegen
│  括号 / 重复声明 / @unchecked 误用  ├─ xcodegen generate
│  协议未实现 / 未声明类型            ├─ 模拟器 Debug 编译（门禁）
│  scheme 与 target 名一致            ├─ 真机 Release 无签名归档 → .zip
└─ mock_smoke_test.py               └─ 有签名 secrets 时 → .ipa
   35 项接口契约断言
```

`build` 依赖 `lint`：便宜的机器先跑，错了不浪费 Mac 分钟。

### 版本管理（语义化版本 + 自动构建号）

- **命名规则**：`MAJOR.MINOR.PATCH`（语义化版本）。主版本 +1 = 破坏性变更；
  次版本 +1 = 新功能；修订号 +1 = 缺陷修复。发布历史版本对照用语义化做变更溯源于一目了然。
- **唯一真相源**：`VehicleControliOS/VERSION`。`Tools/ci/bump_version.py` 负责递增
  并同步 `project.yml` 的 `CFBundleShortVersionString` / `MARKETING_VERSION`；
  静态检查器强制三方一致，漂移会在 40 秒的 lint job 被拦下。
- **构建号**：`CURRENT_PROJECT_VERSION = CI run number`，每次构建严格递增，无需人工管理。
- **发布时递增**：`python Tools/ci/autopilot.py --bump patch`（或 `--minor` / `--major` /
  `--set=1.2.3`），递增发生在门禁之前，随本次提交一起发布。日常修复跑 `patch`。

### OTA 更新机制

**触发条件**（应用内 `UpdateChecker`）：

- 每次冷启动检查一次（`RootView.task`），结果缓存，进程内不重复请求；
- 清单不可达/解析失败静默跳过——离线可用优先，更新检查永不阻塞启动；
- `latest_version > 当前版本` → 提示更新（可忽略）；`当前版本 < min_version` → 强制更新弹窗。

**分发渠道**（当前为未签名包阶段的现实约束）：

| 渠道 | 适用 | 说明 |
|---|---|---|
| 仓库 manifest + 手动重签 | **当前** | CI 成功后 autopilot 自动把 `.github/ota/manifest.json` 写入仓库
（含 `latest_version` / `min_version` / `build` / `ipa_url`），应用启动比对；用户从 `ipa_url`
下载 IPA 后用 Sideloadly/AltStore 重签安装 |
| itms-services 空中安装 | 配置签名 secrets 后 | Ad Hoc/企业签名包挂 HTTPS `manifest.plist`，
手机点链接直接安装；把 plist 地址填进 manifest 的 `manifest_plist_url` 即可启用 |
| TestFlight | 有付费账号后 | 上传 App Store Connect，推送走苹果通道，本机制仍可作为灰度对照 |

注意：`[skip ci]` 已加在清单提交信息上，清单回写不会触发新一轮构建。

### 应用图标

- **素材**：`Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`，汽车图形（白色车身 +
  深蓝底），AI 生成后人工校验。
- **规格要求**（iOS 单尺寸图标，全部有静态检查兜底）：1024×1024 像素、PNG、8-bit、
  **无 alpha 通道**、方形无预裁圆角（系统自动裁切）、sRGB、无文字压边。
- **接线**：`project.yml` 的 `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`；actool 打包时
  自动生成 `CFBundleIcons` 注入产物，Info.plist 无需手写。

### 产物说明：你会拿到什么包

| 产物 | 内容 | 能否安装 |
|---|---|---|
| `VehicleControl-unsigned.zip` | Release `.app` 原样压缩，供快速校验二进制 | 否（结构非 IPA） |
| `VehicleControl-unsigned.ipa` | 标准 `Payload/<App>.app` 结构，**未签名** | 否，需重签：Sideloadly / AltStore 用个人 Apple ID（免费 7 天有效期，付费开发者 1 年），或交给企业签 / TestFlight 流程 |
| `VehicleControl-ipa-*.ipa` | **已签名**，可直接安装 / 分发 | 是（仅描述文件内登记的设备） |

签名 IPA 需在仓库 Secrets 配置 5 项，CI 会按导出方式自动匹配证书：

| Secret | 内容 | 从哪里取 |
|---|---|---|
| `BUILD_CERTIFICATE_BASE64` | 证书 .p12 的 base64 | Apple Developer → Certificates 下载 .cer，钥匙串导出 .p12 |
| `P12_PASSWORD` | 导出 .p12 时设的密码 | 自定 |
| `KEYCHAIN_PASSWORD` | CI 临时钥匙串密码 | 自定（任意强密码） |
| `PROVISIONING_PROFILE_BASE64` | 描述文件 base64 | Apple Developer → Profiles（Ad Hoc 需先登记设备 UDID） |
| `APPLE_TEAM_ID` | 10 位 Team ID | Apple Developer 账户详情页 |

`export_method=development` 会自动改用 `Apple Development` 证书，其余方式用
`Apple Distribution`；归档与导出两处一致。

### 静态检查的能力边界（已实测）

`Tools/ci/swift_static_check.py` 不是编译器替代品，只挡「必然编译失败」的低级错误。
我注入过一个含 5 类错误的探针文件验证它确实有效，7 条问题全部报出：

```
✗ '(' 与 ')' 数量不一致 (3 vs 2)
✗ 'BrokenProbe' 是 struct，@unchecked Sendable 只能用于 class/actor
✗ Vehicle 重复声明（与 Vehicle.swift 冲突）
✗ 'HalfService' 声明遵循 VehicleServicing，但未实现 fetchSnapshot / send / commandReceipt
✗ 未声明的类型引用：'Frobnicator'
```

当前状态：33 个 Swift 文件、71 个类型声明，检查通过。

### 首次云编译的预期

以下是我能预判、但只有真编译器能确认的三类风险（按可能性排序）：

1. **并发隔离警告**：`@StateObject private var container = AppContainer()`（`@MainActor` init 在
   非隔离属性初始化器中调用）会报 "call to main actor-isolated initializer in a sync nonisolated
   context"。**已预防性修复**：`VehicleControlApp` 已标注 `@MainActor`；即使仍有残余警告，
   `SWIFT_STRICT_CONCURRENCY: minimal` 下也不阻塞产物。
2. **个别 SwiftUI API 边界**：iOS 16 上 `.foregroundStyle(.tertiary)`、`confirmationDialog`
   变体等若报不可用，改回 `.foregroundColor` 或 `actionSheet` 即可，属局部改动。
3. **签名阶段**：`method` 与描述文件类型不匹配（ad-hoc vs development）、`plist` 里 profile
   名取错——只影响 `.ipa`，不影响无签名产物。

### 拿到日志后的反馈方式

失败时把 `Upload unsigned package & logs` 产物里的 `simulator-build.log`，或 Actions 页面
报错段落（`error:` 开头的行）贴回来即可，我按行定位修改。日志里 **warning 可以忽略**，
只需要 `error:` 行。

### 已验证项

该服务在本机用脚本跑过完整链路，35 项断言全部通过：
授权页渲染 → 302 回调 → PKCE 换令牌 → 错误 code 拒绝 → 无令牌 401 →
车辆列表 → 快照 → 指令 202 → 幂等重放同 ticket → 回执 dispatched → 3s 后 succeeded →
状态联动生效 → 固定失败路径 → failed 后状态不变 → 推送令牌 204 →
refresh 换新令牌可用 → WebSocket 101 握手 + `Sec-WebSocket-Accept` 校验 + 首帧快照解析。

> 注意：Mock 是**开发期替身**，不做速率限制、不做签名校验、数据全在内存（重启即重置）。
> 它验证的是「客户端调用逻辑与状态机」，不能替代官方接口的契约确认。

