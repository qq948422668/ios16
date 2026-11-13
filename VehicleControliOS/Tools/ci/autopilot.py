#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Autopilot：全自动配置 → 门禁 → 提交 → 推送 → 云端 Mac 编译 → 取日志。

一条命令跑完除「凭据签发」以外的所有环节：

    python Tools/ci/autopilot.py --check-only     # 只体检，不改任何东西
    python Tools/ci/autopilot.py                  # 装环境 + 门禁 + 提交（无凭据时停在这里）
    GITHUB_REPO=owner/name GITHUB_TOKEN=xxx python Tools/ci/autopilot.py
                                                  # 继续推送 + 触发云端编译 + 失败自动抽 error

设计原则
--------
* 幂等：每一步先检测再动作，重复执行安全。
* 失败快：门禁不过就不提交，不浪费 Mac 额度。
* 不落凭据：token 只用于一次性 push URL，不写进 .git/config。
* 不猜：缺凭据时以退出码 78（EX_CONFIG）明确停下，而不是半途失败。

退出码：0 全部完成 / 1 门禁失败 / 2 git 或发布失败 / 78 缺凭据
"""

from __future__ import annotations

import base64
import io
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]          # VehicleControliOS/
REPO_ROOT = ROOT.parent                             # 仓库根（含 .github/）
API = "https://api.github.com"

WORKFLOW_FILE = os.environ.get("GITHUB_WORKFLOW", "ios-build.yml")
TARGET_REF = os.environ.get("GITHUB_REF_NAME", "main")
REPO = os.environ.get("GITHUB_REPO", "").strip()
TOKEN = os.environ.get("GITHUB_TOKEN", "").strip()

ALLOWED_PREFIXES = (".github/", "VehicleControliOS/", ".gitignore", "codemagic.yaml")
POLL_INTERVAL = 15
POLL_TIMEOUT = 60 * 60

def _locate_git() -> str | None:
    """git 可能来自 PATH、Git for Windows 安装器，或免安装的 MinGit。"""
    explicit = os.environ.get("GIT_EXE", "").strip()
    if explicit and Path(explicit).exists():
        return explicit
    found = shutil.which("git")
    if found:
        return found
    for candidate in (
        Path(os.environ.get("LOCALAPPDATA", "")) / "GitMin/cmd/git.exe",
        Path(r"C:\Program Files\Git\cmd\git.exe"),
        Path(os.environ.get("LOCALAPPDATA", "")) / "Programs/Git/cmd/git.exe",
        Path("/opt/homebrew/bin/git"),
        Path("/usr/local/bin/git"),
        Path("/usr/bin/git"),
    ):
        if candidate.exists():
            return str(candidate)
    return None


def _install_mingit_windows() -> str | None:
    """免安装版 MinGit：解压即用，不需要 UAC 提权，CI/受限机器上更可靠。"""
    dest = Path(os.environ.get("LOCALAPPDATA", "")) / "GitMin"
    exe = dest / "cmd/git.exe"
    if exe.exists():
        return str(exe)

    emit("git", "WAIT", "下载 MinGit（约 50 MB）…")
    code, payload = api("/repos/git-for-windows/git/releases/latest")
    if code != 200:
        emit("git", "FAIL", "查询 MinGit 版本失败 HTTP %s" % code)
        return None

    try:
        assets = json.loads(payload).get("assets", [])
    except ValueError:
        return None

    url = None
    for item in assets:
        name = item.get("name", "")
        if (name.startswith("MinGit") and name.endswith(".zip")
                and "64-bit" in name and "busybox" not in name):
            url = item.get("browser_download_url")
            emit("git", "INFO", "使用 %s (%.1f MB)" % (name, item.get("size", 0) / 1048576))
            break
    if not url:
        emit("git", "FAIL", "未找到 MinGit 资产")
        return None

    try:
        with urllib.request.urlopen(url, timeout=600) as response:
            blob = response.read()
        dest.mkdir(parents=True, exist_ok=True)
        zipfile.ZipFile(io.BytesIO(blob)).extractall(dest)
    except Exception as error:                       # noqa: BLE001 - 网络/解压失败一律降级
        emit("git", "FAIL", "MinGit 安装失败：%s" % error)
        return None

    return str(exe) if exe.exists() else None


GIT = _locate_git()


# ----------------------------------------------------------------------------
# 输出
# ----------------------------------------------------------------------------

def emit(step: str, status: str, detail: str = "") -> None:
    mark = {"OK": "  OK  ", "SKIP": " SKIP ", "FAIL": " FAIL ", "WAIT": " WAIT ",
            "INFO": " INFO ", "BLOCK": " BLOCK"}[status]
    line = "[%s] %-12s" % (mark, step)
    if detail:
        line += " " + detail
    print(line, flush=True)


def section(title: str) -> None:
    print("\n" + "=" * 72)
    print(title)
    print("=" * 72, flush=True)


# ----------------------------------------------------------------------------
# 工具
# ----------------------------------------------------------------------------

def run(cmd: list[str], cwd: Path | None = None, timeout: int = 600) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            cmd, cwd=str(cwd or REPO_ROOT), capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=timeout,
        )
        return proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except FileNotFoundError:
        return 127, "command not found: %s" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "timeout after %ss: %s" % (timeout, " ".join(cmd))


def git(*args: str, timeout: int = 300) -> tuple[int, str]:
    if not GIT:
        return 127, "git not installed"
    return run([GIT, *args], timeout=timeout)


class _DropAuthOnRedirect(urllib.request.HTTPRedirectHandler):
    """GitHub 的日志下载会 302 到 blob 存储，带着 Authorization 跳转会被拒。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            for key in list(new.headers):
                if key.lower() == "authorization":
                    del new.headers[key]
        return new


