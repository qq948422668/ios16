#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Swift 静态检查（零依赖，Linux/macOS/Windows 可跑）。

不是为了替代编译器，而是把「必然导致 Xcode 编译失败」的低级错误挡在
昂贵的 macOS runner 之前。检查项：

  1. 括号 / 引号配平
  2. 顶层类型重复声明（同 module 内 redeclaration）
  3. `struct/enum ... : @unchecked Sendable`（@unchecked 只能用于 class/actor）
  4. 引用了未声明的类型（白名单外）
  5. 项目内协议的方法/属性要求未被实现
  6. project.yml 的 target 名、工作流 SCHEME、后台任务标识符是否一致

用法：
  python Tools/ci/swift_static_check.py            # 在 VehicleControliOS/ 下执行
退出码 0 = 通过，1 = 有错误。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "Sources"

# 系统框架/SDK 类型名白名单（本项目实际用到的部分）。
SDK_TYPES = {
    # Swift / Foundation
    "Any", "AnyHashable", "Array", "Bool", "Bundle", "CancellationError", "CaseIterable",
    "CharacterSet", "CheckedContinuation", "Codable", "Data", "Date", "Decodable", "Decoder",
    "DecodingError", "Dictionary", "Encodable", "Encoder", "Equatable", "Error", "FileManager",
    "Hashable", "Identifiable", "Int", "JSONDecoder", "JSONEncoder", "LocalizedError", "NSLock",
    "NSError", "NSURLErrorCancelled", "NSURLErrorDomain", "NSTemporaryDirectory", "Never",
    "Optional", "ProcessInfo", "RawRepresentable", "Result", "Self", "Sendable", "Set",
    "String", "Task", "TimeInterval", "URL", "URLComponents", "URLQueryItem", "URLRequest",
    "URLResponse", "URLSession", "URLSessionConfiguration", "URLSessionWebSocketTask",
    "URLError", "UUID", "UInt64", "Void", "HTTPURLResponse", "DispatchQueue", "Double",
    # Task / 并发
    "AsyncStream", "AsyncThrowingStream", "MainActor", "actor", "Task",
    # SwiftUI
    "Binding", "Button", "Capsule", "Circle", "Color", "Divider", "EnvironmentObject",
    "ForEach", "GridItem", "Group", "HStack", "Image", "Label", "LazyVGrid", "List", "Menu",
    "NavigationLink", "NavigationStack", "ObservableObject", "ProgressView", "Published",
    "RoundedRectangle", "ScrollView", "Spacer", "State", "StateObject", "SwiftUI", "Text",
    "ToolbarItem", "VStack", "View", "ViewBuilder", "Visibility", "LocalizedStringKey",
    "Spacer", "EmptyView", "ZStack",
    # UIKit
    "UIKit", "UIApplication", "UIApplicationDelegate", "UIWindow", "UIWindowScene",
    "UIScreen", "UIResponder", "UIViewController",
    # AuthenticationServices
    "ASWebAuthenticationSession", "ASWebAuthenticationPresentationContextProviding",
    "ASPresentationAnchor", "ASWebAuthenticationSessionError",
    "ASWebAuthenticationSessionErrorDomain", "AuthenticationServices",
    # BackgroundTasks
    "BGTask", "BGTaskScheduler", "BGAppRefreshTaskRequest", "BackgroundTasks",
    # UserNotifications
    "UNNotification", "UNNotificationPresentationOptions", "UNNotificationResponse",
    "UNUserNotificationCenter", "UNUserNotificationCenterDelegate", "UserNotifications",
    # CryptoKit / Security / os
    "CryptoKit", "SHA256", "Security", "SecRandomCopyBytes", "SecItemAdd", "SecItemCopyMatching",
    "SecItemDelete", "SecItemUpdate",     "OSStatus", "CFTypeRef", "CFDictionary", "errSecSuccess",
    "errSecItemNotFound", "os", "Logger", "App", "Scene", "WindowGroup",
    "ISO8601DateFormatter", "NSObject", "UIApplicationDelegateAdaptor", "UInt8",
    "UIApplicationLaunchOptionsKey", "UIApplicationLaunchOptionsKey",
}

# 允许「先引用、后声明」或由编译期属性生成的写法。
IGNORED_IDENTIFIERS = {"Self", "T", "R", "A", "M", "Body"}

DECL_RE = re.compile(
    r"^\s*(?:@\w+\s+)*(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+)*"
    r"(struct|enum|class|actor|protocol|typealias)\s+([A-Z]\w*)",
    re.MULTILINE,
)


def swift_files() -> list[Path]:
    return sorted(SOURCES.rglob("*.swift"))


