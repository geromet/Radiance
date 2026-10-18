#!/usr/bin/env python3
"""Deterministic fixture checks for the external Gradle content comparator.

These test *content reconciliation*, not actual daemon ownership, PID/start
correlation, source sealing, or complete spec-7 acceptance.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "tools" / "gradle-distribution-identity.py"


def make_dist(base: Path, marker: bytes) -> Path:
    root = base / "gradle-8.14.1"
    lib = root / "lib"
    lib.mkdir(parents=True)
    (lib / "gradle-launcher-8.14.1.jar").write_bytes(b"launcher:" + marker)
    (lib / "gradle-core-8.14.1.jar").write_bytes(b"core:" + marker)
    (root / "NOTICE").write_bytes(b"notice")
    return root


def identify(dist: Path, admitted: Path, work: Path, name: str,
             *, expected_root: Path | None = None, success: bool = True) -> dict | None:
    cmdline = work / f"{name}.cmdline"
    output = work / f"{name}.json"
    launcher = dist / "lib" / "gradle-launcher-8.14.1.jar"
    cmdline.write_bytes(("java\0-cp\0" + str(launcher)
                         + "\0org.gradle.launcher.daemon.bootstrap.GradleDaemon\0").encode())
    args = [sys.executable, str(HELPER), "--cmdline-file", str(cmdline),
            "--admitted-root", str(admitted), "--output", str(output)]
    if expected_root is not None:
        args += ["--expected-root", str(expected_root)]
    proc = subprocess.run(args, capture_output=True, text=True)
    if success:
        assert proc.returncode == 0, proc.stderr
        assert output.is_file(), "accepted content had no evidence"
        result = json.loads(output.read_text())
        assert result["distribution_content_reconciled"] is True
        assert result["distribution_tree_sha256"] == result["admitted_distribution_tree_sha256"]
        return result
    assert proc.returncode != 0, "non-equivalent content was accepted"
    assert not output.exists(), "failed reconciliation emitted accepted evidence"
    return None


def main() -> int:
    with tempfile.TemporaryDirectory() as td:
        work = Path(td)
        a = make_dist(work / "a", b"same")
        relocated = make_dist(work / "relocated", b"same")
        foreign = make_dist(work / "foreign", b"different")
        symlinked = make_dist(work / "symlinked", b"same")
        os.symlink("/etc/passwd", symlinked / "redirect")

        a_id = identify(a, a, work, "a")
        relocated_id = identify(relocated, a, work, "relocated")
        assert a_id["distribution_tree_sha256"] == relocated_id["distribution_tree_sha256"], "equivalent relocated content was rejected"
        assert a_id["distribution_root"] != relocated_id["distribution_root"], "relocation fixture is not distinct"

        identify(foreign, a, work, "foreign", success=False)
        identify(a, foreign, work, "wrong-admission", success=False)
        identify(a, a, work, "wrong-root", expected_root=foreign, success=False)
        identify(symlinked, symlinked, work, "symlink-escape", success=False)
    print("gradle-distribution-identity content controls: PASS (not full spec-7)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
