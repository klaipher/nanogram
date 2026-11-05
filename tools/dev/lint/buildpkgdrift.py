#!/usr/bin/env python3
"""Report drift between the Bazel BUILD and the SwiftPM Package.swift of the shared core modules.

Both build systems compile the same core sources: Bazel for iOS, SwiftPM (through the Mac's Xcode workspace) for
the Mac. 34 modules carry both a BUILD file and a Package.swift, and nothing kept them in step. The 2026-11-04
merge had to fix duplicate declarations, a missing DiskWriteAccounting package and iOS-only MediaPlayer sources
leaking into SwiftPM (eea6c4e2) by hand.

For every submodules/<path>/ that has both files this compares

  * the module names the main library depends on (BUILD deps labels reduced to their target name, Package.swift
    `.product(name:)` / `.target(name:)` entries of the first non-test target), and
  * the files the library leaves out of its sources (BUILD glob `exclude`, Package.swift `exclude:`), by file name.

Differences are printed and never fail: some are intended (Mac-only or iOS-only dependencies, MediaPlayer's excluded
UIKit files), so this is a report to read when a module changes, not a gate yet.

  buildpkgdrift.py [--root DIR] [--module NAME] [--json] [--strict]

--strict exits 1 when any module differs (for a later gate). Pure text analysis; nothing is built.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

SOURCE_SUFFIXES = (".swift", ".m", ".mm", ".c", ".cc", ".cpp", ".h", ".hpp")
LIBRARY_RULES = ("swift_library", "objc_library", "swift6_library", "strict_swift_library", "cc_library")


@dataclass
class Described:
    deps: set[str] = field(default_factory=set)
    excludes: set[str] = field(default_factory=set)


@dataclass
class Difference:
    module: str
    deps_only_in_build: list[str]
    deps_only_in_package: list[str]
    excludes_only_in_build: list[str]
    excludes_only_in_package: list[str]

    @property
    def empty(self) -> bool:
        return not (self.deps_only_in_build or self.deps_only_in_package
                    or self.excludes_only_in_build or self.excludes_only_in_package)


def excluded_sources(group: str | None) -> set[str]:
    """File names of the excluded sources; directories (Tests) and the BUILD file itself are not sources."""
    names = {item.rsplit("/", 1)[-1] for item in strings(group or "")}
    return {name for name in names if name.endswith(SOURCE_SUFFIXES)}


def strip_comments(text: str, line_comment: str) -> str:
    out = []
    for line in text.splitlines():
        in_string = False
        cut = len(line)
        for index, char in enumerate(line):
            if char == '"' and (index == 0 or line[index - 1] != "\\"):
                in_string = not in_string
            elif not in_string and line.startswith(line_comment, index):
                cut = index
                break
        out.append(line[:cut])
    return "\n".join(out)


def balanced(text: str, start: int) -> str:
    """The text of the bracket group that opens at text[start] (including both brackets)."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = []
    in_string = False
    for index in range(start, len(text)):
        char = text[index]
        if char == '"' and text[index - 1] != "\\":
            in_string = not in_string
        elif in_string:
            continue
        elif char in pairs:
            stack.append(pairs[char])
        elif stack and char == stack[-1]:
            stack.pop()
            if not stack:
                return text[start:index + 1]
    return text[start:]


def strings(text: str) -> list[str]:
    return re.findall(r'"((?:[^"\\]|\\.)*)"', text)


def keyword_group(text: str, keyword: str) -> str | None:
    """The bracket group that follows `keyword =` (Starlark) or `keyword:` (Swift) at the first level of text."""
    match = re.search(rf"\b{re.escape(keyword)}\s*[=:]\s*(?:[A-Za-z_][\w.]*)?(?=[(\[{{])", text)
    if not match:
        return None
    return balanced(text, match.end())


def list_items(group: str | None) -> list[str]:
    """The strings of a list, or of every list inside a select({...}) (its condition keys are not dependencies)."""
    group = group or ""
    if group.startswith("["):
        return strings(group)
    items = []
    for index, char in enumerate(group):
        if char == "[":
            items += strings(balanced(group, index))
    return items


