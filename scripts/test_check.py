"""Regression and negative-case tests for scripts/check.py (zero third-party dependencies).

Covers M2-K09 isolated negative cases:
- Dart formatting error -> non-zero
- Flutter analyzer warning/info -> non-zero
- Failing Flutter test -> non-zero
- .flutter-version mismatch -> non-zero
- Linux Flutter archive SHA-256 mismatch -> non-zero

Run from any directory:
    python -B scripts/test_check.py
"""

from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.dont_write_bytecode = True

import check  # noqa: E402


def _make_fake_flutter_tar_xz(archive_path: Path, body: bytes = b"#!/bin/sh\necho flutter\n") -> str:
    with tarfile.open(archive_path, mode="w:xz") as tf:
        info = tarfile.TarInfo(name="flutter/bin/flutter")
        info.size = len(body)
        info.mode = 0o755
        tf.addfile(info, io.BytesIO(body))
    return hashlib.sha256(archive_path.read_bytes()).hexdigest()


class ToolAndParserUnitTests(unittest.TestCase):
    def test_parse_flutter_version_output_text_and_json(self) -> None:
        self.assertEqual(
            check.parse_flutter_version_output("Flutter 3.50.0 \u2022 channel stable\nTools \u2022 Dart 3.14.0\n"),
            "3.50.0",
        )
        self.assertEqual(
            check.parse_flutter_version_output('{"frameworkVersion": "3.50.0", "channel": "stable"}'),
            "3.50.0",
        )
        self.assertIsNone(check.parse_flutter_version_output("unrelated output"))

    def test_find_tool_windows_localappdata_fallback(self) -> None:
        with tempfile.TemporaryDirectory(prefix="blink-tool-fallback-") as tmp:
            base = Path(tmp)
            fl_bin = base / "Programs" / "flutter" / "bin"
            fl_bin.mkdir(parents=True)
            fl_bat = fl_bin / "flutter.bat"
            dt_bat = fl_bin / "dart.bat"
            fl_bat.write_text("@echo off\n", encoding="utf-8")
            dt_bat.write_text("@echo off\n", encoding="utf-8")

            env = {"PATH": "", "LOCALAPPDATA": str(base)}
            self.assertEqual(check.find_tool("flutter", platform="win32", env=env), str(fl_bat))
            self.assertEqual(check.find_tool("dart", platform="win32", env=env), str(dt_bat))
            self.assertIsNone(check.find_tool("flutter", platform="linux", env=env))

    def test_build_tool_env_strips_git_hook_variables(self) -> None:
        env = check.build_tool_env(
            base_env={
                "PATH": "/usr/bin",
                "GIT_DIR": "/some/repo/.git",
                "GIT_WORK_TREE": "/some/repo",
                "GIT_INDEX_FILE": "/some/repo/.git/index",
                "KEEP_ME": "yes",
            }
        )
        self.assertNotIn("GIT_DIR", env)
        self.assertNotIn("GIT_WORK_TREE", env)
        self.assertNotIn("GIT_INDEX_FILE", env)
        self.assertEqual(env["KEEP_ME"], "yes")
        self.assertEqual(env["BLINK_QUIET"], "1")


class LinuxFlutterArchiveTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="blink-linux-archive-")
        self.base = Path(self._tmp.name)
        self.root = self.base / "repo"
        self.dest = self.base / "runner-temp"
        self.root.mkdir()
        (self.root / "scripts").mkdir()
        (self.root / ".flutter-version").write_text("3.50.0\n", encoding="utf-8", newline="\n")
        self.archive_src = self.base / "flutter_linux_3.50.0-stable.tar.xz"
        self.valid_sha = _make_fake_flutter_tar_xz(self.archive_src)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _write_checksums(self, *, version: str = "3.50.0", linux_sha: str | None = None) -> None:
        payload = {
            "schemaVersion": 1,
            "baseUrl": check.OFFICIAL_FLUTTER_BASE_URL,
            "channel": "stable",
            "version": version,
            "archives": {
                "windows": {
                    "arch": "x64",
                    "archive": "stable/windows/flutter_windows_3.50.0-stable.zip",
                    "sha256": "a" * 64,
                },
                "linux": {
                    "arch": "x64",
                    "archive": "stable/linux/flutter_linux_3.50.0-stable.tar.xz",
                    "sha256": linux_sha if linux_sha is not None else self.valid_sha,
                },
            },
        }
        (self.root / "scripts" / "flutter-checksums.json").write_text(
            json.dumps(payload, indent=2) + "\n", encoding="utf-8", newline="\n"
        )

    def test_linux_flutter_archive_sha256_mismatch_fails_without_extracting(self) -> None:
        self._write_checksums(linux_sha="0" * 64)
        downloaded_urls: list[str] = []

        def fake_download(url: str, target: Path) -> None:
            downloaded_urls.append(url)
            shutil.copyfile(self.archive_src, target)

        stderr_buf = io.StringIO()
        with mock.patch("sys.stderr", stderr_buf):
            rc = check.install_linux_flutter(self.root, self.dest, downloader=fake_download)

        self.assertEqual(rc, 1)
        self.assertIn("SHA-256 mismatch", stderr_buf.getvalue())
        self.assertEqual(
            downloaded_urls,
            [f"{check.OFFICIAL_FLUTTER_BASE_URL}/stable/linux/flutter_linux_3.50.0-stable.tar.xz"],
        )
        self.assertFalse((self.dest / "flutter").exists())
        self.assertEqual(list(self.dest.glob("*.part")), [])

    def test_linux_flutter_archive_sha256_match_extracts_cleanly(self) -> None:
        self._write_checksums(linux_sha=self.valid_sha)

        def fake_download(url: str, target: Path) -> None:
            shutil.copyfile(self.archive_src, target)

        stdout_buf = io.StringIO()
        with mock.patch("sys.stdout", stdout_buf):
            rc = check.install_linux_flutter(self.root, self.dest, downloader=fake_download)

        self.assertEqual(rc, 0)
        self.assertTrue((self.dest / "flutter" / "bin" / "flutter").is_file())
        self.assertEqual(list(self.dest.glob("*.part")), [])

    def test_linux_flutter_version_mismatch_in_checksums_rejected(self) -> None:
        self._write_checksums(version="3.50.1", linux_sha=self.valid_sha)
        stderr_buf = io.StringIO()
        with mock.patch("sys.stderr", stderr_buf):
            rc = check.install_linux_flutter(self.root, self.dest, downloader=lambda _u, _t: None)
        self.assertEqual(rc, 1)
        self.assertIn("flutter-checksums.json version", stderr_buf.getvalue())


class GateOrchestrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="blink-gate-orch-")
        self.root = Path(self._tmp.name) / "repo"
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "apps" / "blink_client").mkdir(parents=True)
        (self.root / ".flutter-version").write_text("3.50.0\n", encoding="utf-8", newline="\n")
        for script_name in ("check_docs.py", "deps.py", "package.py", "test_sample.py"):
            (self.root / "scripts" / script_name).write_text("# stub\n", encoding="utf-8", newline="\n")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _make_fake_runner(self, *, fail_contains: str | None = None):
        calls: list[list[str]] = []

        def runner(cmd: list[str], cwd: Path, env: dict[str, str]) -> check.CommandResult:
            calls.append(cmd)
            joined = " ".join(cmd)
            if fail_contains and fail_contains in joined:
                return check.CommandResult(1, "", f"forced failure on {fail_contains}")
            if "--version" in cmd:
                return check.CommandResult(0, "Flutter 3.50.0 \u2022 channel stable\n", "")
            return check.CommandResult(0, "ok\n", "")

        return calls, runner

    def test_quick_and_ci_modes_run_ten_steps(self) -> None:
        pkg_dir = self.root / "packages" / "blink_sanitizer"
        (pkg_dir / "lib").mkdir(parents=True)
        (pkg_dir / "pubspec.yaml").write_text(
            "name: blink_sanitizer\nenvironment:\n  sdk: ^3.14.0\n",
            encoding="utf-8",
            newline="\n",
        )
        (pkg_dir / "lib" / "blink_sanitizer.dart").write_text(
            "int ok() => 1;\n",
            encoding="utf-8",
            newline="\n",
        )

        for mode in ("quick", "ci"):
            with self.subTest(mode=mode):
                calls, runner = self._make_fake_runner()
                rc, results = check.run_gate(
                    self.root,
                    mode=mode,
                    platform="linux",
                    runner=runner,
                    tool_finder=lambda name: f"/mock/bin/{name}",
                )
                self.assertEqual(rc, 0)
                self.assertEqual(
                    [r.name for r in results],
                    [
                        "docs",
                        "git-diff",
                        "flutter-version",
                        "python-tests",
                        "inv02-deps",
                        "dart-format",
                        "dart-analyze",
                        "dart-test",
                        "flutter-analyze",
                        "flutter-test",
                    ],
                )
                self.assertTrue(all(r.status == "passed" for r in results))
                self.assertTrue(any("format" in c and "--set-exit-if-changed" in c for c in calls))
                self.assertTrue(any(c[0].endswith("dart") and "analyze" in c and "--fatal-infos" in c for c in calls))
                self.assertTrue(any(c[0].endswith("dart") and "test" in c for c in calls))
                self.assertTrue(any(c[0].endswith("flutter") and "analyze" in c and "--fatal-infos" in c for c in calls))

    def test_inv02_rejects_flutter_import_in_packages(self) -> None:
        pkg_dir = self.root / "packages" / "blink_sanitizer"
        (pkg_dir / "lib").mkdir(parents=True)
        (pkg_dir / "pubspec.yaml").write_text(
            "name: blink_sanitizer\nenvironment:\n  sdk: ^3.14.0\n",
            encoding="utf-8",
            newline="\n",
        )
        (pkg_dir / "lib" / "bad.dart").write_text(
            "import 'package:flutter/widgets.dart';\n",
            encoding="utf-8",
            newline="\n",
        )
        res = check.check_inv02_dependencies_step(self.root)
        self.assertEqual(res.status, "failed")
        self.assertIn("package:flutter/", res.output)

    def test_inv02_rejects_blink_sanitizer_importing_or_depending_on_blink_core(self) -> None:
        pkg_dir = self.root / "packages" / "blink_sanitizer"
        (pkg_dir / "lib").mkdir(parents=True)
        (pkg_dir / "pubspec.yaml").write_text(
            "name: blink_sanitizer\ndependencies:\n  blink_core: any\n",
            encoding="utf-8",
            newline="\n",
        )
        (pkg_dir / "lib" / "bad.dart").write_text(
            "import 'package:blink_core/blink_core.dart';\n",
            encoding="utf-8",
            newline="\n",
        )
        res = check.check_inv02_dependencies_step(self.root)
        self.assertEqual(res.status, "failed")
        self.assertIn("blink_core", res.output)

    def test_inv02_allows_downward_dependency_and_ignores_comments(self) -> None:
        san_dir = self.root / "packages" / "blink_sanitizer"
        core_dir = self.root / "packages" / "blink_core"
        (san_dir / "lib").mkdir(parents=True)
        (core_dir / "lib").mkdir(parents=True)
        (san_dir / "pubspec.yaml").write_text(
            "name: blink_sanitizer\ndependencies:\n  html: 0.15.7\n",
            encoding="utf-8",
            newline="\n",
        )
        (san_dir / "lib" / "ok.dart").write_text(
            "// Never import 'package:flutter/material.dart';\n"
            "/* export 'package:blink_core/blink_core.dart'; */\n"
            "const int x = 1;\n",
            encoding="utf-8",
            newline="\n",
        )
        (core_dir / "pubspec.yaml").write_text(
            "name: blink_core\ndependencies:\n  blink_sanitizer: any\n",
            encoding="utf-8",
            newline="\n",
        )
        (core_dir / "lib" / "ok.dart").write_text(
            "import 'package:blink_sanitizer/blink_sanitizer.dart';\n",
            encoding="utf-8",
            newline="\n",
        )
        res = check.check_inv02_dependencies_step(self.root)
        self.assertEqual(res.status, "passed")

    def test_full_gate_windows_runs_packaging_without_install(self) -> None:
        calls, runner = self._make_fake_runner()
        rc, results = check.run_gate(
            self.root,
            mode="full",
            platform="win32",
            runner=runner,
            tool_finder=lambda name: f"mock_{name}",
        )
        self.assertEqual(rc, 0)
        names = [r.name for r in results]
        self.assertEqual(
            names[-4:],
            ["deps-audit", "package-dev", "package-release", "package-rehearsal"],
        )
        self.assertTrue(all(r.status == "passed" for r in results))
        pkg_calls = [c for c in calls if any("package.py" in arg for arg in c)]
        self.assertEqual(len(pkg_calls), 3)
        for cmd in pkg_calls:
            self.assertNotIn("--install", cmd)
        self.assertTrue(any("--channel" in c and "blink" in c and "--version" in c for c in pkg_calls))
        self.assertTrue(any("--rehearsal" in c for c in pkg_calls))

    def test_full_gate_non_windows_marks_packaging_not_run(self) -> None:
        calls, runner = self._make_fake_runner()
        rc, results = check.run_gate(
            self.root,
            mode="full",
            platform="linux",
            runner=runner,
            tool_finder=lambda name: f"/mock/bin/{name}",
        )
        self.assertEqual(rc, 0)
        by_name = {r.name: r for r in results}
        self.assertEqual(by_name["deps-audit"].status, "passed")
        for step_name in ("package-dev", "package-release", "package-rehearsal"):
            self.assertEqual(by_name[step_name].status, "not-run")
        self.assertFalse(any(any("package.py" in arg for arg in c) for c in calls))

    def test_full_gate_skips_windows_packaging_when_deps_audit_fails(self) -> None:
        calls, runner = self._make_fake_runner(fail_contains="deps.py")
        rc, results = check.run_gate(
            self.root,
            mode="full",
            platform="win32",
            runner=runner,
            tool_finder=lambda name: f"mock_{name}",
        )
        self.assertEqual(rc, 1)
        by_name = {r.name: r for r in results}
        self.assertEqual(by_name["deps-audit"].status, "failed")
        for step_name in ("package-dev", "package-release", "package-rehearsal"):
            self.assertEqual(by_name[step_name].status, "not-run")
        self.assertFalse(any(any("package.py" in arg for arg in c) for c in calls))


