#!/usr/bin/env python3

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("check_apple_spm_locks.py")
SPEC = importlib.util.spec_from_file_location("check_apple_spm_locks", SCRIPT)
CHECKER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(CHECKER)


class AppleSpmLockCheckerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self._write_package_config(packages=[])
        self._write_all_locks(with_sentry=False)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_package_config(self, packages: list) -> None:
        path = self.root / ".dart_tool/package_config.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps({"configVersion": 2, "packages": packages}),
            encoding="utf-8",
        )

    def _lock_payload(self, with_sentry: bool) -> dict:
        pins = [
            {
                "identity": "mpv-build",
                "kind": "remoteSourceControl",
                "location": "https://github.com/example/mpv-build",
                "state": {"revision": "abc", "branch": "main"},
            }
        ]
        if with_sentry:
            pins.append(
                {
                    "identity": "sentry-cocoa",
                    "kind": "remoteSourceControl",
                    "location": "https://github.com/getsentry/sentry-cocoa",
                    "state": {"revision": "def", "version": "8.58.4"},
                }
            )
        return {"originHash": "fixture", "pins": pins, "version": 2}

    def _write_lock(self, relative: Path, with_sentry: bool) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self._lock_payload(with_sentry)), encoding="utf-8")

    def _write_all_locks(self, with_sentry: bool) -> None:
        for path in CHECKER.LOCK_PATHS:
            self._write_lock(path, with_sentry)

    def test_clean_graph_passes_library_and_cli(self) -> None:
        self.assertEqual([], CHECKER.validate(self.root))
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, completed.returncode, completed.stdout + completed.stderr)
        self.assertIn("no Sentry pins", completed.stdout)

    def test_reports_sentry_pin_in_ios_lock(self) -> None:
        self._write_lock(CHECKER.LOCK_PATHS[0], with_sentry=True)

        errors = CHECKER.validate(self.root)

        self.assertTrue(
            any("sentry-cocoa" in error and "ios" in error for error in errors),
            errors,
        )

    def test_reports_sentry_pin_in_macos_lock(self) -> None:
        self._write_lock(CHECKER.LOCK_PATHS[1], with_sentry=True)

        errors = CHECKER.validate(self.root)

        self.assertTrue(
            any("sentry-cocoa" in error and "macos" in error for error in errors),
            errors,
        )

    def test_reports_sentry_flutter_back_in_package_config(self) -> None:
        self._write_package_config(packages=[{"name": "sentry_flutter", "rootUri": "../packages/sentry_flutter"}])

        errors = CHECKER.validate(self.root)

        self.assertTrue(any("sentry_flutter" in error for error in errors), errors)

    def test_reports_missing_package_config(self) -> None:
        (self.root / ".dart_tool/package_config.json").unlink()

        errors = CHECKER.validate(self.root)

        self.assertTrue(any("flutter pub get first" in error for error in errors))

    def test_reports_malformed_lock(self) -> None:
        path = self.root / CHECKER.LOCK_PATHS[0]
        path.write_text(json.dumps({"version": 1, "pins": []}), encoding="utf-8")

        errors = CHECKER.validate(self.root)

        self.assertTrue(any("version-2 SwiftPM lock" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