_OPENER = urllib.request.build_opener(_DropAuthOnRedirect)


def api(path: str, method: str = "GET", payload: dict | None = None) -> tuple[int, bytes]:
    url = path if path.startswith("http") else API + path
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("X-GitHub-Api-Version", "2022-11-28")
    request.add_header("User-Agent", "vehiclecontrol-autopilot")
    if TOKEN:
        request.add_header("Authorization", "Bearer " + TOKEN)
    if data:
        request.add_header("Content-Type", "application/json")
    try:
        with _OPENER.open(request, timeout=60) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except urllib.error.URLError as error:
        return 0, str(error.reason).encode()


# ----------------------------------------------------------------------------
# 1. 环境
# ----------------------------------------------------------------------------

def step_environment(check_only: bool) -> bool:
    section("1/5 环境配置")

    emit("python", "OK", "%s" % sys.version.split()[0])
    emit("platform", "INFO", "%s" % sys.platform)

    if GIT:
        _, version = git("--version")
        emit("git", "OK", version.strip())
    elif check_only:
        emit("git", "FAIL", "未安装（--check-only 不做安装）")
        return False
    elif TOKEN and REPO:
        emit("git", "INFO", "未安装；已提供凭据，推送走 Git Data API，跳过安装")
    else:
        emit("git", "WAIT", "未安装，尝试自动安装…")
        if sys.platform.startswith("win"):
            code, out = run(["winget", "install", "--id", "Git.Git", "-e",
                             "--source", "winget", "--accept-source-agreements",
                             "--accept-package-agreements", "--disable-interactivity"],
                            cwd=Path.home(), timeout=900)
            globals()["GIT"] = _locate_git()
            if not GIT:
                reason = ("winget 未成功（通常因需要 UAC 提权）" if code != 0
                          else "安装完成但当前进程 PATH 未刷新")
                emit("git", "INFO", reason + "，改用免安装版 MinGit")
                globals()["GIT"] = _install_mingit_windows()
            if not GIT:
                emit("git", "FAIL", "自动安装失败。手动装：https://git-scm.com/download/win")
                print(out[-500:])
                return False
            _, version = git("--version")
            emit("git", "OK", "自动安装成功 %s" % version.strip())
        else:
            code, out = run(["brew", "install", "git"], cwd=Path.home(), timeout=900)
            if code != 0:
                emit("git", "FAIL", "brew 安装失败")
                return False
            globals()["GIT"] = shutil.which("git")
            emit("git", "OK", "自动安装成功")

    if sys.platform == "darwin":
        if shutil.which("xcodegen"):
            emit("xcodegen", "OK", "本机可用")
        else:
            emit("xcodegen", "INFO", "本机未装（云端 runner 会自动 brew install，本地不必装）")
    else:
        emit("xcodegen", "INFO", "非 macOS，跳过（云端 runner 会装）")

    if shutil.which("xcodebuild"):
        emit("xcodebuild", "OK", "本机可直接编译")
    else:
        emit("xcodebuild", "INFO", "本机无 Xcode，编译将走云端 macOS runner")

    return True


# ----------------------------------------------------------------------------
# 2. 门禁
# ----------------------------------------------------------------------------