def strip_noise(text: str) -> str:
    """去掉字符串字面量与注释，避免误报。

    顺序很关键：必须先删字符串再删注释，否则 URL 里的 `//` 会被当成行注释，
    把后续的 `)` 一起吃掉。
    """
    text = re.sub(r'"""(?:.|\n)*?"""', '""', text)
    text = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def find_block_end(text: str, open_index: int) -> int:
    """从 '{' 位置开始，返回匹配 '}' 的下标。"""
    depth = 0
    for index in range(open_index, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
    return -1


def collect_declarations(files: dict[Path, str]) -> tuple[dict[str, Path], list[str]]:
    declared: dict[str, Path] = {}
    duplicates: list[str] = []
    for path, text in files.items():
        for match in DECL_RE.finditer(text):
            name = match.group(2)
            if name in declared and declared[name] != path:
                duplicates.append(f"{name}: {declared[name].name} 与 {path.name} 重复声明")
            else:
                declared[name] = path
        # 泛型参数不是类型引用，登记后跳过
        for generic in re.finditer(r"\b(?:struct|enum|class|actor|protocol|func)\s+\w+\s*<([^>]*)>", text):
            for parameter in generic.group(1).split(","):
                name = parameter.strip().split(":")[0].strip()
                if name and name[0].isupper():
                    declared.setdefault(name, path)
    return declared, duplicates


def check_balance(path: Path, raw: str) -> list[str]:
    text = strip_noise(raw)
    problems = []
    for opener, closer in (("{", "}"), ("(", ")"), ("[", "]")):
        if text.count(opener) != text.count(closer):
            problems.append(
                f"{path.name}: '{opener}' 与 '{closer}' 数量不一致 "
                f"({text.count(opener)} vs {text.count(closer)})"
            )
    if raw.count('"') % 2 != 0:
        problems.append(f"{path.name}: 双引号数量为奇数，可能有未闭合字符串")
    return problems


def check_unchecked_usage(path: Path, raw: str) -> list[str]:
    problems = []
    for match in re.finditer(r"\b(struct|enum)\s+([A-Z]\w*)[^{]*:\s*@unchecked\s+Sendable", raw):
        problems.append(
            f"{path.name}: '{match.group(2)}' 是 {match.group(1)}，"
            f"@unchecked Sendable 只能用于 class/actor"
        )
    return problems


def check_protocol_conformance(files: dict[Path, str], declared: dict[str, Path]) -> list[str]:
    """项目内协议：检查 conforming 类型是否实现了每个要求（含 extension 默认实现）。"""
    protocols: dict[str, set[str]] = {}
    defaults: dict[str, set[str]] = {}

    for path, text in files.items():
        for match in re.finditer(r"\bprotocol\s+([A-Z]\w*)[^{]*\{", text):
            name = match.group(1)
            start = match.end() - 1
            end = find_block_end(text, start)
            if end < 0:
                continue
            body = text[start + 1:end]
            requirements = set()
            for func in re.finditer(r"\bfunc\s+([a-zA-Z_]\w*)\s*[<(]", body):
                requirements.add(func.group(1))
            for prop in re.finditer(r"\bvar\s+([a-zA-Z_]\w*)\s*:", body):
                requirements.add(prop.group(1))
            protocols[name] = requirements

        for match in re.finditer(r"\bextension\s+([A-Z]\w*)\s*(?::[^{]*)?\{", text):
            name = match.group(1)
            start = match.end() - 1
            end = find_block_end(text, start)
            if end < 0:
                continue
            body = text[start + 1:end]
            names = set()
            for func in re.finditer(r"\bfunc\s+([a-zA-Z_]\w*)\s*[<(]", body):
                names.add(func.group(1))
            for prop in re.finditer(r"\bvar\s+([a-zA-Z_]\w*)\s*[:{]", body):
                names.add(prop.group(1))
            defaults.setdefault(name, set()).update(names)

    problems = []
    for path, text in files.items():
        for match in re.finditer(
            r"\b(?:struct|class|actor|final class)\s+([A-Z]\w*)\s*:\s*([^{]+)\{", text
        ):
            type_name = match.group(1)
            conformances = [c.strip().split("<")[0].strip() for c in match.group(2).split(",")]
            project_protocols = [c for c in conformances if c in protocols]
            if not project_protocols:
                continue

            start = match.end() - 1
            end = find_block_end(text, start)
            if end < 0:
                continue
            body = text[start + 1:end]

            implemented = set()
            for func in re.finditer(r"\bfunc\s+([a-zA-Z_]\w*)\s*[<(]", body):
                implemented.add(func.group(1))
            for prop in re.finditer(r"\b(?:var|let)\s+([a-zA-Z_]\w*)\s*[:{=]", body):
                implemented.add(prop.group(1))

            for proto in project_protocols:
                for requirement in protocols[proto]:
                    if requirement in implemented:
                        continue
                    if requirement in defaults.get(proto, set()):
                        continue
                    problems.append(
                        f"{path.name}: '{type_name}' 声明遵循 {proto}，"
                        f"但未实现 '{requirement}'"
                    )
    return problems


def check_type_references(files: dict[Path, str], declared: dict[str, Path]) -> list[str]:
    """粗粒度检查：引用了既非项目声明、也不在白名单的「看起来像类型」的标识符。"""
    known = set(declared) | SDK_TYPES | IGNORED_IDENTIFIERS
    unknown: dict[str, Path] = {}

    for path, raw in files.items():
        text = strip_noise(raw)
        # 去掉成员访问（.Foo）与泛型参数声明
        text = re.sub(r"\.\s*[A-Z]\w*", "", text)
        for match in re.finditer(r"(?<![\w.])[A-Z][A-Za-z0-9_]{2,}(?![\w])", text):
            name = match.group(0)
            if name in known:
                continue
            # 只保留「类型位置」的用法，降低误报
            tail = text[match.end():match.end() + 3]
            head = text[max(0, match.start() - 4):match.start()]
            if re.match(r"\s*[\(\[\]?>:,.)]", tail) or re.search(r"(->|:\s|any |some |as[!?]|\bas\s)\s*$", head):
                unknown.setdefault(name, path)

    return [
        f"未声明的类型引用：'{name}'（{path.name}）"
        for name, path in sorted(unknown.items())
    ]


def check_build_config() -> list[str]:
    """target 名 / 工作流 SCHEME / 后台任务标识符必须一致，否则 CI 会白跑一次。"""
    problems = []
    yml = ROOT / "project.yml"
    if not yml.exists():
        return ["project.yml 不存在"]

    text = yml.read_text(encoding="utf-8")
    target_match = re.search(r"^\s{2}([A-Za-z][\w-]*):\s*$", text, re.MULTILINE)
    targets = re.findall(r"^  ([A-Za-z][\w-]*):\s*$", text, re.MULTILINE)
    if not targets:
        problems.append("project.yml 未找到 target 定义")
    elif target_match and target_match.group(1) not in targets:
        problems.append("project.yml target 解析异常")

    workflow = ROOT.parent / ".github" / "workflows" / "ios-build.yml"
    if workflow.exists() and targets:
        workflow_text = workflow.read_text(encoding="utf-8")
        scheme = re.search(r"SCHEME:\s*(\S+)", workflow_text)
        if scheme and scheme.group(1) not in targets:
            problems.append(
                f"工作流 SCHEME={scheme.group(1)} 与 project.yml target {targets} 不一致"
            )

        project_bundle = re.search(r"PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)", text)
        wf_bundle = re.search(r"BUNDLE_ID:\s*(\S+)", workflow_text)
        if project_bundle and wf_bundle and wf_bundle.group(1) != project_bundle.group(1):
            problems.append(
                f"工作流 BUNDLE_ID={wf_bundle.group(1)} 与 project.yml 的"
                f" PRODUCT_BUNDLE_IDENTIFIER={project_bundle.group(1)} 不一致"
            )

    codemagic = ROOT.parent / "codemagic.yaml"
    project_bundle = re.search(r"PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)", text)
    if codemagic.exists() and project_bundle:
        cm_bundle = re.search(
            r"<key>(com\.[\w.]+)</key>", codemagic.read_text(encoding="utf-8")
        )
        if cm_bundle and cm_bundle.group(1) != project_bundle.group(1):
            problems.append(
                f"codemagic 导出配置的 bundle '{cm_bundle.group(1)}' 与"
                f" project.yml 的 {project_bundle.group(1)} 不一致"
            )

    refresher = SOURCES / "Services" / "BackgroundRefresher.swift"
    if refresher.exists():
        identifier = re.search(
            r'taskIdentifier\s*=\s*"([^"]+)"', refresher.read_text(encoding="utf-8")
        )
        if identifier and identifier.group(1) not in text:
            problems.append(
                f"后台任务标识符 '{identifier.group(1)}' 未在 project.yml 的"
                f" BGTaskSchedulerPermittedIdentifiers 中登记"
            )
    return problems


def main() -> int:
    files: dict[Path, str] = {}
    for path in swift_files():
        files[path] = path.read_text(encoding="utf-8")

    if not files:
        print("ERROR: Sources/ 下没有 Swift 文件")
        return 1

    declared, duplicates = collect_declarations(files)

    problems: list[str] = []
    for path, text in files.items():
        problems += check_balance(path, text)
        problems += check_unchecked_usage(path, text)
    problems += duplicates
    problems += check_protocol_conformance(files, declared)
    problems += check_type_references(files, declared)
    problems += check_build_config()

    print(f"扫描 {len(files)} 个 Swift 文件，声明 {len(declared)} 个类型")

    if problems:
        print(f"\n发现 {len(problems)} 个问题：")
        for problem in problems:
            print("  ✗ " + problem)
        return 1

    print("静态检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
