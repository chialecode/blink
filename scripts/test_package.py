"""Zero-dependency unit tests for scripts/package.py and blink.iss.

Covers packaging version rules, single-latest artifact retention, Inno Setup 7.1.x
compiler version guard, and the full dev auto-install decision matrix using
isolated temporary directories and injectable fakes.
"""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import package  # noqa: E402


class FakeClock:
    """Deterministic clock for fast timeout and timestamp assertions."""

    def __init__(self, start_mono: float = 100.0) -> None:
        self._mono = start_mono
        self.slept: list[float] = []
        self._now = datetime(2026, 11, 23, 0, 30, 0, tzinfo=timezone.utc)

    def monotonic(self) -> float:
        return self._mono

    def sleep(self, seconds: float) -> None:
        self.slept.append(seconds)
        self._mono += seconds

    def utc_now(self) -> datetime:
        return self._now


class FakeRegistrySpy:
    """In-memory HKCU Uninstall store spying on every identity read or write."""

    def __init__(self, entries: dict[str, package.UninstallEntry] | None = None) -> None:
        self._entries: dict[str, package.UninstallEntry] = dict(entries or {})
        self.read_keys: list[str] = []
        self.written_keys: list[str] = []

    def read_dev_only(self) -> package.UninstallEntry | None:
        subkey = package.IDENTITY_SPECS["blink-dev"].uninstall_subkey
        self.read_keys.append(subkey)
        return self._entries.get("blink-dev")

    def set_entry(self, identity: str, entry: package.UninstallEntry) -> None:
        subkey = package.IDENTITY_SPECS[identity].uninstall_subkey
        self.written_keys.append(subkey)
        self._entries[identity] = entry

    def assert_only_dev_key_touched(self, test: unittest.TestCase) -> None:
        dev_key = package.IDENTITY_SPECS["blink-dev"].uninstall_subkey
        forbidden = {
            package.IDENTITY_SPECS["blink"].uninstall_subkey,
            package.IDENTITY_SPECS["blink-test"].uninstall_subkey,
            package.IDENTITY_SPECS["blink-dev-test"].uninstall_subkey,
        }
        for key in self.read_keys + self.written_keys:
            test.assertNotIn(key, forbidden, f"Forbidden uninstall key accessed: {key}")
            test.assertEqual(key, dev_key)


class FakeInstallHarness:
    """Composable test double for engineering.md 2.2 dev auto-install."""

    def __init__(
        self,
        *,
        dev_entry: package.UninstallEntry | None,
        running_polls_before_exit: int = 0,
        stays_running_forever: bool = False,
        quit_result: package.QuitRequestResult | None = None,
        installer_rc: int = 0,
        post_install_reg_version: str | None = None,
        post_install_exe_version: str | None = None,
        in_job: bool = False,
        explorer_succeeds: bool = True,
        breakaway_succeeds: bool = True,
        direct_succeeds: bool = True,
        tray_verified: bool = True,
    ) -> None:
        initial: dict[str, package.UninstallEntry] = {
            "blink": package.UninstallEntry(
                install_location=Path("mock_programs") / "blink",
                display_version="0.1.0",
            ),
            "blink-test": package.UninstallEntry(
                install_location=Path("mock_tmp") / "blink-test",
                display_version="0.1.0",
            ),
            "blink-dev-test": package.UninstallEntry(
                install_location=Path("mock_tmp") / "blink-dev-test",
                display_version="0.1.0-dev.202611230000",
            ),
        }
        if dev_entry is not None:
            initial["blink-dev"] = dev_entry
        self.registry = FakeRegistrySpy(initial)
        self.clock = FakeClock()

        self._stays_running = stays_running_forever
        self._running_remaining = running_polls_before_exit
        self._quit_result = quit_result or package.QuitRequestResult(ok=True, busy=False, detail="accepted")
        self._installer_rc = installer_rc
        self._post_reg_ver = post_install_reg_version
        self._post_exe_ver = post_install_exe_version
        self._in_job = in_job
        self._explorer_ok = explorer_succeeds
        self._breakaway_ok = breakaway_succeeds
        self._direct_ok = direct_succeeds
        self._tray_verified = tray_verified

        self.quit_calls: list[tuple[Path, str, float]] = []
        self.installer_calls: list[Path] = []
        self.explorer_calls: list[tuple[Path, list[str]]] = []
        self.breakaway_calls: list[tuple[Path, list[str]]] = []
        self.direct_calls: list[tuple[Path, list[str]]] = []
        self.tray_verify_calls: list[tuple[str, float]] = []
        self.force_kill_calls: int = 0

    def _is_running(self, identity: str) -> bool:
        assert identity == "blink-dev"
        if self._stays_running:
            return True
        if self._running_remaining > 0:
            self._running_remaining -= 1
            return True
        return False

    def _request_quit(self, exe_path: Path, identity: str, timeout_s: float) -> package.QuitRequestResult:
        self.quit_calls.append((exe_path, identity, timeout_s))
        self.clock.sleep(0.1)
        return self._quit_result

    def _run_installer(self, installer_path: Path) -> int:
        self.installer_calls.append(installer_path)
        if self._installer_rc == 0 and self._post_reg_ver is not None:
            existing = self.registry.read_dev_only()
            loc = existing.install_location if existing is not None else (Path("mock_programs") / "blink-dev")
            self.registry.set_entry(
                "blink-dev",
                package.UninstallEntry(install_location=loc, display_version=self._post_reg_ver),
            )
        return self._installer_rc

    def _read_exe_version(self, exe_path: Path) -> str:
        assert exe_path.name == "blink-dev.exe"
        if self._post_exe_ver is None:
            raise package.PackageError("Simulated missing PE version")
        return self._post_exe_ver

    def _launch_explorer(self, exe_path: Path, args: list[str]) -> bool:
        self.explorer_calls.append((exe_path, list(args)))
        return self._explorer_ok

    def _launch_breakaway(self, exe_path: Path, args: list[str]) -> bool:
        self.breakaway_calls.append((exe_path, list(args)))
        return self._breakaway_ok

    def _launch_direct(self, exe_path: Path, args: list[str]) -> bool:
        self.direct_calls.append((exe_path, list(args)))
        return self._direct_ok

    def _verify_tray(self, identity: str, timeout_s: float) -> bool:
        self.tray_verify_calls.append((identity, timeout_s))
        return self._tray_verified

    def build_deps(self) -> package.DevInstallDeps:
        return package.DevInstallDeps(
            read_dev_uninstall_entry=self.registry.read_dev_only,
            is_running=self._is_running,
            request_quit_for_update=self._request_quit,
            run_installer=self._run_installer,
            read_exe_product_version=self._read_exe_version,
            is_in_job_object=lambda: self._in_job,
            launch_via_explorer_shell=self._launch_explorer,
            launch_with_breakaway=self._launch_breakaway,
            launch_direct=self._launch_direct,
            verify_running_in_tray=self._verify_tray,
            clock=self.clock,
        )