def step_gates() -> bool:
    section("2/5 静态门禁（不花 Mac 额度）")

    checks = [
        ("swift_static_check", ROOT / "Tools/ci/swift_static_check.py"),
        ("mock_contract", ROOT / "Tools/ci/mock_smoke_test.py"),
    ]
    for name, script in checks:
        if not script.exists():
            emit(name, "FAIL", "脚本缺失：%s" % script)
            return False
        code, out = run([sys.executable, "-X", "utf8", str(script)], cwd=script.parent,
                        timeout=300)
        tail = out.strip().splitlines()[-1] if out.strip() else ""
        if code != 0:
            emit(name, "FAIL", tail)
            print(out[-2000:])
            return False
        emit(name, "OK", tail)
    return True


# ----------------------------------------------------------------------------
# 3. 仓库隔离 + 提交
# ----------------------------------------------------------------------------

def step_repo(check_only: bool) -> bool:
    section("3/5 仓库隔离与提交")

    if not GIT:
        if TOKEN and REPO:
            emit("repo", "INFO", "git 不可用：改用白名单收集器校验 + API 提交")
            _files, violations = _collect_files()
            if violations:
                emit("repo", "FAIL", "%d 个白名单内文件不可读：%s" % (len(violations), violations[:5]))
                return False
            emit("repo", "OK", "白名单校验通过，待 API 提交")
            return True
        emit("repo", "FAIL", "git 不可用，无法继续")
        return False

    if not (REPO_ROOT / ".git").exists():
        if check_only:
            emit("repo", "FAIL", "尚未 git init（--check-only 不改动）")
            return False
        code, out = git("init", "-b", TARGET_REF)
        if code != 0:
            emit("repo", "FAIL", "git init 失败：%s" % out.strip()[:200])
            return False
        emit("repo", "OK", "已初始化仓库，分支 %s" % TARGET_REF)
    else:
        emit("repo", "OK", "仓库已存在")

    git("config", "core.quotepath", "false")
    git("add", "-A")

    code, staged = git("diff", "--cached", "--name-only")
    if code != 0:
        emit("repo", "FAIL", "读取暂存区失败")
        return False

    files = [line.strip() for line in staged.splitlines() if line.strip()]
    illegal = [f for f in files if not _allowed(f)]
    if illegal:
        emit("repo", "FAIL", "白名单外文件被暂存，已中止（共 %d 个）：" % len(illegal))
        for item in illegal[:15]:
            print("      - " + item)
        print("  修正根级 .gitignore 白名单后重跑，切勿直接 push。")
        return False

    emit("repo", "OK", "暂存 %d 个文件，全部在白名单内" % len(files))
    groups: dict[str, int] = {}
    for item in files:
        key = item.split("/")[0] if "/" in item else "(root)"
        groups[key] = groups.get(key, 0) + 1
    emit("scope", "INFO", ", ".join("%s=%d" % kv for kv in sorted(groups.items())))

    if not files:
        emit("commit", "SKIP", "无改动")
        return True

    if check_only:
        emit("commit", "SKIP", "--check-only 不提交")
        return True

    message = "chore: 同步 iOS 工程与 CI 配置 (%s)" % time.strftime("%Y-%m-%d %H:%M")
    code, out = git("-c", "user.name=autopilot", "-c", "user.email=autopilot@local",
                    "commit", "-m", message)
    if code != 0:
        if "nothing to commit" in out:
            emit("commit", "SKIP", "无改动")
            return True
        emit("commit", "FAIL", out.strip()[:300])
        return False
    _, head = git("rev-parse", "--short", "HEAD")
    emit("commit", "OK", "%s  %s" % (head.strip(), message))
    return True


# ----------------------------------------------------------------------------
# 4. 推送 + 触发云端编译
# ----------------------------------------------------------------------------