def build_label_module(label: str) -> str | None:
    """Bazel label to module name: "//a/b:C" -> C, "//a/b" -> b; external (@...) and local (:x) labels are skipped."""
    if not label.startswith("//"):
        return None
    package, _, target = label[2:].partition(":")
    return target or package.rsplit("/", 1)[-1]


def build_rules(text: str) -> list[tuple[str, str]]:
    rules = []
    for match in re.finditer(r"^(\w+)\(", text, re.MULTILINE):
        rules.append((match.group(1), balanced(text, match.end() - 1)))
    return rules


def describe_build(text: str, module: str) -> Described | None:
    text = strip_comments(text, "#")
    candidates = []
    for kind, body in build_rules(text):
        if kind not in LIBRARY_RULES or re.search(r"\btestonly\s*=\s*True", body):
            continue
        name = re.search(r'\bname\s*=\s*"([^"]+)"', body)
        module_name = re.search(r'\bmodule_name\s*=\s*"([^"]+)"', body)
        names = {name.group(1) if name else "", module_name.group(1) if module_name else ""}
        candidates.append((module in names, body))
    if not candidates:
        return None
    body = sorted(candidates, key=lambda c: not c[0])[0][1]
    result = Described()
    deps = keyword_group(body, "deps")
    for label in list_items(deps):
        name = build_label_module(label)
        if name:
            result.deps.add(name)
    result.excludes = excluded_sources(keyword_group(body, "exclude"))
    return result


def describe_package(text: str) -> Described | None:
    text = strip_comments(text, "//")
    for match in re.finditer(r"\.target\(", text):
        body = balanced(text, match.end() - 1)
        result = Described()
        deps = keyword_group(body, "dependencies")
        if deps is None:
            deps = ""
        for product in re.finditer(r'\.(?:product|target|byName)\(\s*name:\s*"([^"]+)"', deps):
            result.deps.add(product.group(1))
        stripped = re.sub(r"\.(?:product|target|byName)\([^()]*\)", "", deps)
        result.deps.update(strings(stripped))
        result.excludes = excluded_sources(keyword_group(body, "exclude"))
        return result
    return None


def compare(module: str, build: Described, package: Described) -> Difference:
    return Difference(module,
                      sorted(build.deps - package.deps), sorted(package.deps - build.deps),
                      sorted(build.excludes - package.excludes), sorted(package.excludes - build.excludes))


def modules(root: Path) -> list[Path]:
    found = []
    for build in sorted((root / "submodules").glob("**/BUILD")):
        directory = build.parent
        if (directory / "Package.swift").is_file() and "Tests" not in directory.parts:
            found.append(directory)
    return found


def scan(root: Path, only: str | None = None) -> tuple[list[Difference], list[str]]:
    differences, skipped = [], []
    for directory in modules(root):
        name = directory.name
        if only and name != only:
            continue
        build = describe_build((directory / "BUILD").read_text(errors="replace"), name)
        package = describe_package((directory / "Package.swift").read_text(errors="replace"))
        if build is None or package is None:
            skipped.append(f"{directory.relative_to(root).as_posix()}: no {'library rule in BUILD' if build is None else 'target in Package.swift'}")
            continue
        differences.append(compare(directory.relative_to(root).as_posix(), build, package))
    return differences, skipped


def render(differences: list[Difference], skipped: list[str]) -> list[str]:
    lines = []
    differing = [d for d in differences if not d.empty]
    for d in differing:
        lines.append(d.module)
        for label, values in (("dependencies only in BUILD", d.deps_only_in_build),
                              ("dependencies only in Package.swift", d.deps_only_in_package),
                              ("excluded only in BUILD", d.excludes_only_in_build),
                              ("excluded only in Package.swift", d.excludes_only_in_package)):
            if values:
                lines.append(f"  {label}: {', '.join(values)}")
    for note in skipped:
        lines.append(f"skipped {note}")
    lines.append(f"build/package drift: {len(differing)} of {len(differences)} module(s) with both files differ"
                 " (report only; some differences are intended)")
    return lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--module")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args(argv)
    differences, skipped = scan(args.root.resolve(), args.module)
    if args.json:
        print(json.dumps([d.__dict__ for d in differences if not d.empty], indent=1))
    else:
        print("\n".join(render(differences, skipped)))
    return 1 if args.strict and any(not d.empty for d in differences) else 0


if __name__ == "__main__":
    sys.exit(main())
