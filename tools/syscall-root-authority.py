#!/usr/bin/env python3
"""Fail-closed verifier for Fleet-Control #538's pinned Linux syscall root.

Acquisition is intentionally separate from proof consumption. `acquire` accepts bytes
only when the caller supplies the exact expected raw SHA-256 and records the pinned
commit/path/blob identity. `verify-offline` consumes only that retained artifact and
never performs network or Git/cache lookup.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

PINNED_COMMIT = "e8f897f4afef0031fe618a8e94127a0934896aba"
PINNED_PATH = "arch/x86/entry/syscalls/syscall_64.tbl"
PINNED_BLOB = "7e8d46f4147f574111962c214119af2dd2b62b4a"
EXTRACTOR_VERSION = 1
ALLOWED_ABI = {"common", "64"}
KNOWN_ABI = ALLOWED_ABI | {"x32"}

class VerificationError(RuntimeError):
    pass

def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def parse_table(data: bytes) -> list[tuple[int, str, str]]:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise VerificationError("syscall table is not UTF-8") from exc
    rows: list[tuple[int, str, str]] = []
    seen_nr: dict[int, str] = {}
    seen_name: dict[str, int] = {}
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 3:
            raise VerificationError(f"line {lineno}: malformed syscall row")
        try:
            nr = int(fields[0], 10)
        except ValueError as exc:
            raise VerificationError(f"line {lineno}: invalid syscall number") from exc
        abi, name = fields[1], fields[2]
        if abi not in KNOWN_ABI:
            raise VerificationError(f"line {lineno}: unknown ABI {abi!r}")
        if abi == "x32":
            continue
        if nr & 0x40000000:
            raise VerificationError(f"line {lineno}: x32 syscall bit in native universe")
        if nr in seen_nr:
            raise VerificationError(f"line {lineno}: duplicate native number {nr}")
        if name in seen_name:
            raise VerificationError(f"line {lineno}: duplicate native name {name}")
        seen_nr[nr] = name
        seen_name[name] = nr
        rows.append((nr, abi, name))
    rows.sort()
    if not rows:
        raise VerificationError("empty native syscall universe")
    return rows

def enumeration_bytes(rows: list[tuple[int, str, str]]) -> bytes:
    return "".join(f"{nr}\t{abi}\t{name}\n" for nr, abi, name in rows).encode()

def acquire(source: Path, out_dir: Path, expected_sha256: str) -> dict[str, object]:
    data = source.read_bytes()
    actual = sha256(data)
    if actual != expected_sha256.lower():
        raise VerificationError(f"raw SHA-256 mismatch: expected {expected_sha256}, got {actual}")
    rows = parse_table(data)
    enum = enumeration_bytes(rows)
    out_dir.mkdir(parents=True, exist_ok=False)
    retained = out_dir / "syscall_64.tbl"
    retained.write_bytes(data)
    retained.chmod(stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)
    evidence = {
        "schema": 1,
        "phase": "acquisition",
        "commit": PINNED_COMMIT,
        "path": PINNED_PATH,
        "blob": PINNED_BLOB,
        "raw_sha256": actual,
        "extractor_version": EXTRACTOR_VERSION,
        "enumeration_sha256": sha256(enum),
        "native_row_count": len(rows),
    }
    (out_dir / "acquisition.json").write_text(json.dumps(evidence, sort_keys=True, indent=2) + "\n")
    return evidence

def verify_offline(artifact_dir: Path, expected_sha256: str) -> dict[str, object]:
    retained = artifact_dir / "syscall_64.tbl"
    evidence_path = artifact_dir / "acquisition.json"
    if not retained.is_file() or not evidence_path.is_file():
        raise VerificationError("retained source or acquisition evidence missing")
    evidence = json.loads(evidence_path.read_text())
    expected_identity = (PINNED_COMMIT, PINNED_PATH, PINNED_BLOB)
    got_identity = (evidence.get("commit"), evidence.get("path"), evidence.get("blob"))
    if got_identity != expected_identity:
        raise VerificationError("pinned commit/path/blob identity mismatch")
    data = retained.read_bytes()
    actual = sha256(data)
    if actual != expected_sha256.lower() or evidence.get("raw_sha256") != actual:
        raise VerificationError("retained source digest mismatch")
    rows = parse_table(data)
    enum_digest = sha256(enumeration_bytes(rows))
    if evidence.get("enumeration_sha256") != enum_digest or evidence.get("native_row_count") != len(rows):
        raise VerificationError("retained enumeration evidence mismatch")
    # This command has no networking/Git code path by construction. CI must additionally
    # execute it in a mechanically network-denied environment for spec22 proof.
    return {"raw_sha256": actual, "enumeration_sha256": enum_digest, "native_row_count": len(rows)}

def main() -> int:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("acquire")
    a.add_argument("--source", type=Path, required=True)
    a.add_argument("--out", type=Path, required=True)
    a.add_argument("--expected-sha256", required=True)
    v = sub.add_parser("verify-offline")
    v.add_argument("--artifact", type=Path, required=True)
    v.add_argument("--expected-sha256", required=True)
    ns = p.parse_args()
    try:
        result = acquire(ns.source, ns.out, ns.expected_sha256) if ns.cmd == "acquire" else verify_offline(ns.artifact, ns.expected_sha256)
    except (OSError, ValueError, json.JSONDecodeError, VerificationError) as exc:
        print(f"SYSCALL_ROOT_REJECT: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