def step_publish() -> int:
    section("4/5 推送与云端编译")

    if not REPO or not TOKEN:
        emit("credentials", "BLOCK", "缺少 GITHUB_REPO / GITHUB_TOKEN")
        print("""
  凭据需要你签发（这是唯一无法自动化的环节，原因见回复说明）：
    1. 新建空仓库，得到 owner/name
    2. Fine-grained token → 限该仓库 → Contents: Read and write + Workflows: Read and write
    3. 有效期建议 1 天，用完 revoke
  然后重跑：
    set GITHUB_REPO=owner/name
    set GITHUB_TOKEN=github_pat_xxx
    python Tools/ci/autopilot.py
""")
        return 78

    slug = REPO if "/" in REPO else None
    if not slug:
        emit("credentials", "FAIL", "GITHUB_REPO 需形如 owner/name")
        return 2

    if not GIT:
        emit("push", "INFO", "本机无 git（且下载被封），改走 Git Data API，不依赖客户端")
        return _publish_via_api(slug, TARGET_REF)

    code, branch = git("rev-parse", "--abbrev-ref", "HEAD")
    branch = branch.strip() or TARGET_REF

    push_url = "https://x-access-token:%s@github.com/%s.git" % (
        urllib.parse.quote(TOKEN, safe=""), slug)
    emit("push", "WAIT", "推送到 %s (%s)" % (slug, branch))
    code, out = git("push", push_url, "HEAD:refs/heads/%s" % branch, timeout=600)
    if code != 0:
        lowered = out.lower()
        network_broken = any(marker in lowered for marker in (
            "connection was reset", "could not resolve host",
            "failed to connect", "connection timed out"))
        if network_broken:
            emit("push", "INFO", "git 通道被网络策略阻断，自动降级到 Git Data API 路径")
            return _publish_via_api(slug, branch)
        if "already exists" in out or "non-fast-forward" in out or "fetch first" in lowered:
            # 远端有本地没有的提交（例如此前经 API 路径写入的 OTA 清单），
            # 不强推：改走 Git Data API，以远端最新提交为父提交做增量。
            emit("push", "INFO", "远端领先于本地 git 历史，改走 API 增量提交（不强推）")
            return _publish_via_api(slug, branch)
        else:
            emit("push", "FAIL", out.strip()[:400])
        return 2
    emit("push", "OK", "已推送")

    # 保持 origin 干净（不含 token）
    git("remote", "remove", "origin")
    git("remote", "add", "origin", "https://github.com/%s.git" % slug)

    return _dispatch_and_watch(slug, branch)


def _wait_for_run(slug: str, branch: str, since: float) -> tuple[int, str, str]:
    deadline = time.time() + POLL_TIMEOUT
    run_id: int | None = None
    last_state = ""

    while time.time() < deadline:
        if run_id is None:
            code, body = api("/repos/%s/actions/runs?branch=%s&per_page=10"
                             % (slug, urllib.parse.quote(branch)))
            if code == 200:
                for item in json.loads(body).get("workflow_runs", []):
                    # 只认 dispatch 之后创建的运行，避免抓到上一轮的旧实例。
                    created = item.get("created_at", "")
                    try:
                        created_epoch = datetime.fromisoformat(
                            created.replace("Z", "+00:00")).timestamp()
                    except ValueError:
                        continue
                    if created_epoch + 5 < since:
                        continue
                    run_id = item["id"]
                    url = item.get("html_url", "")
                    emit("run", "OK", "#%s 已排队（%s）" % (run_id, item.get("run_number", "?")))
                    break
            if run_id is None:
                elapsed = int(time.time() - since)
                emit("run", "WAIT", "等待运行实例… %ss" % elapsed)
                time.sleep(POLL_INTERVAL)
                continue

        code, body = api("/repos/%s/actions/runs/%s" % (slug, run_id))
        if code != 200:
            emit("run", "WAIT", "查询失败 HTTP %s" % code)
            time.sleep(POLL_INTERVAL)
            continue

        info = json.loads(body)
        state = info.get("status", "unknown")
        conclusion = info.get("conclusion")
        if state != last_state:
            emit("run", "INFO", "状态 %s" % state)
            last_state = state
        if state == "completed":
            return run_id, conclusion or "unknown", info.get("html_url", "")
        time.sleep(POLL_INTERVAL)

    return run_id or 0, "timeout", ""


def _dump_errors(slug: str, run_id: int) -> None:
    emit("logs", "WAIT", "下载运行日志…")
    code, payload = api("/repos/%s/actions/runs/%s/logs" % (slug, run_id))
    if code != 200:
        emit("logs", "INFO", "日志包不可用 HTTP %s，改读 annotations" % code)
        _dump_annotations(slug, run_id)
        return

    errors: list[str] = []
    notes: list[str] = []
    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            for name in archive.namelist():
                if not name.endswith((".log", ".txt")):
                    continue
                text = archive.read(name).decode("utf-8", "replace")
                for line in text.splitlines():
                    stripped = line.strip()
                    if re.search(r"\berror:", stripped) and not stripped.startswith("##["):
                        errors.append("%s | %s" % (Path(name).name, stripped))
                    elif "error: " in stripped and ".swift" in stripped:
                        errors.append("%s | %s" % (Path(name).name, stripped))
    except zipfile.BadZipFile:
        emit("logs", "FAIL", "日志不是合法 zip")
        return

    unique: list[str] = []
    seen = set()
    for item in errors:
        key = item.split("|", 1)[-1].strip()
        if key not in seen:
            seen.add(key)
            unique.append(item)

    report = ROOT.parent / "compile-errors.txt"
    report.write_text("\n".join(unique) if unique else "(日志中未匹配到 error: 行)",
                      encoding="utf-8")
    emit("logs", "OK", "抽取 %d 条 error → %s" % (len(unique), report.name))
    for item in unique[:40]:
        print("    " + item)
    if len(unique) > 40:
        print("    … 其余 %d 条见 %s" % (len(unique) - 40, report.name))


