#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GitHub 仓库分析工具：输入 owner/repo 与 PAT，产出结构化仓库报告。

用法
----
    python Tools/ci/repo_report.py owner/repo                     # 匿名（仅公开仓库）
    python Tools/ci/repo_report.py owner/repo --token-env GH_PAT  # 从环境变量读令牌
    python Tools/ci/repo_report.py owner/repo --token ghp_xxx     # 直接传令牌
    python Tools/ci/repo_report.py owner/repo --json              # 机器可读输出

分析内容
--------
仓库概况 / 语言分布 / 最近提交 / 贡献者 / 开放 Issues 与 PRs / 最近 CI 运行。
任何一章失败只降级该章，不阻塞其余章节；全部失败或鉴权失败才整页退出。

退出码：0 全部章节成功 / 2 输入非法 / 3 鉴权失败 / 4 部分章节失败 / 5 仓库不可达
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

API = "https://api.github.com"
REPO_RE = re.compile(r"^[\w.\-]+/[\w.\-]+$")
TOKEN_PREFIXES = ("ghp_", "gho_", "ghu_", "ghs_", "github_pat_")

EXIT_OK, EXIT_INPUT, EXIT_AUTH, EXIT_PARTIAL, EXIT_UNREACHABLE = 0, 2, 3, 4, 5

# 章节定义：key -> (路径, 参数, 说明)
SECTIONS = [
    ("commits", "/repos/{repo}/commits", {"per_page": "10"}, "最近提交"),
    ("contributors", "/repos/{repo}/contributors", {"per_page": "10"}, "贡献者"),
    ("issues", "/repos/{repo}/issues", {"state": "open", "per_page": "10"}, "开放 Issues"),
    ("pulls", "/repos/{repo}/pulls", {"state": "open", "per_page": "10"}, "开放 Pull Requests"),
    ("languages", "/repos/{repo}/languages", {}, "语言分布"),
    ("contents", "/repos/{repo}/contents", {}, "根目录结构"),
    ("runs", "/repos/{repo}/actions/runs", {"per_page": "3"}, "最近 CI 运行"),
]


# ----------------------------------------------------------------------------
# HTTP
# ----------------------------------------------------------------------------

def gh_request(path: str, token: str | None, params: dict | None = None,
               method: str = "GET") -> tuple[int, object, dict]:
    """返回 (状态码, 解析后的 JSON, 响应头)。状态码 0 表示网络层失败。"""
    url = API + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(url, method=method)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("X-GitHub-Api-Version", "2022-11-28")
    request.add_header("User-Agent", "repo-report-tool")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode("utf-8", "replace")
            data = json.loads(body) if body.strip() else None
            return response.status, data, dict(response.headers)
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8", "replace")
        try:
            data = json.loads(raw) if raw.strip() else None
        except ValueError:
            data = {"message": raw[:200]}
        return error.code, data, dict(error.headers)
    except urllib.error.URLError as error:
        return 0, {"message": str(getattr(error, "reason", error))}, {}


def explain(status: int, data: object, headers: dict) -> str:
    """把 GitHub 的错误翻译成可执行的建议。"""
    message = ""
    if isinstance(data, dict):
        message = str(data.get("message", ""))

    if status == 0:
        return "网络不可达：%s（本工具只访问 api.github.com，请检查网络策略）" % message

    if status == 401:
        return ("令牌无效或已被撤销。请确认：复制完整、未过期、账号未改密导致失效；"
                "fine-grained 令牌还需确认未选错资源所有者。")

    if status == 403:
        if headers.get("X-RateLimit-Remaining") == "0":
            reset = headers.get("X-RateLimit-Reset", "")
            hint = ""
            if reset.isdigit():
                when = datetime.fromtimestamp(int(reset), tz=timezone.utc)
                hint = "，重置于 %s UTC" % when.strftime("%H:%M")
            return "API 速率用尽%s。匿名 60 次/小时，带令牌 5000 次/小时。" % hint
        return ("权限不足。fine-grained 令牌需要该仓库的 Metadata: Read（公开仓库足够）；"
                "私有仓库还需 Contents: Read。classic 令牌需要 repo 或 public_repo scope。")

    if status == 404:
        return ("仓库不存在，或令牌无权访问它——对私有仓库这两种情况返回相同的 404。"
                "请核对 owner/repo 拼写与大小写，并确认令牌授权了正确的仓库。")

    if status == 301:
        return "仓库已改名/转移，请使用新地址（见响应中的 url 字段）。"

    return "HTTP %s：%s" % (status, message or "未知错误")


