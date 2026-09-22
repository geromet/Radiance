#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("rootauth", HERE / "syscall-root-authority.py")
rootauth = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(rootauth)

GOOD = b"# fixture\n0 common read sys_read\n1 64 write sys_write\n512 x32 read compat_read\n"

class RootAuthorityTests(unittest.TestCase):
    def test_acquire_then_offline_verify(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "source.tbl"
            source.write_bytes(GOOD)
            digest = hashlib.sha256(GOOD).hexdigest()
            artifact = root / "artifact"
            ev = rootauth.acquire(source, artifact, digest)
            self.assertEqual(ev["native_row_count"], 2)
            result = rootauth.verify_offline(artifact, digest)
            self.assertEqual(result["native_row_count"], 2)
            self.assertTrue((artifact / "syscall_64.tbl").is_file())

    def test_wrong_expected_digest_rejects_acquisition(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "source.tbl"
            source.write_bytes(GOOD)
            with self.assertRaises(rootauth.VerificationError):
                rootauth.acquire(source, root / "artifact", "0" * 64)

    def test_substituted_retained_bytes_reject(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "source.tbl"
            source.write_bytes(GOOD)
            digest = hashlib.sha256(GOOD).hexdigest()
            artifact = root / "artifact"
            rootauth.acquire(source, artifact, digest)
            (artifact / "syscall_64.tbl").write_bytes(GOOD + b"2 common open sys_open\n")
            with self.assertRaises(rootauth.VerificationError):
                rootauth.verify_offline(artifact, digest)

    def test_missing_retained_object_rejects(self):
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaises(rootauth.VerificationError):
                rootauth.verify_offline(Path(td), hashlib.sha256(GOOD).hexdigest())

    def test_unknown_abi_rejects(self):
        with self.assertRaises(rootauth.VerificationError):
            rootauth.parse_table(b"0 mystery read sys_read\n")

    def test_duplicate_native_number_rejects(self):
        with self.assertRaises(rootauth.VerificationError):
            rootauth.parse_table(b"0 common read sys_read\n0 64 write sys_write\n")

    def test_x32_rows_are_excluded(self):
        rows = rootauth.parse_table(GOOD)
        self.assertEqual(rows, [(0, "common", "read"), (1, "64", "write")])

    def test_tampered_acquisition_identity_rejects(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "source.tbl"
            source.write_bytes(GOOD)
            digest = hashlib.sha256(GOOD).hexdigest()
            artifact = root / "artifact"
            rootauth.acquire(source, artifact, digest)
            evidence = json.loads((artifact / "acquisition.json").read_text())
            evidence["blob"] = "deadbeef"
            (artifact / "acquisition.json").write_text(json.dumps(evidence))
            with self.assertRaises(rootauth.VerificationError):
                rootauth.verify_offline(artifact, digest)

if __name__ == "__main__":
    unittest.main()