def _dump_annotations(slug: str, run_id: int) -> None:
    """读取 workflow 里 `::error` 生成的 annotation（走 api.github.com，不经 CDN）。"""
    code, body = api("/repos/%s/actions/runs/%s/jobs" % (slug, run_id))
    if code != 200:
        emit("annotations", "FAIL", "读取 job 失败 HTTP %s" % code)
        return

    messages: list[str] = []
    for job in json.loads(body).get("jobs", []):
        url = job.get("check_run_url")
        if not url:
            continue
        detail, payload = api(url + "/annotations")
        if detail != 200:
            continue
        for item in json.loads(payload):
            if item.get("annotation_level") == "failure":
                messages.append("%s | %s" % (
                    item.get("title") or job.get("name", "job"),
                    (item.get("message") or "").strip()))

    unique: list[str] = []
    seen: set[str] = set()
    for message in messages:
        key = message.split("|", 1)[-1]
        if key not in seen:
            seen.add(key)
            unique.append(message)

    report = REPO_ROOT / "compile-errors.txt"
    report.write_text("\n".join(unique) if unique else "(annotation 中没有 error 行)",
                      encoding="utf-8")
    emit("annotations", "OK", "%d 条 → %s" % (len(unique), report.name))
    for message in unique[:40]:
        print("    " + message)


def _report_artifacts(slug: str, run_id: int) -> None:
    code, body = api("/repos/%s/actions/runs/%s/artifacts" % (slug, run_id))
    if code != 200:
        return
    items = json.loads(body).get("artifacts", [])
    if not items:
        emit("artifacts", "INFO", "本次运行无产物")
        return
    for item in items:
        emit("artifacts", "OK", "%s  %.1f MB" % (item["name"],
                                                 item["size_in_bytes"] / 1024 / 1024))


