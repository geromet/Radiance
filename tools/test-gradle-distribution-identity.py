#!/usr/bin/env python3
import json
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


def identify(dist: Path, work: Path, name: str) -> dict:
    cmdline = work / f"{name}.cmdline"
    output = work / f"{name}.json"
    launcher = dist / "lib" / "gradle-launcher-8.14.1.jar"
    cmdline.write_bytes(("java\0-cp\0" + str(launcher) + "\0org.gradle.launcher.daemon.bootstrap.GradleDaemon\0").encode())
    subprocess.run([sys.executable, str(HELPER), "--cmdline-file", str(cmdline), "--expected-root", str(dist), "--output", str(output)], check=True)
    return json.loads(output.read_text())


def main() -> int:
    with tempfile.TemporaryDirectory() as td:
        work = Path(td)
        a = make_dist(work / "a", b"same")
        relocated = make_dist(work / "relocated", b"same")
        foreign = make_dist(work / "foreign", b"different")

        a_id = identify(a, work, "a")
        relocated_id = identify(relocated, work, "relocated")
        foreign_id = identify(foreign, work, "foreign")

        assert a_id["distribution_tree_sha256"] == relocated_id["distribution_tree_sha256"], "equivalent relocation changed content identity"
        assert a_id["distribution_tree_sha256"] != foreign_id["distribution_tree_sha256"], "non-equivalent same-version distribution inherited identity"

        wrong = work / "wrong.json"
        proc = subprocess.run([sys.executable, str(HELPER), "--cmdline-file", str(work / "a.cmdline"), "--expected-root", str(foreign), "--output", str(wrong)])
        assert proc.returncode != 0, "wrong expected distribution root was accepted"
        assert not wrong.exists(), "failed identity check emitted accepted evidence"
    print("gradle-distribution-identity controls: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