def rate_note(headers: dict) -> str:
    remaining = headers.get("X-RateLimit-Remaining", "?")
    limit = headers.get("X-RateLimit-Limit", "?")
    return "API 余量 %s/%s" % (remaining, limit)


# ----------------------------------------------------------------------------
# 输入校验（先校验，后发请求）
# ----------------------------------------------------------------------------

def validate_inputs(repo: str, token: str) -> list[str]:
    problems: list[str] = []
    if not repo.strip():
        problems.append("仓库标识为空，应为 owner/repo 形式，例如 octocat/Hello-World")
    elif not REPO_RE.match(repo.strip()):
        problems.append(
            "仓库标识 '%s' 不符合 owner/repo 格式："
            "两侧只能是字母、数字、点、连字符、下划线，且不含空格" % repo.strip()
        )
    if token:
        if len(token) < 20 or " " in token:
            problems.append("令牌长度异常或包含空格，确认复制完整且未夹带换行")
        elif not token.startswith(TOKEN_PREFIXES):
            problems.append(
                "令牌前缀不符合 GitHub 约定（应为 ghp_/gho_/ghu_/ghs_/github_pat_ 之一），"
                "请确认这是 GitHub PAT 而不是其他服务的密钥"
            )
    return problems


# ----------------------------------------------------------------------------
# 各章节渲染
# ----------------------------------------------------------------------------

def _short_date(iso: str) -> str:
    return (iso or "")[:10]


def render_section(key: str, data: object) -> list[str]:
    lines: list[str] = []

    if key == "commits":
        commits = data if isinstance(data, list) else []
        if not commits:
            return ["  （无提交）"]
        for item in commits:
            sha = str(item.get("sha", ""))[:7]
            commit = item.get("commit", {})
            author = (commit.get("author") or {}).get("name") or item.get("author", {}).get("login", "?")
            message = (commit.get("message") or "").splitlines()[0][:70]
            date = _short_date(commit.get("author", {}).get("date", ""))
            lines.append("  %s  %s  %-16s %s" % (sha, date, str(author)[:16], message))

    elif key == "contributors":
        people = data if isinstance(data, list) else []
        if not people:
            return ["  （无贡献者数据）"]
        for item in people[:10]:
            lines.append("  %-20s %s 次提交" % (item.get("login", "?"), item.get("contributions", 0)))

    elif key in ("issues", "pulls"):
        items = data if isinstance(data, list) else []
        if key == "issues":
            # issues 接口会混入 PR，按 pull_request 键过滤
            items = [x for x in items if "pull_request" not in x]
        if not items:
            return ["  （无）"]
        # 注意：/pulls 返回的对象不含 pull_request 键，类型由章节名决定
        kind = "PR" if key == "pulls" else "issue"
        for item in items:
            lines.append("  #%s [%s] %s  （%s）" % (
                item.get("number", "?"), kind,
                str(item.get("title", ""))[:60], item.get("user", {}).get("login", "?")))

    elif key == "languages":
        langs = data if isinstance(data, dict) else {}
        if not langs:
            return ["  （无语言统计）"]
        total = sum(langs.values()) or 1
        pieces = ", ".join("%s %.1f%%" % (name, size * 100.0 / total)
                           for name, size in sorted(langs.items(), key=lambda kv: -kv[1]))
        lines.append("  %d 种：%s" % (len(langs), pieces))

    elif key == "contents":
        entries = data if isinstance(data, list) else []
        dirs = sorted(x["name"] for x in entries if x.get("type") == "dir")
        files = sorted(x["name"] for x in entries if x.get("type") == "file")
        if dirs:
            lines.append("  目录：%s" % ", ".join(dirs))
        if files:
            lines.append("  文件：%s" % ", ".join(files))
        if not entries:
            return ["  （空仓库）"]

    elif key == "runs":
        runs = (data or {}).get("workflow_runs", []) if isinstance(data, dict) else []
        if not runs:
            return ["  （无 Actions 运行记录，或未启用 Actions）"]
        for item in runs:
            conclusion = item.get("conclusion") or item.get("status", "?")
            lines.append("  #%-6s %-10s %-12s %s  %s" % (
                item.get("run_number", "?"), str(conclusion)[:10],
                item.get("name", "?"), _short_date(item.get("created_at", "")),
                item.get("html_url", "")))

    return lines or ["  （无数据）"]