def _publish_ota_manifest(slug: str, run_id: int, run_url: str) -> None:
    """构建成功后把 OTA 清单写入仓库 `.github/ota/manifest.json`。

    应用内 UpdateChecker 启动时拉取该清单做版本比较；
    提交信息带 [skip ci]，避免清单提交本身再触发一轮构建。
    """
    version_file = ROOT / "VERSION"
    if not version_file.exists():
        emit("ota", "INFO", "无 VERSION 文件，跳过 OTA 清单发布")
        return
    version = version_file.read_text(encoding="utf-8").strip()

    code, body = api("/repos/%s/actions/runs/%s" % (slug, run_id))
    run_number = json.loads(body).get("run_number") if code == 200 else None

    manifest = {
        "latest_version": version,
        "min_version": version,
        "build": run_number,
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "notes": "",
        "ipa_url": run_url,
        # 未签名包无法 itms-services 空中安装；签名后把 plist 地址填到这里。
        "manifest_plist_url": None,
    }
    content = base64.b64encode(
        json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8")).decode()

    path = ".github/ota/manifest.json"
    detail, payload = api("/repos/%s/contents/%s" % (slug, path))
    put: dict = {"message": "chore(ota): publish v%s (build %s) [skip ci]" % (version, run_number),
                 "content": content}
    if detail == 200:
        put["sha"] = json.loads(payload).get("sha")
    code, body = api("/repos/%s/contents/%s" % (slug, path), "PUT", put)
    if code in (200, 201):
        emit("ota", "OK", "清单已发布 v%s (build %s) → %s" % (version, run_number, path))
    else:
        emit("ota", "FAIL", "清单发布失败 HTTP %s：%s" % (
            code, body.decode("utf-8", "replace")[:200]))


# ----------------------------------------------------------------------------
# 4b. 无 git 时的提交路径（Git Data API：blob → tree → commit → ref）
# ----------------------------------------------------------------------------

SKIP_DIRS = {".git", "build", "DerivedData", "__pycache__", ".vscode", ".idea", "xcuserdata"}
SKIP_SUFFIXES = (".ipa", ".p12", ".mobileprovision", ".xcarchive", ".xcuserstate", ".dSYM")
SKIP_EXACT = {"VehicleControliOS/VehicleControl/Info.plist", ".DS_Store", "compile-errors.txt"}


def _allowed(rel: str) -> bool:
    return rel in (".gitignore", "codemagic.yaml") or rel.startswith((".github/", "VehicleControliOS/"))


def _collect_files() -> tuple[list[tuple[str, bytes]], list[str]]:
    """只遍历白名单根目录（不扫 node_modules 之类），返回 (files, violations)。

    violations 只记录「该传但读不了」的文件——非白名单路径直接跳过，
    那是白名单的意义所在，不算错误。
    """
    files: list[tuple[str, bytes]] = []
    violations: list[str] = []

    for rel in (".gitignore", "codemagic.yaml"):
        path = REPO_ROOT / rel
        if path.is_file():
            files.append((rel, path.read_bytes()))

    for root in (REPO_ROOT / ".github", REPO_ROOT / "VehicleControliOS"):
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(REPO_ROOT).as_posix()
            if rel in SKIP_EXACT or rel.endswith(SKIP_SUFFIXES):
                continue
            parts = rel.split("/")
            if any(part in SKIP_DIRS or part.endswith((".xcodeproj", ".xcworkspace"))
                   for part in parts):
                continue
            if not _allowed(rel):        # 兜底，正常不会命中
                continue
            try:
                files.append((rel, path.read_bytes()))
            except OSError as error:
                violations.append("%s (%s)" % (rel, error))
    return files, violations


def _print_plan() -> bool:
    files, violations = _collect_files()
    total_kb = sum(len(content) for _, content in files) / 1024
    emit("plan", "INFO", "%d 个文件，%.1f KB" % (len(files), total_kb))

    groups: dict[str, int] = {}
    for rel, _ in files:
        key = rel.split("/")[0] if "/" in rel else "(root)"
        groups[key] = groups.get(key, 0) + 1
    emit("scope", "INFO", ", ".join("%s=%d" % item for item in sorted(groups.items())))

    for rel, content in files:
        print("      %-58s %6.1f KB" % (rel, len(content) / 1024))

    if violations:
        emit("plan", "FAIL", "%d 个路径在白名单外或不可读" % len(violations))
        for item in violations[:15]:
            print("      ! " + item)
        return False
    emit("plan", "OK", "全部落在白名单内，可直接上传")
    return True


def _publish_via_api(slug: str, branch: str) -> int:
    code, body = api("/repos/%s" % slug)
    if code != 200:
        emit("api", "FAIL", "读取仓库失败 HTTP %s：%s"
             % (code, body.decode("utf-8", "replace")[:200]))
        return 2
    default_branch = json.loads(body).get("default_branch") or branch

    parent_sha = tree_base = None
    code, body = api("/repos/%s/git/ref/heads/%s" % (slug, urllib.parse.quote(default_branch)))
    if code == 200:
        parent_sha = json.loads(body)["object"]["sha"]
        detail, payload = api("/repos/%s/git/commits/%s" % (slug, parent_sha))
        if detail == 200:
            tree_base = json.loads(payload)["tree"]["sha"]
        emit("api", "OK", "分支 %s 已有提交 %.8s" % (default_branch, parent_sha))
    elif code in (404, 409):
        emit("api", "INFO", "仓库为空，将创建首个提交")
    else:
        emit("api", "FAIL", "读取分支失败 HTTP %s" % code)
        return 2

    files, violations = _collect_files()
    if violations:
        emit("api", "FAIL", "白名单外文件，已中止：%s" % violations[:5])
        return 2
    emit("api", "INFO", "上传 %d 个文件（%.1f KB）" % (len(files),
                                                     sum(len(c) for _, c in files) / 1024))

    entries = []
    for rel, content in files:
        try:
            payload = {"content": content.decode("utf-8"), "encoding": "utf-8"}
        except UnicodeDecodeError:
            payload = {"content": base64.b64encode(content).decode(), "encoding": "base64"}
        # GitHub blob API 偶发返回 400「malformed request」（实测同一请求
        # 重放 1~3 次后必 201），属于突发请求触发的瞬时抖动：
        # 5 次指数退避重试 + 上传间隔节流，blob 重复创建是幂等的。
        detail = response = None
        for attempt in range(5):
            detail, response = api("/repos/%s/git/blobs" % slug, "POST", payload)
            if detail == 201:
                break
            time.sleep(min(3 * (2 ** attempt), 30))
        if detail != 201:
            emit("api", "FAIL", "blob 失败 %s HTTP %s（已重试 5 次）" % (rel, detail))
            return 2
        time.sleep(0.4)
        entries.append({"path": rel, "mode": "100644", "type": "blob",
                        "sha": json.loads(response)["sha"]})
    emit("api", "OK", "blob 全部创建完成")

    tree_payload: dict = {"tree": entries}
    if tree_base:
        tree_payload["base_tree"] = tree_base
    detail, response = api("/repos/%s/git/trees" % slug, "POST", tree_payload)
    if detail != 201:
        emit("api", "FAIL", "tree 创建失败 HTTP %s" % detail)
        return 2
    tree_sha = json.loads(response)["sha"]

    message = "chore: 同步 iOS 工程与 CI 配置 (%s)" % time.strftime("%Y-%m-%d %H:%M")
    detail, response = api("/repos/%s/git/commits" % slug, "POST", {
        "message": message, "tree": tree_sha,
        "parents": [parent_sha] if parent_sha else [],
    })
    if detail != 201:
        emit("api", "FAIL", "commit 失败 HTTP %s：%s"
             % (detail, response.decode("utf-8", "replace")[:200]))
        return 2
    commit_sha = json.loads(response)["sha"]
    emit("commit", "OK", "%.8s %s" % (commit_sha, message))

    if parent_sha:
        detail, response = api(
            "/repos/%s/git/refs/heads/%s" % (slug, urllib.parse.quote(default_branch)),
            "PATCH", {"sha": commit_sha, "force": False})
        ok = detail == 200
    else:
        detail, response = api("/repos/%s/git/refs" % slug, "POST",
                               {"ref": "refs/heads/%s" % default_branch, "sha": commit_sha})
        ok = detail == 201
    if not ok:
        emit("push", "FAIL", "更新分支失败 HTTP %s：%s"
             % (detail, response.decode("utf-8", "replace")[:200]))
        return 2
    emit("push", "OK", "已提交到 %s @ %.8s" % (default_branch, commit_sha))

    return _dispatch_and_watch(slug, default_branch)


def _dispatch_and_watch(slug: str, branch: str) -> int:
    dispatched_at = time.time()
    detail, body = api("/repos/%s/actions/workflows/%s/dispatches" % (slug, WORKFLOW_FILE),
                       method="POST", payload={"ref": branch})
    if detail not in (201, 204):
        emit("dispatch", "FAIL", "HTTP %s %s" % (detail, body.decode("utf-8", "replace")[:300]))
        if detail in (403, 404):
            print("  403/404 常见原因：token 缺 Workflows: write 权限，"
                  "或工作流文件尚未出现在该分支上。")
        return 2
    emit("dispatch", "OK", "已触发 %s @ %s" % (WORKFLOW_FILE, branch))

    run_id, conclusion, url = _wait_for_run(slug, branch, dispatched_at)
    if not run_id:
        emit("run", "FAIL", "未观测到运行实例（可能被 concurrency 取消，或触发失败）")
        return 2

    # push 与 dispatch 会各触发一次运行，concurrency 策略下较晚的会取消较早的。
    # 被取消的实例不是失败——改盯同分支最新的活跃/最终实例继续观察。
    hops = 0
    while conclusion == "cancelled" and hops < 4:
        hops += 1
        emit("run", "INFO", "实例被并发取消，改盯同分支最新实例（第 %d 次）" % hops)
        time.sleep(POLL_INTERVAL)
        candidate = _latest_active_run(slug, branch, dispatched_at)
        if not candidate:
            break
        run_id, url = candidate
        emit("run", "INFO", "#%s 接着观察" % run_id)
        run_id, conclusion, url = _watch_run(slug, run_id)

    emit("run", "INFO", "运行页 %s" % url)
    if conclusion == "success":
        emit("result", "OK", "lint + build 全部通过")
        _report_artifacts(slug, run_id)
        _publish_ota_manifest(slug, run_id, url)
        return 0

    emit("result", "FAIL", "结论：%s" % conclusion)
    _dump_errors(slug, run_id)
    return 2


def _latest_active_run(slug: str, branch: str, since: float) -> tuple[int, str] | None:
    """返回 dispatch 之后创建的最新、未被取消的运行实例。"""
    code, body = api("/repos/%s/actions/runs?branch=%s&per_page=10"
                     % (slug, urllib.parse.quote(branch)))
    if code != 200:
        return None
    for item in json.loads(body).get("workflow_runs", []):
        created = item.get("created_at", "")
        try:
            created_epoch = datetime.fromisoformat(
                created.replace("Z", "+00:00")).timestamp()
        except ValueError:
            continue
        if created_epoch + 5 < since:
            continue
        if item.get("conclusion") == "cancelled":
            continue
        return item["id"], item.get("html_url", "")
    return None


def _watch_run(slug: str, run_id: int) -> tuple[int, str, str]:
    """盯着单个运行实例直到结束。"""
    deadline = time.time() + POLL_TIMEOUT
    last_state = ""
    while time.time() < deadline:
        code, body = api("/repos/%s/actions/runs/%s" % (slug, run_id))
        if code != 200:
            time.sleep(POLL_INTERVAL)
            continue
        info = json.loads(body)
        state = info.get("status", "unknown")
        if state != last_state:
            emit("run", "INFO", "状态 %s" % state)
            last_state = state
        if state == "completed":
            return run_id, info.get("conclusion") or "unknown", info.get("html_url", "")
        time.sleep(POLL_INTERVAL)
    return run_id, "timeout", ""


# ----------------------------------------------------------------------------
# 5. 汇总
# ----------------------------------------------------------------------------

def _apply_cli_overrides(argv: list[str]) -> None:
    """允许 --repo / --token 直接传参，省去配置环境变量。

    注意：令牌出现在命令行会留在 shell 历史，推荐仍用 GITHUB_TOKEN 环境变量。
    """
    global REPO, TOKEN
    if "--repo" in argv:
        index = argv.index("--repo")
        if index + 1 < len(argv):
            REPO = argv[index + 1].strip()
    if "--token" in argv:
        index = argv.index("--token")
        if index + 1 < len(argv):
            TOKEN = argv[index + 1].strip()
            print("提醒：令牌经命令行传入会留在 shell 历史，用完请清理历史并 revoke。")


def _apply_version_bump(argv: list[str]) -> None:
    """--bump patch|minor|major|set=X.Y.Z：发布前递增版本（默认不递增）。

    只在执行模式生效；递增发生在门禁之前，保证随本次提交一起上传。
    """
    if "--bump" not in argv:
        return
    index = argv.index("--bump")
    if index + 1 >= len(argv):
        emit("bump", "FAIL", "--bump 需要参数：patch|minor|major|set=X.Y.Z")
        raise SystemExit(2)
    mode = argv[index + 1].strip()
    script = ROOT / "Tools/ci/bump_version.py"
    args = [sys.executable, "-X", "utf8", str(script)]
    if mode == "patch":
        args.append("--patch")
    elif mode == "minor":
        args.append("--minor")
    elif mode == "major":
        args.append("--major")
    elif mode.startswith("set="):
        args += ["--set", mode[4:]]
    else:
        emit("bump", "FAIL", "未知模式 %r（可选 patch|minor|major|set=X.Y.Z）" % mode)
        raise SystemExit(2)
    code, out = run(args, cwd=ROOT, timeout=30)
    print(out.strip())
    if code != 0:
        emit("bump", "FAIL", "版本递增失败")
        raise SystemExit(2)
    emit("bump", "OK", "版本已更新，将随本次构建发布")


def main() -> int:
    _apply_cli_overrides(sys.argv)
    check_only = "--check-only" in sys.argv
    plan_only = "--plan" in sys.argv
    mode = "计划（只读，列出待上传文件）" if plan_only else ("体检（只读）" if check_only else "执行")
    print("Autopilot  |  仓库根 %s" % REPO_ROOT)
    print("模式：%s" % mode)

    if not (check_only or plan_only):
        _apply_version_bump(sys.argv)

    env_ok = step_environment(check_only or plan_only)
    if not env_ok and not plan_only:
        return 1
    if not step_gates():
        return 1
    if plan_only:
        section("3/5 待上传文件计划")
        return 0 if _print_plan() else 2
    if not step_repo(check_only):
        return 2

    if check_only:
        section("5/5 汇总")
        emit("summary", "OK", "本地环节全部就绪；加凭据即可发布")
        return 0

    result = step_publish()
    section("5/5 汇总")
    if result == 0:
        emit("summary", "OK", "编译通过，产物见上方 artifacts")
    elif result == 78:
        emit("summary", "BLOCK", "本地就绪，等待 GitHub 凭据")
    else:
        emit("summary", "FAIL", "失败详情见上方输出与 compile-errors.txt")
    return result


if __name__ == "__main__":
    sys.exit(main())