class VersionCalculationTests(unittest.TestCase):
    def test_dev_default_version_uses_utc_timestamp(self) -> None:
        fixed_utc = datetime(2026, 11, 23, 4, 15, 42, tzinfo=timezone.utc)
        info = package.compute_version("blink-dev", None, dirty=False, now_utc=fixed_utc)
        self.assertEqual(info.version, "0.1.0-dev.202611230415")
        self.assertEqual(info.file_version_comma, "0,1,0,0")
        self.assertEqual(info.file_version_str, "0.1.0.0")
        self.assertFalse(info.dirty)

    def test_dev_version_appends_dirty_when_working_tree_dirty(self) -> None:
        fixed_utc = datetime(2026, 11, 23, 4, 15, 0, tzinfo=timezone.utc)
        info = package.compute_version("blink-dev", None, dirty=True, now_utc=fixed_utc)
        self.assertEqual(info.version, "0.1.0-dev.202611230415+dirty")
        self.assertEqual(info.file_version_str, "0.1.0.0")
        self.assertTrue(info.dirty)

    def test_formal_channel_requires_explicit_version(self) -> None:
        with self.assertRaises(package.PackageError):
            package.compute_version("blink", None, dirty=False)
        with self.assertRaises(package.PackageError):
            package.compute_version("blink", "   ", dirty=False)

    def test_formal_channel_accepts_semver_and_rejects_prerelease(self) -> None:
        clean = package.compute_version("blink", "0.1.2", dirty=False)
        self.assertEqual(clean.version, "0.1.2")
        self.assertEqual(clean.file_version_comma, "0,1,2,0")
        self.assertEqual(clean.file_version_str, "0.1.2.0")

        dirty = package.compute_version("blink", "0.1.0", dirty=True)
        self.assertEqual(dirty.version, "0.1.0+dirty")
        self.assertTrue(dirty.dirty)

        with self.assertRaises(package.PackageError):
            package.compute_version("blink", "0.1.0-dev.202611230000", dirty=False)

    def test_cmake_env_contains_all_contract_variables(self) -> None:
        spec = package.IDENTITY_SPECS["blink-dev"]
        ver = package.compute_version("blink-dev", "0.1.0-dev.202611230102", dirty=False)
        env = package.build_cmake_env({"EXISTING": "1"}, spec, ver)
        self.assertEqual(env["EXISTING"], "1")
        self.assertEqual(env["BLINK_PRODUCT_VERSION"], "0.1.0-dev.202611230102")
        self.assertEqual(env["BLINK_FILE_VERSION"], "0,1,0,0")
        self.assertEqual(env["BLINK_FILE_VERSION_STR"], "0.1.0.0")
        self.assertEqual(env["BLINK_PRODUCT_NAME"], "BLINK Dev")
        self.assertEqual(env["BLINK_INTERNAL_NAME"], "blink-dev")
        self.assertEqual(env["BLINK_ORIGINAL_FILENAME"], "blink-dev.exe")
        self.assertEqual(env["BLINK_ICON_FILE"], "blink-dev.ico")
        self.assertTrue(env["BLINK_FILE_DESCRIPTION"])

    def test_identity_specs_match_channel_isolation_contract(self) -> None:
        self.assertEqual(
            package.IDENTITY_SPECS["blink"].uninstall_key_name,
            "io.github.chialecode.blink_is1",
        )
        self.assertEqual(
            package.IDENTITY_SPECS["blink-dev"].uninstall_key_name,
            "io.github.chialecode.blink-dev_is1",
        )
        self.assertEqual(
            package.IDENTITY_SPECS["blink-dev-test"].uninstall_key_name,
            "io.github.chialecode.blink-dev-test_is1",
        )
        self.assertEqual(package.IDENTITY_SPECS["blink-dev"].mutex_name, "blink-dev-instance")
        self.assertEqual(package.IDENTITY_SPECS["blink-dev"].pipe_name, r"\\.\pipe\blink-dev-control")
        self.assertEqual(package.IDENTITY_SPECS["blink"].icon_file, "blink.ico")
        self.assertEqual(package.IDENTITY_SPECS["blink-dev"].icon_file, "blink-dev.ico")