def render_repo_overview(info: dict) -> list[str]:
    pushed = (info.get("pushed_at") or "")[:10]
    visibility = "私有" if info.get("private") else "公开"
    license_name = (info.get("license") or {}).get("spdx_id") or "未声明"
    return [
        "  名称      %s" % info.get("full_name", "?"),
        "  描述      %s" % (info.get("description") or "（无）"),
        "  主语言    %s · %s · %s" % (info.get("language") or "未声明", visibility, license_name),
        "  规模      %s KB · %s stars · %s forks · 默认分支 %s" % (
            info.get("size", 0), info.get("stargazers_count", 0),
            info.get("forks_count", 0), info.get("default_branch", "?")),
        "  最近推送  %s" % (pushed or "未知"),
        "  地址      %s" % info.get("html_url", "?"),
    ]


# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="分析 GitHub 仓库：概况/语言/提交/贡献者/Issues/PRs/CI")
    parser.add_argument("repo", help="仓库标识，owner/repo 形式")
    parser.add_argument("--token", help="GitHub PAT（注意会留在 shell 历史，建议用 --token-env）")
    parser.add_argument("--token-env", default="GITHUB_TOKEN",
                        help="从该环境变量读取令牌（默认 GITHUB_TOKEN）")
    parser.add_argument("--json", action="store_true", help="输出 JSON 而非文本报告")
    args = parser.parse_args(argv)

    token = (args.token or "").strip() or __import__("os").environ.get(args.token_env, "").strip()

    problems = validate_inputs(args.repo, token)
    if problems:
        print("输入校验未通过：", file=sys.stderr)
        for item in problems:
            print("  ✗ " + item, file=sys.stderr)
        return EXIT_INPUT

    repo = args.repo.strip()
    failures: dict[str, str] = {}
    report: dict[str, object] = {"repo": repo, "authenticated": bool(token)}

    # ---- 鉴权预检：把「令牌坏了」和「仓库不可见」区分开 ----
    if token:
        code, data, headers = gh_request("/user", token)
        if code != 200:
            print("鉴权失败：%s" % explain(code, data, headers), file=sys.stderr)
            return EXIT_AUTH
        who = data.get("login", "?")
        print("已认证为 %s（%s）" % (who, rate_note(headers)))

    # ---- 仓库元信息：失败则整页退出 ----
    code, info, headers = gh_request("/repos/%s" % urllib.parse.quote(repo, safe="/"), token)
    if code != 200 or not isinstance(info, dict):
        print("无法访问仓库：%s" % explain(code, info, headers), file=sys.stderr)
        return EXIT_UNREACHABLE if code in (0, 301) else EXIT_AUTH
    report["overview"] = {k: info.get(k) for k in
                          ("full_name", "description", "language", "private",
                           "size", "stargazers_count", "forks_count",
                           "default_branch", "pushed_at", "html_url")}

    # ---- 其余章节：逐个降级 ----
    for key, path, params, _title in SECTIONS:
        code, data, headers = gh_request(path.format(repo=repo), token, params)
        if code != 200:
            failures[key] = explain(code, data, headers)
            continue
        report[key] = data
        report["rate_remaining"] = headers.get("X-RateLimit-Remaining")

    if args.json:
        report["failed_sections"] = failures
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return EXIT_OK if not failures else EXIT_PARTIAL

    # ---- 文本报告 ----
    print()
    print("GitHub 仓库分析报告")
    print("=" * 72)
    for line in render_repo_overview(info):
        print(line)
    print()

    titles = {key: title for key, _p, _pa, title in SECTIONS}
    for key, _path, _params, title in SECTIONS:
        if key in failures:
            continue
        print("%s" % title)
        print("-" * 72)
        for line in render_section(key, report.get(key)):
            print(line)
        print()

    if failures:
        print("未获取到的章节")
        print("-" * 72)
        for key, reason in failures.items():
            print("  ✗ %s：%s" % (titles[key], reason))
        print()

    print(rate_note({"X-RateLimit-Remaining": str(report.get("rate_remaining", "?")),
                     "X-RateLimit-Limit": "5000" if token else "60"}))
    return EXIT_OK if not failures else EXIT_PARTIAL


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
