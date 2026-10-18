#!/usr/bin/env python3
"""External Gradle distribution identity primitive for the verification harness.

This helper deliberately does not trust Gradle/build-script self-reporting.  Given
an observed daemon command line, it identifies the Gradle launcher JAR used by
that process, requires it to live in a conventional extracted Gradle
installation, and emits a canonical content digest for that installation.

The caller must obtain cmdline bytes from the actual daemon (e.g.
/proc/<pid>/cmdline), supply a trusted, independently admitted Gradle
distribution root, and bind the resulting record to the accepted
attempt/process/start identity. This comparator is NOT that process witness,
a raw-Git source seal, or an end-to-end spec-7 acceptance oracle.
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import stat
import sys


def fail(message: str) -> "NoReturn":
    print(f"gradle distribution identity error: {message}", file=sys.stderr)
    raise SystemExit(1)


def canonical_tree_digest(root: Path) -> tuple[str, int]:
    root = root.resolve(strict=True)
    h = hashlib.sha256()
    count = 0
    for path in sorted(root.rglob("*"), key=lambda p: p.relative_to(root).as_posix().encode("utf-8")):
        rel = path.relative_to(root).as_posix()
        st = path.lstat()
        mode = stat.S_IMODE(st.st_mode)
        if path.is_symlink():
            fail(f"symlink in Gradle distribution is not admitted: {rel}")
        elif path.is_file():
            kind = "file"
            payload = path.read_bytes()
        elif path.is_dir():
            kind = "dir"
            payload = b""
        else:
            fail(f"unsupported filesystem object in Gradle distribution: {rel}")
        h.update(kind.encode() + b"\0" + f"{mode:o}".encode() + b"\0" + rel.encode("utf-8") + b"\0")
        h.update(hashlib.sha256(payload).digest())
        h.update(b"\0")
        count += 1
    return h.hexdigest(), count


def parse_cmdline(path: Path) -> list[str]:
    raw = path.read_bytes()
    if not raw or not raw.endswith(b"\0"):
        fail("cmdline evidence is empty or not NUL-terminated")
    parts = raw[:-1].split(b"\0")
    if not parts or any(not p for p in parts):
        fail("cmdline evidence contains an empty argument")
    return [p.decode("utf-8", "surrogateescape") for p in parts]


def launcher_from_args(args: list[str]) -> Path:
    candidates: list[Path] = []
    for arg in args:
        for component in arg.split(os.pathsep):
            if component.endswith("/lib/gradle-launcher-8.14.1.jar"):
                candidates.append(Path(component))
    unique = {str(p.resolve(strict=True)): p.resolve(strict=True) for p in candidates}
    if len(unique) != 1:
        fail(f"expected exactly one Gradle 8.14.1 launcher path, found {len(unique)}")
    return next(iter(unique.values()))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cmdline-file", required=True, type=Path)
    parser.add_argument("--expected-root", type=Path)
    parser.add_argument("--admitted-root", required=True, type=Path,
                        help="externally admitted distribution contents; NOT a daemon self-report")
    parser.add_argument("--output", required=True, type=Path)
    ns = parser.parse_args()

    args = parse_cmdline(ns.cmdline_file)
    launcher = launcher_from_args(args)
    if launcher.parent.name != "lib":
        fail("launcher is not below a Gradle lib directory")
    root = launcher.parent.parent.resolve(strict=True)
    expected = ns.expected_root.resolve(strict=True) if ns.expected_root else None
    if expected is not None and root != expected:
        fail(f"executing Gradle root {root} differs from expected root {expected}")

    launcher_sha = hashlib.sha256(launcher.read_bytes()).hexdigest()
    tree_sha, object_count = canonical_tree_digest(root)
    admitted_root = ns.admitted_root.resolve(strict=True)
    admitted_tree_sha, admitted_count = canonical_tree_digest(admitted_root)
    if not hmac.compare_digest(tree_sha, admitted_tree_sha) or object_count != admitted_count:
        fail("executing Gradle distribution content differs from admitted content")
    record = {
        "schema": 1,
        "gradle_version": "8.14.1",
        "distribution_root": str(root),
        "launcher_path": str(launcher),
        "launcher_sha256": launcher_sha,
        "distribution_tree_sha256": tree_sha,
        "distribution_object_count": object_count,
        "admitted_distribution_tree_sha256": admitted_tree_sha,
        "admitted_distribution_object_count": admitted_count,
        "distribution_content_reconciled": True,
    }
    ns.output.parent.mkdir(parents=True, exist_ok=True)
    ns.output.write_text(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
