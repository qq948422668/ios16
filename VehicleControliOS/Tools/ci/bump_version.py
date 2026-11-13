#!/usr/bin/env python3
"""语义化版本递增工具。

单一真相源是仓库内 VehicleControliOS/VERSION（MAJOR.MINOR.PATCH）。
本工具在递增 VERSION 的同时同步 project.yml 中的两处字面值
（CFBundleShortVersionString / MARKETING_VERSION），保证本地直接
`xcodegen generate && xcodebuild` 不依赖环境变量也能拿到正确版本。

用法：
    python Tools/ci/bump_version.py            # 默认 PATCH 递增 1.0.0 -> 1.0.1
    python Tools/ci/bump_version.py --minor    # 1.0.0 -> 1.1.0
    python BUMP= python Tools/ci/bump_version.py --major   # 1.0.0 -> 2.0.0
    python Tools/ci/bump_version.py --set 1.2.3            # 显式设定
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]        # VehicleControliOS/
VERSION_FILE = ROOT / "VERSION"
PROJECT_FILE = ROOT / "project.yml"

SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def read_current() -> tuple[int, int, int]:
    text = VERSION_FILE.read_text(encoding="utf-8").strip()
    match = SEMVER.match(text)
    if not match:
        raise SystemExit(f"✗ VERSION 内容非法：{text!r}（期望 MAJOR.MINOR.PATCH）")
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def write_version(version: tuple[int, int, int]) -> None:
    literal = "%d.%d.%d" % version
    VERSION_FILE.write_text(literal + "\n", encoding="utf-8")

    project = PROJECT_FILE.read_text(encoding="utf-8")
    project = re.sub(
        r'CFBundleShortVersionString:\s*"\d+\.\d+\.\d+"',
        'CFBundleShortVersionString: "%s"' % literal,
        project)
    project = re.sub(
        r'MARKETING_VERSION:\s*"\d+\.\d+\.\d+"',
        'MARKETING_VERSION: "%s"' % literal,
        project)
    PROJECT_FILE.write_text(project, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="语义化版本递增")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--major", action="store_true", help="主版本 +1（破坏性变更）")
    group.add_argument("--minor", action="store_true", help="次版本 +1（新功能）")
    group.add_argument("--patch", action="store_true", help="修订号 +1（默认，缺陷修复）")
    group.add_argument("--none", action="store_true", help="不递增，仅校验")
    group.add_argument("--set", metavar="X.Y.Z", help="显式设定版本")
    args = parser.parse_args()

    current = read_current()
    current_literal = "%d.%d.%d" % current

    if args.set:
        if not SEMVER.match(args.set):
            raise SystemExit(f"✗ --set 需要合法语义化版本，收到 {args.set!r}")
        target = tuple(int(part) for part in args.set.split("."))
    elif args.major:
        target = (current[0] + 1, 0, 0)
    elif args.minor:
        target = (current[0], current[1] + 1, 0)
    elif args.none:
        target = current
    else:
        target = (current[0], current[1], current[2] + 1)

    if target != current:
        write_version(target)
    target_literal = "%d.%d.%d" % target
    print(f"version: {current_literal} -> {target_literal}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