class PackagingRetentionAndIssGuardTests(unittest.TestCase):
    def test_atomic_replace_directory_keeps_only_latest_installer_set(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dest = root / "dist" / "blink-dev"
            dest.mkdir(parents=True)
            (dest / "blink-dev-setup-0.1.0-dev.202611220000.exe").write_bytes(b"old")
            (dest / "SHA256SUMS.txt").write_text("oldsum  old.exe\n", encoding="utf-8")

            staging = root / "staging"
            staging.mkdir()
            (staging / "blink-dev-setup-0.1.0-dev.202611230000.exe").write_bytes(b"new")
            (staging / "SHA256SUMS.txt").write_text("newsum  new.exe\n", encoding="utf-8")
            (staging / "build-info.json").write_text('{"version":"0.1.0-dev.202611230000"}\n', encoding="utf-8")

            package.atomic_replace_directory(staging, dest)

            names = sorted(p.name for p in dest.iterdir())
            self.assertEqual(
                names,
                [
                    "SHA256SUMS.txt",
                    "blink-dev-setup-0.1.0-dev.202611230000.exe",
                    "build-info.json",
                ],
            )
            parent_names = sorted(p.name for p in dest.parent.iterdir())
            self.assertEqual(parent_names, ["blink-dev"])

    def test_missing_flutter_or_iscc_raises_clear_error(self) -> None:
        with self.assertRaises(package.PackageError):
            package.find_flutter_executable({"PATH": ""})
        with self.assertRaises(package.PackageError):
            package.find_iscc_executable({"PATH": ""})

    def test_iss_script_enforces_inno_setup_7_1_x_and_per_user_defaults(self) -> None:
        iss_path = package.ISS_PATH
        self.assertTrue(iss_path.is_file(), "apps/blink_client/windows/packaging/blink.iss must exist")
        raw = iss_path.read_bytes()
        self.assertFalse(raw.startswith(b"\xef\xbb\xbf"), "blink.iss must not have UTF-8 BOM")
        self.assertNotIn(b"\r\n", raw, "blink.iss must use LF line endings")

        text = raw.decode("utf-8")
        self.assertIn("Ver < EncodeVer(7, 1, 0) || Ver >= EncodeVer(7, 2, 0)", text)
        self.assertIn("PrivilegesRequired=lowest", text)
        self.assertIn(r"DefaultDirName={userpf}\{#BlinkIdentity}", text)
        self.assertIn("AppId={#BlinkAppId}", text)
        self.assertIn("AppVersion={#BlinkVersion}", text)
        self.assertIn("AppMutex={#BlinkIdentity}-instance", text)
        self.assertIn("CloseApplications=no", text)
        self.assertIn("RestartApplications=no", text)
        self.assertIn('AppUserModelID: "{#BlinkAppId}"', text)
        self.assertIn('Name: "desktopicon"', text)
        self.assertIn("Flags: unchecked", text)
        self.assertNotIn("[UninstallDelete]", text)

        if sys.platform != "win32":
            return

        try:
            iscc = package.find_iscc_executable()
        except package.PackageError:
            self.skipTest("ISCC.exe not available on host")

        with tempfile.TemporaryDirectory() as tmp:
            td = Path(tmp)
            for bad_expr in ("EncodeVer(7, 0, 9)", "EncodeVer(7, 2, 0)", "EncodeVer(6, 4, 0)"):
                wrapper = td / "bad_ver.iss"
                wrapper.write_text(
                    f'#define Ver {bad_expr}\n#include "{iss_path}"\n',
                    encoding="utf-8",
                )
                proc = subprocess.run(
                    [str(iscc), "--preprocess", str(wrapper)],
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    creationflags=package.CREATE_NO_WINDOW,
                )
                self.assertNotEqual(
                    proc.returncode,
                    0,
                    f"Expected blink.iss to reject compiler version {bad_expr}",
                )
                self.assertIn("7.1.x", proc.stderr + proc.stdout)

            ok_proc = subprocess.run(
                [
                    str(iscc),
                    "--preprocess",
                    "/DBlinkIdentity=blink-dev-test",
                    "/DBlinkAppId=io.github.chialecode.blink-dev-test",
                    "/DBlinkProductName=BLINK Dev Test",
                    "/DBlinkVersion=0.1.0-dev.202611230000",
                    "/DBlinkFileVersionStr=0.1.0.0",
                    f"/DBlinkSourceDir={td}",
                    f"/DBlinkIconFile={td / 'dummy.ico'}",
                    f"/DBlinkOutputDir={td}",
                    str(iss_path),
                ],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                creationflags=package.CREATE_NO_WINDOW,
            )
            self.assertEqual(ok_proc.returncode, 0, ok_proc.stderr + ok_proc.stdout)

    def test_snapshot_diff_detects_registry_and_start_menu_changes(self) -> None:
        base = {
            "uninstall_keys": {"blink": {"exists": False, "values": {}}},
            "start_menu": {"user_start_menu": []},
            "localappdata": {"localappdata_blink": []},
            "desktop": [],
        }
        self.assertEqual(package.diff_snapshots(base, dict(base)), {})

        changed = dict(base)
        changed["start_menu"] = {"user_start_menu": ["BLINK Dev Test.lnk"]}
        diff = package.diff_snapshots(base, changed)
        self.assertIn("start_menu", diff)


class DevAutoInstallDecisionTests(unittest.TestCase):
    def _run_case(
        self,
        harness: FakeInstallHarness,
        *,
        channel: str = "blink-dev",
        identity: str | None = None,
        new_version: str = "0.1.0-dev.202611230030",
        dirty: bool = False,
        env: dict[str, str] | None = None,
        platform_name: str = "win32",
    ) -> tuple[int, dict[str, object]]:
        with tempfile.TemporaryDirectory() as tmp:
            td = Path(tmp)
            receipt_path = td / "artifacts" / "package" / "install-dev.json"
            installer_path = td / "dist" / "blink-dev" / f"blink-dev-setup-{new_version}.exe"
            installer_path.parent.mkdir(parents=True, exist_ok=True)
            installer_path.write_bytes(b"fake-installer")

            rc, receipt = package.run_dev_auto_install(
                channel=channel,
                identity=identity,
                installer_path=installer_path,
                new_version=new_version,
                dirty=dirty,
                env=env if env is not None else {},
                deps=harness.build_deps(),
                receipt_path=receipt_path,
                repo_root=td,
                platform_name=platform_name,
            )
            self.assertTrue(receipt_path.is_file(), "install-dev.json receipt must be written")
            persisted = json.loads(receipt_path.read_text(encoding="utf-8"))
            self.assertEqual(persisted, receipt)
            return rc, receipt

    def test_not_installed_skips_cleanly_and_reports_installer_path(self) -> None:
        harness = FakeInstallHarness(dev_entry=None)
        rc, receipt = self._run_case(harness)

        self.assertEqual(rc, 0)
        self.assertEqual(receipt["status"], "skipped")
        self.assertFalse(receipt["installed"])
        self.assertEqual(receipt["reason"], "not_installed")
        self.assertIn("dist/blink-dev/blink-dev-setup-", str(receipt["guidance"]))
        self.assertEqual(harness.quit_calls, [])
        self.assertEqual(harness.installer_calls, [])
        self.assertEqual(harness.direct_calls, [])
        harness.registry.assert_only_dev_key_touched(self)

    def test_not_running_installs_verifies_and_launches_background_tray(self) -> None:
        new_ver = "0.1.0-dev.202611230030"
        harness = FakeInstallHarness(
            dev_entry=package.UninstallEntry(
                install_location=Path("mock_programs") / "blink-dev",
                display_version="0.1.0-dev.202611220000",
            ),
            running_polls_before_exit=0,
            installer_rc=0,
            post_install_reg_version=new_ver,
            post_install_exe_version=new_ver,
            in_job=False,
        )
        rc, receipt = self._run_case(harness, new_version=new_ver)

        self.assertEqual(rc, 0)
        self.assertEqual(receipt["status"], "installed")
        self.assertTrue(receipt["installed"])
        self.assertEqual(receipt["previous_version"], "0.1.0-dev.202611220000")
        self.assertEqual(receipt["new_version"], new_ver)
        self.assertFalse(receipt["was_running"])
        self.assertIsNone(receipt["quit_elapsed_seconds"])
        self.assertTrue(receipt["running_in_tray"])
        self.assertFalse(receipt["inJob"])
        self.assertEqual(receipt["launch_method"], "direct")
        self.assertEqual(harness.quit_calls, [])
        self.assertEqual(len(harness.installer_calls), 1)
        self.assertEqual(len(harness.direct_calls), 1)
        self.assertEqual(harness.direct_calls[0][1], ["--background"])
        harness.registry.assert_only_dev_key_touched(self)

    def test_running_instance_quits_cleanly_installs_and_relaunches(self) -> None:
        new_ver = "0.1.0-dev.202611230045+dirty"
        harness = FakeInstallHarness(
            dev_entry=package.UninstallEntry(
                install_location=Path("mock_programs") / "blink-dev",
                display_version="0.1.0-dev.202611220000",
            ),
            running_polls_before_exit=3,
            installer_rc=0,
            post_install_reg_version=new_ver,
            post_install_exe_version=new_ver,
            in_job=False,
        )
        rc, receipt = self._run_case(harness, new_version=new_ver, dirty=True)

        self.assertEqual(rc, 0)
        self.assertEqual(receipt["status"], "installed")
        self.assertTrue(receipt["installed"])
        self.assertTrue(receipt["dirty"])
        self.assertTrue(receipt["was_running"])
        self.assertIsNotNone(receipt["quit_elapsed_seconds"])
        self.assertGreater(float(receipt["quit_elapsed_seconds"]), 0.0)
        self.assertTrue(receipt["running_in_tray"])
        self.assertEqual(len(harness.quit_calls), 1)
        self.assertEqual(len(harness.installer_calls), 1)
        self.assertEqual(len(harness.direct_calls), 1)
        self.assertEqual(harness.direct_calls[0][1], ["--background"])
        harness.registry.assert_only_dev_key_touched(self)

    def test_running_instance_30s_timeout_aborts_without_force_kill(self) -> None:
        harness = FakeInstallHarness(
            dev_entry=package.UninstallEntry(
                install_location=Path("mock_programs") / "blink-dev",
                display_version="0.1.0-dev.202611220000",
            ),
            stays_running_forever=True,
        )
        rc, receipt = self._run_case(harness)

        self.assertNotEqual(rc, 0)
        self.assertEqual(receipt["status"], "failed")
        self.assertFalse(receipt["installed"])
        self.assertTrue(receipt["was_running"])
        self.assertEqual(receipt["reason"], "quit_timeout")
        self.assertGreaterEqual(float(receipt["quit_elapsed_seconds"]), 30.0)
        self.assertEqual(harness.force_kill_calls, 0)
        self.assertEqual(harness.installer_calls, [])
        self.assertEqual(harness.explorer_calls, [])
        self.assertEqual(harness.breakaway_calls, [])
        self.assertEqual(harness.direct_calls, [])
        harness.registry.assert_only_dev_key_touched(self)

    def test_running_instance_busy_aborts_without_force_kill(self) -> None:
        harness = FakeInstallHarness(
            dev_entry=package.UninstallEntry(
                install_location=Path("mock_programs") / "blink-dev",
                display_version="0.1.0-dev.202611220000",
            ),
            running_polls_before_exit=5,
            quit_result=package.QuitRequestResult(ok=False, busy=True, detail='{"ok":false,"reason":"busy"}'),
        )
        rc, receipt = self._run_case(harness)

        self.assertNotEqual(rc, 0)
        self.assertEqual(receipt["status"], "failed")
        self.assertFalse(receipt["installed"])
        self.assertTrue(receipt["was_running"])
        self.assertEqual(receipt["reason"], "busy")
        self.assertEqual(harness.force_kill_calls, 0)
        self.assertEqual(harness.installer_calls, [])
        self.assertEqual(harness.direct_calls, [])
        harness.registry.assert_only_dev_key_touched(self)

    def test_installer_failure_returns_nonzero_without_launching(self) -> None:
        harness = FakeInstallHarness(
            dev_entry=package.UninstallEntry(
                install_location=Path("mock_programs") / "blink-dev",
                display_version="0.1.0-dev.202611220000",
            ),
            installer_rc=5,
        )
        rc, receipt = self._run_case(harness)

        self.assertNotEqual(rc, 0)
        self.assertEqual(receipt["status"], "failed")
        self.assertFalse(receipt["installed"])
        self.assertEqual(receipt["reason"], "installer_failed_exit_5")
        self.assertEqual(harness.direct_calls, [])
        self.assertEqual(harness.explorer_calls, [])
        harness.registry.assert_only_dev_key_touched(self)

    def test_registry_or_exe_version_mismatch_fails_without_launching(self) -> None:
        new_ver = "0.1.0-dev.202611230030"
        old_ver = "0.1.0-dev.202611220000"

        for label, reg_v, exe_v in (
            ("registry_mismatch", old_ver, new_ver),
            ("exe_mismatch", new_ver, old_ver),
        ):
            with self.subTest(label):
                harness = FakeInstallHarness(
                    dev_entry=package.UninstallEntry(
                        install_location=Path("mock_programs") / "blink-dev",
                        display_version=old_ver,
                    ),
                    installer_rc=0,
                    post_install_reg_version=reg_v,
                    post_install_exe_version=exe_v,
                )
                rc, receipt = self._run_case(harness, new_version=new_ver)

                self.assertNotEqual(rc, 0)
                self.assertEqual(receipt["status"], "failed")
                self.assertFalse(receipt["installed"])
                self.assertEqual(receipt["reason"], "version_mismatch")
                self.assertEqual(receipt["verified_registry_version"], reg_v)
                self.assertEqual(receipt["verified_exe_version"], exe_v)
                self.assertEqual(harness.direct_calls, [])
                self.assertEqual(harness.explorer_calls, [])
                harness.registry.assert_only_dev_key_touched(self)

    def test_job_object_launch_fallback_order_and_in_job_true_receipt(self) -> None:
        new_ver = "0.1.0-dev.202611230030"
        dev_entry = package.UninstallEntry(
            install_location=Path("mock_programs") / "blink-dev",
            display_version="0.1.0-dev.202611220000",
        )

        # 1. Explorer shell succeeds -> detached from job.
        h1 = FakeInstallHarness(
            dev_entry=dev_entry,
            post_install_reg_version=new_ver,
            post_install_exe_version=new_ver,
            in_job=True,
            explorer_succeeds=True,
        )
        rc1, rec1 = self._run_case(h1, new_version=new_ver)
        self.assertEqual(rc1, 0)
        self.assertEqual(rec1["launch_method"], "explorer_shell")
        self.assertFalse(rec1["inJob"])
        self.assertEqual(len(h1.explorer_calls), 1)
        self.assertEqual(h1.explorer_calls[0][1], ["--background"])
        self.assertEqual(h1.breakaway_calls, [])
        self.assertEqual(h1.direct_calls, [])

        # 2. Explorer unavailable -> breakaway succeeds.
        h2 = FakeInstallHarness(
            dev_entry=dev_entry,
            post_install_reg_version=new_ver,
            post_install_exe_version=new_ver,
            in_job=True,
            explorer_succeeds=False,
            breakaway_succeeds=True,
        )
        rc2, rec2 = self._run_case(h2, new_version=new_ver)
        self.assertEqual(rc2, 0)
        self.assertEqual(rec2["launch_method"], "breakaway")
        self.assertFalse(rec2["inJob"])
        self.assertEqual(len(h2.explorer_calls), 1)
        self.assertEqual(len(h2.breakaway_calls), 1)
        self.assertEqual(h2.direct_calls, [])

        # 3. Both explorer and breakaway unavailable -> direct launch records inJob=True + Start Menu guidance.
        h3 = FakeInstallHarness(
            dev_entry=dev_entry,
            post_install_reg_version=new_ver,
            post_install_exe_version=new_ver,
            in_job=True,
            explorer_succeeds=False,
            breakaway_succeeds=False,
            direct_succeeds=True,
        )
        rc3, rec3 = self._run_case(h3, new_version=new_ver)
        self.assertEqual(rc3, 0)
        self.assertEqual(rec3["launch_method"], "direct_in_job")
        self.assertTrue(rec3["inJob"])
        self.assertIn("Start Menu", str(rec3["guidance"]))
        self.assertEqual(len(h3.direct_calls), 1)
        self.assertEqual(h3.direct_calls[0][1], ["--background"])

    def test_env_disable_and_ci_flags_skip_cleanly(self) -> None:
        dev_entry = package.UninstallEntry(
            install_location=Path("mock_programs") / "blink-dev",
            display_version="0.1.0-dev.202611220000",
        )
        for env_map, expected_reason in (
            ({"BLINK_DEV_AUTO_INSTALL": "0"}, "disabled_by_env"),
            ({"CI": "true"}, "ci_environment"),
            ({"CI": "1"}, "ci_environment"),
        ):
            with self.subTest(expected_reason):
                harness = FakeInstallHarness(dev_entry=dev_entry)
                rc, receipt = self._run_case(harness, env=env_map)
                self.assertEqual(rc, 0)
                self.assertEqual(receipt["status"], "skipped")
                self.assertFalse(receipt["installed"])
                self.assertEqual(receipt["reason"], expected_reason)
                self.assertEqual(harness.registry.read_keys, [])
                self.assertEqual(harness.installer_calls, [])
                self.assertEqual(harness.direct_calls, [])

    def test_non_windows_install_reports_not_run(self) -> None:
        harness = FakeInstallHarness(dev_entry=None)
        rc, receipt = self._run_case(harness, platform_name="linux")
        self.assertEqual(rc, 0)
        self.assertEqual(receipt["status"], "not-run")
        self.assertFalse(receipt["installed"])
        self.assertEqual(harness.registry.read_keys, [])

    def test_formal_channel_and_test_identities_refused_without_touching_registry(self) -> None:
        for channel, ident in (
            ("blink", "blink"),
            ("blink", "blink-test"),
            ("blink-dev", "blink-dev-test"),
        ):
            with self.subTest(f"{channel}/{ident}"):
                harness = FakeInstallHarness(dev_entry=None)
                rc, receipt = self._run_case(harness, channel=channel, identity=ident)
                self.assertNotEqual(rc, 0)
                self.assertEqual(receipt["status"], "failed")
                self.assertEqual(receipt["reason"], "invalid_channel_for_install")
                self.assertEqual(harness.registry.read_keys, [])
                self.assertEqual(harness.registry.written_keys, [])
                self.assertEqual(harness.installer_calls, [])

    def test_real_dev_uninstall_reader_targets_only_blink_dev_identity(self) -> None:
        with mock.patch.object(package, "read_uninstall_entry_for_identity", return_value=None) as patched:
            result = package.read_dev_uninstall_entry()
        self.assertIsNone(result)
        patched.assert_called_once_with("blink-dev")


class CliAndHelperTests(unittest.TestCase):
    def test_cli_rejects_invalid_flag_combinations(self) -> None:
        buf = io.StringIO()
        with redirect_stderr(buf), redirect_stdout(buf):
            self.assertNotEqual(package.main(["--install", "--rehearsal"]), 0)
            self.assertNotEqual(package.main(["--rehearsal", "--channel", "blink"]), 0)
            self.assertNotEqual(package.main(["--rehearsal", "--version", "0.1.0"]), 0)

            with tempfile.TemporaryDirectory() as tmp:
                with mock.patch.object(package, "ARTIFACTS_PACKAGE_DIR", Path(tmp)):
                    self.assertNotEqual(package.main(["--channel", "blink", "--install"]), 0)
                    receipt = json.loads((Path(tmp) / "install-dev.json").read_text(encoding="utf-8"))
                    self.assertEqual(receipt["reason"], "invalid_channel_for_install")

    def test_cli_install_env_skip_short_circuits_without_building(self) -> None:
        buf = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp:
            with (
                redirect_stderr(buf),
                redirect_stdout(buf),
                mock.patch.object(package, "ARTIFACTS_PACKAGE_DIR", Path(tmp)),
                mock.patch.object(package, "build_windows_package", side_effect=AssertionError("must not build")),
                mock.patch.dict("os.environ", {"BLINK_DEV_AUTO_INSTALL": "0"}, clear=False),
            ):
                rc = package.main(["--install"])
            self.assertEqual(rc, 0)
            receipt = json.loads((Path(tmp) / "install-dev.json").read_text(encoding="utf-8"))
            self.assertEqual(receipt["status"], "skipped")
            self.assertEqual(receipt["reason"], "disabled_by_env")

    def test_quit_for_update_exit_code_classification(self) -> None:
        fake_exe = Path("mock_programs") / "blink-dev" / "blink-dev.exe"

        with mock.patch.object(
            subprocess,
            "run",
            return_value=subprocess.CompletedProcess([str(fake_exe)], 0, stdout="", stderr=""),
        ):
            res = package.request_quit_for_update_process(fake_exe, "blink-dev", 5.0)
            self.assertTrue(res.ok)
            self.assertFalse(res.busy)

        # Windows GUI subsystem exe may exit with code 2 and empty stdout/stderr on busy.
        with mock.patch.object(
            subprocess,
            "run",
            return_value=subprocess.CompletedProcess([str(fake_exe)], 2, stdout="", stderr=""),
        ):
            res = package.request_quit_for_update_process(fake_exe, "blink-dev", 5.0)
            self.assertFalse(res.ok)
            self.assertTrue(res.busy)

        with mock.patch.object(
            subprocess,
            "run",
            return_value=subprocess.CompletedProcess(
                [str(fake_exe)], 1, stdout='{"ok": false, "reason": "busy"}', stderr=""
            ),
        ):
            res = package.request_quit_for_update_process(fake_exe, "blink-dev", 5.0)
            self.assertFalse(res.ok)
            self.assertTrue(res.busy)

        with mock.patch.object(
            subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired([str(fake_exe)], 5.0),
        ):
            res = package.request_quit_for_update_process(fake_exe, "blink-dev", 5.0)
            self.assertFalse(res.ok)
            self.assertFalse(res.busy)

    def test_atomic_replace_directory_restores_previous_on_swap_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dest = root / "dist" / "blink-dev"
            dest.mkdir(parents=True)
            (dest / "previous.txt").write_text("keep-me\n", encoding="utf-8")

            staging = root / "staging"
            staging.mkdir()
            (staging / "new.txt").write_text("new\n", encoding="utf-8")

            real_replace = package.os.replace
            calls = {"n": 0}

            def flaky_replace(src: Path, dst: Path) -> None:
                calls["n"] += 1
                if calls["n"] == 2:
                    raise OSError("simulated swap error")
                real_replace(src, dst)

            with mock.patch.object(package.os, "replace", side_effect=flaky_replace):
                with self.assertRaises(OSError):
                    package.atomic_replace_directory(staging, dest)

            self.assertTrue((dest / "previous.txt").is_file())
            self.assertEqual((dest / "previous.txt").read_text(encoding="utf-8"), "keep-me\n")

    def test_lifecycle_json_validation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            data_dir = Path(tmp)
            lc = data_dir / "run" / "lifecycle.json"
            lc.parent.mkdir(parents=True)
            lc.write_text(
                json.dumps(
                    {
                        "exitReason": "quit-for-update",
                        "windowWasVisible": False,
                        "version": "0.1.0-dev.202611230001",
                        "identity": "blink-dev-test",
                        "timestampUtc": "2026-11-23T00:30:00Z",
                    }
                ),
                encoding="utf-8",
            )
            parsed = package._validate_lifecycle_json(
                data_dir,
                expected_version="0.1.0-dev.202611230001",
                expected_identity="blink-dev-test",
                expected_window_visible=False,
            )
            self.assertEqual(parsed["version"], "0.1.0-dev.202611230001")

            with self.assertRaises(package.PackageError):
                package._validate_lifecycle_json(
                    data_dir,
                    expected_version="0.1.0-dev.202611230002",
                    expected_identity="blink-dev-test",
                )

    def test_windows_pe_product_version_reader_on_python_executable(self) -> None:
        if sys.platform != "win32":
            self.skipTest("Windows-only PE version reader test")
        pv = package.read_exe_product_version(Path(sys.executable))
        self.assertTrue(pv)
        self.assertTrue(pv[0].isdigit())


class SubprocessDecodingTests(unittest.TestCase):
    """F-001 regression: text-mode subprocess output must not depend on the host ANSI code page."""

    def test_text_mode_subprocess_calls_declare_utf8_decoding(self) -> None:
        import ast

        offenders: list[str] = []
        for script in sorted(SCRIPTS_DIR.glob("*.py")):
            tree = ast.parse(script.read_text(encoding="utf-8"), filename=script.name)
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                kwargs = {kw.arg: kw.value for kw in node.keywords if kw.arg}
                text_kw = kwargs.get("text")
                if not (isinstance(text_kw, ast.Constant) and text_kw.value is True):
                    continue
                encoding_kw = kwargs.get("encoding")
                errors_kw = kwargs.get("errors")
                if not (
                    isinstance(encoding_kw, ast.Constant)
                    and encoding_kw.value == "utf-8"
                    and isinstance(errors_kw, ast.Constant)
                    and errors_kw.value == "replace"
                ):
                    offenders.append(f"{script.name}:{node.lineno}")
        self.assertEqual(
            offenders,
            [],
            "text=True subprocess calls must pass encoding='utf-8', errors='replace' "
            "(a GBK/cp936 host crashes the reader thread and yields stdout=None)",
        )

    def test_read_flutter_version_survives_non_ascii_utf8_output(self) -> None:
        payload = "Flutter 3.50.0 • channel stable • https://github.com/flutter/flutter.git\n"
        fake = subprocess.CompletedProcess(args=[], returncode=0, stdout=payload, stderr="")
        with mock.patch.object(package.subprocess, "run", return_value=fake) as run_mock:
            self.assertEqual(package.read_flutter_version(Path("flutter")), "3.50.0")
        self.assertEqual(run_mock.call_args.kwargs.get("encoding"), "utf-8")
        self.assertEqual(run_mock.call_args.kwargs.get("errors"), "replace")


if __name__ == "__main__":
    unittest.main()