class RealToolchainNegativeTests(unittest.TestCase):
    """Isolated temp-directory M2-K09 negative cases run against real Dart/Flutter tools."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.flutter_bin = check.find_tool("flutter")
        cls.dart_bin = check.find_tool("dart")
        if not cls.flutter_bin or not cls.dart_bin:
            raise unittest.SkipTest("Flutter/Dart SDK not available on host")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="blink-real-k09-")
        self.root = Path(self._tmp.name) / "fixture"
        self.app_dir = self.root / "apps" / "blink_client"
        (self.app_dir / "lib").mkdir(parents=True)
        (self.app_dir / "test").mkdir(parents=True)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _write_minimal_dart_package(self, *, with_flutter_sdk: bool = False) -> None:
        if with_flutter_sdk:
            pubspec = (
                "name: blink_client\n"
                "environment:\n"
                "  sdk: ^3.14.0\n"
                "dependencies:\n"
                "  flutter:\n"
                "    sdk: flutter\n"
                "dev_dependencies:\n"
                "  flutter_test:\n"
                "    sdk: flutter\n"
            )
        else:
            pubspec = "name: blink_client\nenvironment:\n  sdk: ^3.14.0\n"
        (self.app_dir / "pubspec.yaml").write_text(pubspec, encoding="utf-8", newline="\n")
        if with_flutter_sdk:
            env = check.build_tool_env(self.flutter_bin)
            proc = subprocess.run(
                [self.flutter_bin, "--suppress-analytics", "pub", "get", "--offline"],
                cwd=str(self.app_dir),
                env=env,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                stdin=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0,
                check=False,
            )
            if proc.returncode != 0:
                self.skipTest(f"offline flutter pub get unavailable: {proc.stderr.strip()[:160]}")
        else:
            pkg_cfg = self.app_dir / ".dart_tool" / "package_config.json"
            pkg_cfg.parent.mkdir(parents=True, exist_ok=True)
            pkg_cfg.write_text(
                json.dumps(
                    {
                        "configVersion": 2,
                        "packages": [
                            {
                                "name": "blink_client",
                                "rootUri": "../",
                                "packageUri": "lib/",
                                "languageVersion": "3.14",
                            }
                        ],
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
                newline="\n",
            )

    def test_dart_format_error_returns_failed(self) -> None:
        self._write_minimal_dart_package(with_flutter_sdk=False)
        target = self.app_dir / "lib" / "sample.dart"
        target.write_text("int   unformatted = 1;\n", encoding="utf-8", newline="\n")
        res_bad = check.check_dart_format_step(self.root, check.default_runner, check.find_tool)
        self.assertEqual(res_bad.status, "failed")

        target.write_text("int formatted = 1;\n", encoding="utf-8", newline="\n")
        res_ok = check.check_dart_format_step(self.root, check.default_runner, check.find_tool)
        self.assertEqual(res_ok.status, "passed")

    def test_flutter_analyze_warning_or_info_returns_failed(self) -> None:
        self._write_minimal_dart_package(with_flutter_sdk=False)
        target = self.app_dir / "lib" / "sample.dart"
        target.write_text(
            "int compute() {\n  final unused = 1;\n  return 2;\n}\n",
            encoding="utf-8",
            newline="\n",
        )
        res_bad = check.check_flutter_analyze_step(self.root, check.default_runner, check.find_tool)
        self.assertEqual(res_bad.status, "failed")

        target.write_text("int compute() => 2;\n", encoding="utf-8", newline="\n")
        res_ok = check.check_flutter_analyze_step(self.root, check.default_runner, check.find_tool)
        self.assertEqual(res_ok.status, "passed")

    def test_flutter_test_failure_returns_failed(self) -> None:
        self._write_minimal_dart_package(with_flutter_sdk=True)
        test_file = self.app_dir / "test" / "sample_test.dart"
        test_file.write_text(
            "import 'package:flutter_test/flutter_test.dart';\n\n"
            "void main() {\n"
            "  test('fails on mismatch', () {\n"
            "    expect(1, 2);\n"
            "  });\n"
            "}\n",
            encoding="utf-8",
            newline="\n",
        )
        res_bad = check.check_flutter_test_step(self.root, check.default_runner, check.find_tool)
        self.assertEqual(res_bad.status, "failed")

        test_file.write_text(
            "import 'package:flutter_test/flutter_test.dart';\n\n"
            "void main() {\n"
            "  test('passes on match', () {\n"
            "    expect(1, 1);\n"
            "  });\n"
            "}\n",
            encoding="utf-8",
            newline="\n",
        )
        res_ok = check.check_flutter_test_step(self.root, check.default_runner, check.find_tool)
        self.assertEqual(res_ok.status, "passed")

    def test_flutter_version_mismatch_returns_failed(self) -> None:
        (self.root / ".flutter-version").write_text("0.0.0-mismatch\n", encoding="utf-8", newline="\n")
        res = check.check_flutter_version_step(self.root, check.default_runner, check.find_tool)
        self.assertEqual(res.status, "failed")
        self.assertIn("0.0.0-mismatch", res.detail)


if __name__ == "__main__":
    unittest.main(verbosity=1)
