"""Zero-dependency unit tests for scripts/package.py and blink.nsi.

Covers packaging version rules, single-latest artifact retention, the pinned NSIS
fetch and script guards, and the full dev auto-install decision matrix using
isolated temporary directories and injectable fakes.
"""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import re
import unittest
from unittest import mock
import zipfile

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
        window_open_polls: int = 0,
        window_open_forever: bool = False,
        exe_running_polls: int = 0,
        exe_running_forever: bool = False,
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
        self._window_open_remaining = window_open_polls
        self._window_open_forever = window_open_forever
        self.window_checks: list[Path] = []
        self._exe_running_remaining = exe_running_polls
        self._exe_running_forever = exe_running_forever
        self.exe_checks: list[Path] = []
        # Whether a blink-dev.exe process was still there each time the installer ran.
        self.exe_running_at_install: list[bool] = []

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

    def _is_window_open(self, exe_path: Path) -> bool:
        self.window_checks.append(exe_path)
        if self._window_open_forever:
            return True
        if self._window_open_remaining > 0:
            self._window_open_remaining -= 1
            return True
        return False

    def _is_exe_running(self, exe_path: Path) -> bool:
        self.exe_checks.append(exe_path)
        if self._exe_running_forever:
            return True
        if self._exe_running_remaining > 0:
            self._exe_running_remaining -= 1
            return True
        return False

    def _request_quit(self, exe_path: Path, identity: str, timeout_s: float) -> package.QuitRequestResult:
        self.quit_calls.append((exe_path, identity, timeout_s))
        self.clock.sleep(0.1)
        return self._quit_result

    def _run_installer(self, installer_path: Path) -> int:
        self.installer_calls.append(installer_path)
        self.exe_running_at_install.append(self._exe_running_forever or self._exe_running_remaining > 0)
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
            is_window_open=self._is_window_open,
            is_exe_running=self._is_exe_running,
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
        # DEC-029: the uninstall key is the app id itself (no Inno "_is1" suffix).
        self.assertEqual(
            package.IDENTITY_SPECS["blink"].uninstall_subkey,
            r"Software\Microsoft\Windows\CurrentVersion\Uninstall\io.github.chialecode.blink",
        )
        self.assertEqual(
            package.IDENTITY_SPECS["blink-dev"].uninstall_key_name,
            "io.github.chialecode.blink-dev",
        )
        self.assertEqual(
            package.IDENTITY_SPECS["blink-dev-test"].uninstall_key_name,
            "io.github.chialecode.blink-dev-test",
        )
        self.assertEqual(package.IDENTITY_SPECS["blink-dev"].mutex_name, "blink-dev-instance")
        self.assertEqual(package.IDENTITY_SPECS["blink-dev"].pipe_name, r"\\.\pipe\blink-dev-control")
        self.assertEqual(package.IDENTITY_SPECS["blink"].icon_file, "blink.ico")
        self.assertEqual(package.IDENTITY_SPECS["blink-dev"].icon_file, "blink-dev.ico")
        self.assertFalse(package.IDENTITY_SPECS["blink"].desktop_on_update)
        self.assertFalse(package.IDENTITY_SPECS["blink-test"].desktop_on_update)
        self.assertTrue(package.IDENTITY_SPECS["blink-dev"].desktop_on_update)
        self.assertTrue(package.IDENTITY_SPECS["blink-dev-test"].desktop_on_update)


class PackagingRetentionAndNsisTests(unittest.TestCase):
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

    def test_missing_flutter_or_makensis_raises_clear_error(self) -> None:
        with self.assertRaises(package.PackageError):
            package.find_flutter_executable({"PATH": ""})
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(package.PackageError, "NSIS 3.13 not found"):
                package.find_makensis_executable({}, cache_dir=Path(tmp) / "nsis-3.13", fetch=False)
            with self.assertRaisesRegex(package.PackageError, "BLINK_MAKENSIS"):
                package.find_makensis_executable({"BLINK_MAKENSIS": str(Path(tmp) / "missing.exe")})
            override = Path(tmp) / "makensis.exe"
            override.write_bytes(b"stub")
            self.assertEqual(package.find_makensis_executable({"BLINK_MAKENSIS": str(override)}), override)

    @staticmethod
    def _nsis_zip(entries: dict[str, bytes]) -> bytes:
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as archive:
            for name, data in entries.items():
                archive.writestr(name, data)
        return buf.getvalue()

    def test_pinned_nsis_fetch_checks_sha256_and_unpacks_atomically(self) -> None:
        good = self._nsis_zip({"nsis-3.13/makensis.exe": b"exe", "nsis-3.13/Stubs/uninst": b"stub"})
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / ".tools" / "nsis-3.13"
            with mock.patch.object(package, "NSIS_ZIP_SHA256", hashlib.sha256(good).hexdigest()):
                buf = io.StringIO()
                with redirect_stdout(buf):
                    exe = package.find_makensis_executable({}, cache_dir=target, download=lambda url: good)
            self.assertEqual(exe, target / "makensis.exe")
            self.assertEqual((target / "Stubs" / "uninst").read_bytes(), b"stub")
            self.assertEqual(sorted(p.name for p in target.parent.iterdir()), ["nsis-3.13"])

            # A cached copy is used as is, without downloading.
            again = package.find_makensis_executable(
                {}, cache_dir=target, download=lambda url: self.fail("must not download")
            )
            self.assertEqual(again, exe)

    def test_pinned_nsis_fetch_rejects_wrong_hash_and_unsafe_entries(self) -> None:
        good = self._nsis_zip({"nsis-3.13/makensis.exe": b"exe"})
        evil = self._nsis_zip({"nsis-3.13/../evil.exe": b"x", "nsis-3.13/makensis.exe": b"exe"})
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / ".tools" / "nsis-3.13"
            buf = io.StringIO()
            with redirect_stdout(buf):
                with self.assertRaisesRegex(package.PackageError, "SHA-256 mismatch"):
                    package.fetch_pinned_nsis(target, download=lambda url: good + b"tampered")
                with mock.patch.object(package, "NSIS_ZIP_SHA256", hashlib.sha256(evil).hexdigest()):
                    with self.assertRaisesRegex(package.PackageError, "Unsafe path"):
                        package.fetch_pinned_nsis(target, download=lambda url: evil)

                def offline(url: str) -> bytes:
                    raise OSError("offline")

                with self.assertRaisesRegex(package.PackageError, "Could not download NSIS"):
                    package.fetch_pinned_nsis(target, download=offline)
            self.assertFalse(target.exists())
            self.assertFalse((Path(tmp) / "evil.exe").exists())
            self.assertEqual(list(target.parent.iterdir()), [])

    def test_remove_files_macro_lists_every_file_then_folders_deepest_first(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp)
            (app / "data" / "flutter_assets").mkdir(parents=True)
            (app / "blink-dev.exe").write_bytes(b"x")
            (app / "data" / "app.so").write_bytes(b"x")
            (app / "data" / "flutter_assets" / "a$b.bin").write_bytes(b"x")
            text = package.render_remove_files_nsh(app)
        lines = text.splitlines()
        self.assertEqual(lines[1], "!macro BLINK_REMOVE_INSTALLED_FILES")
        self.assertEqual(lines[-1], "!macroend")
        self.assertIn('  Delete "$INSTDIR\\blink-dev.exe"', lines)
        self.assertIn('  Delete "$INSTDIR\\data\\flutter_assets\\a$$b.bin"', lines)
        rmdirs = [line for line in lines if line.startswith("  RMDir")]
        self.assertEqual(
            rmdirs,
            ['  RMDir "$INSTDIR\\data\\flutter_assets"', '  RMDir "$INSTDIR\\data"'],
        )
        self.assertNotIn("RMDir /r", text)
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(package.PackageError):
                package.render_remove_files_nsh(Path(tmp))

    def test_silent_installer_uses_nsis_switches(self) -> None:
        fake = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        with mock.patch.object(package.subprocess, "run", return_value=fake) as run_mock:
            rc = package.run_silent_installer(
                Path("C:\\a b\\setup.exe"), extra_args=["/NODESKTOP"], install_dir=Path("C:\\x y\\blink")
            )
        self.assertEqual(rc, 0)
        # /D= stays last and unquoted even with a space; the installer path itself is quoted.
        self.assertEqual(run_mock.call_args.args[0], '"C:\\a b\\setup.exe" /S /NODESKTOP /D=C:\\x y\\blink')
        self.assertEqual(run_mock.call_args.kwargs["timeout"], package.INSTALLER_TIMEOUT_SECONDS)

    def test_silent_installer_reports_a_hang(self) -> None:
        with mock.patch.object(
            package.subprocess, "run", side_effect=subprocess.TimeoutExpired(cmd="setup.exe", timeout=1)
        ):
            self.assertEqual(package.run_silent_installer(Path("setup.exe")), package.INSTALLER_TIMED_OUT)

    def test_nsi_script_pins_nsis_and_keeps_per_user_update_contract(self) -> None:
        nsi_path = package.NSI_PATH
        self.assertTrue(nsi_path.is_file(), "apps/blink_client/windows/packaging/blink.nsi must exist")
        legacy_iss = package.CLIENT_DIR / "windows" / "packaging" / "blink.iss"
        self.assertFalse(legacy_iss.exists(), "the Inno Setup script must be gone (DEC-029)")
        raw = nsi_path.read_bytes()
        self.assertFalse(raw.startswith(b"\xef\xbb\xbf"), "blink.nsi must not have a UTF-8 BOM")
        self.assertNotIn(b"\r\n", raw, "blink.nsi must use LF line endings")

        text = raw.decode("utf-8")
        for needle in (
            '!if "${NSIS_VERSION}" != "v3.13"',
            "RequestExecutionLevel user",
            'InstallDir "$LOCALAPPDATA\\Programs\\${BLINK_IDENTITY}"',
            '!define BLINK_UNINSTALL_KEY "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${BLINK_APP_ID}"',
            'InstallDirRegKey HKCU "${BLINK_UNINSTALL_KEY}" "InstallLocation"',
            '!define BLINK_MUTEX "${BLINK_IDENTITY}-instance"',
            "--quit-for-update",
            '"/UPDATE"',
            '"/RELAUNCH"',
            '"/NODESKTOP"',
            "MUI_FINISHPAGE_SHOWREADME_NOTCHECKED",
            '!insertmacro MUI_LANGUAGE "SimpChinese"',
            "!insertmacro BLINK_REMOVE_INSTALLED_FILES",
            # zlib only: NSIS's LZMA module is CPL-1.0 (docs/research/2026-11-24-nsis-installer.md).
            "SetCompressor /SOLID zlib",
            # Updates skip the folder page; a folder holding another program's uninstaller is refused.
            "!define MUI_PAGE_CUSTOMFUNCTION_PRE BlinkDirectoryPre",
            "!define BLINK_EXIT_FOLDER_TAKEN 7",
            "!define BLINK_EXIT_FILES_NOT_WRITTEN 8",
            "!insertmacro BLINK_REQUIRE BLINK_DESKTOP_ON_UPDATE",
            '!error "BLINK_DESKTOP_ON_UPDATE must be 0 or 1, not ${BLINK_DESKTOP_ON_UPDATE}"',
        ):
            self.assertIn(needle, text)
        # After the mutex is gone, wait (same 30 s) until the installed exe can be opened for writing (#31).
        close_app = text[text.index("Function ${UN}BlinkCloseApp") : text.index("FunctionEnd", text.index("Function ${UN}BlinkCloseApp"))]
        exe_wait = re.search(
            r"\$\{If\} \$\{FileExists\} \"\$1\"\n\s*\$\{Do\}\n"
            r"\s*System::Call 'kernel32::CreateFileW\(w r1, i 0x40000000, i 7, p 0, i 3, i 0x80, p 0\) p\.r0 \?e'\n"
            r"\s*Pop \$3\n\s*\$\{If\} \$0 P<> -1\n\s*System::Call 'kernel32::CloseHandle\(p r0\)'\n\s*\$\{Break\}\n\s*\$\{EndIf\}\n"
            r"\s*\$\{If\} \$3 <> 32\n\s*\$\{Break\}\n\s*\$\{EndIf\}\n"
            r"\s*\$\{If\} \$2 >= \$\{BLINK_QUIT_WAIT_TICKS\}\n[^\n]*\n\s*SetErrorLevel \$\{BLINK_EXIT_QUIT_TIMEOUT\}\n",
            close_app,
        )
        self.assertIsNotNone(exe_wait, "BlinkCloseApp must wait while the installed exe is in use (sharing violation only)")
        # The exe path and the shared tick count are set before the mutex check, so the wait also runs
        # when no mutex was found; the wait itself follows the mutex wait's loop.
        first_check = close_app.index("Call ${UN}BlinkIsRunning")
        self.assertLess(close_app.index('ReadRegStr $1 HKCU "${BLINK_UNINSTALL_KEY}" "InstallLocation"'), first_check)
        self.assertLess(close_app.index("StrCpy $2 0"), first_check)
        mutex_wait_end = re.search(r"\$\{Loop\}\n\s*\$\{EndIf\}\n", close_app)
        self.assertIsNotNone(mutex_wait_end)
        self.assertLess(mutex_wait_end.end(), exe_wait.start() + 1, "the exe wait runs after the mutex wait, outside it")
        self.assertNotIn("FileOpen", close_app, "FileOpen's append mode would create a missing exe")
        # package.INSTALLER_EXITS_BEFORE_FILES: those exits happen before the old uninstaller runs and before any file is written.
        install = text[text.index('Section "Install"') : text.index("SectionEnd", text.index('Section "Install"'))]
        first_change = min(install.index("ExecWait"), install.index("File /r"))
        for early in ("Call BlinkFolderTaken", "SetErrorLevel ${BLINK_EXIT_FOLDER_TAKEN}", "Call BlinkCloseApp"):
            self.assertLess(install.index(early), first_change, f"{early} must come before the install changes anything")
        early_codes = {int(code) for name, code in re.findall(r"(?m)^!define (BLINK_EXIT_\w+) (\d+)", text)
                       if name in {"BLINK_EXIT_BUSY", "BLINK_EXIT_QUIT_TIMEOUT", "BLINK_EXIT_QUIT_FAILED", "BLINK_EXIT_FOLDER_TAKEN"}}
        self.assertEqual(early_codes, set(package.INSTALLER_EXITS_BEFORE_FILES))
        # A file /S could not write stops the install before the uninstaller, the shortcuts and the entry.
        check = re.search(
            r"ClearErrors\n\s*File /r \"\$\{BLINK_SOURCE_DIR\}\\\*\"\n\s*\$\{If\} \$\{Errors\}\n"
            r"\s*MessageBox [^\n]*/SD IDOK\n\s*SetErrorLevel \$\{BLINK_EXIT_FILES_NOT_WRITTEN\}\n\s*Quit\n\s*\$\{EndIf\}\n"
            r"\s*WriteUninstaller ",
            text,
        )
        self.assertIsNotNone(check, "File /r must be followed by the exit-8 check, then WriteUninstaller")
        for later in ('WriteRegStr HKCU "${BLINK_UNINSTALL_KEY}"', 'CreateShortCut "$SMPROGRAMS'):
            self.assertGreater(text.index(later), check.start(), f"{later} must come after the exit-8 check")
        # Start Menu shortcut is created ONLY on first install (or /D= move); over-installs leave it untouched.
        sm_guard = re.search(
            r'\$\{If\} \$FirstInstall == "1"\n\s*CreateShortCut "\$SMPROGRAMS\\\$\{BLINK_PRODUCT_NAME\}\.lnk" "\$INSTDIR\\\$\{BLINK_EXE\}"\n\s*\$\{EndIf\}',
            install,
        )
        self.assertIsNotNone(sm_guard, "Start Menu shortcut must be gated by $FirstInstall == 1")
        self.assertEqual(
            install.count('CreateShortCut "$SMPROGRAMS'),
            1,
            "Start Menu shortcut must only be created in the first-install block",
        )
        # Silent desktop shortcut: created on first install OR when BLINK_DESKTOP_ON_UPDATE == 1, unless /NODESKTOP.
        desktop_guard = re.search(
            r'\$\{If\} \$\{Silent\}\n'
            r'\s*\$\{If\} \$FirstInstall == "1"\n'
            r'\s*\$\{OrIf\} "\$\{BLINK_DESKTOP_ON_UPDATE\}" == "1"\n'
            r'\s*\$\{GetParameters\} \$0\n'
            r'\s*ClearErrors\n'
            r'\s*\$\{GetOptions\} \$0 "/NODESKTOP" \$1\n'
            r'\s*\$\{If\} \$\{Errors\}\n'
            r'\s*Call CreateDesktopShortcut\n',
            install,
        )
        self.assertIsNotNone(
            desktop_guard,
            "Silent desktop shortcut must respect $FirstInstall, BLINK_DESKTOP_ON_UPDATE, and /NODESKTOP",
        )
        # Every exit code the script defines is explained in the install-dev receipt.
        codes = {int(code) for code in re.findall(r"(?m)^!define BLINK_EXIT_\w+ (\d+)", text)}
        self.assertEqual(codes, {3, 4, 5, 7, 8})
        self.assertLessEqual(codes, set(package.INSTALLER_EXIT_MEANINGS))
        self.assertNotRegex(text, r"(?im)^\s*SetCompressor\s.*lzma")
        for value in (
            "DisplayName",
            "DisplayVersion",
            "DisplayIcon",
            "Publisher",
            "InstallLocation",
            "UninstallString",
            "QuietUninstallString",
        ):
            self.assertIn(f'WriteRegStr HKCU "${{BLINK_UNINSTALL_KEY}}" "{value}"', text)
        for value in ("NoModify", "NoRepair", "EstimatedSize"):
            self.assertIn(f'WriteRegDWORD HKCU "${{BLINK_UNINSTALL_KEY}}" "{value}"', text)
        # Never force-kill, never wipe a folder the user may have chosen.
        for forbidden in ("TerminateProcess", "taskkill", "Stop-Process", "RMDir /r", "_is1"):
            self.assertNotIn(forbidden, text)

        if sys.platform != "win32":
            return
        try:
            makensis = package.find_makensis_executable(fetch=False)
        except package.PackageError:
            self.skipTest("NSIS 3.13 not fetched on this host (run scripts/package.py once)")

        for ident, ver in (
            ("blink-dev-test", "0.1.0-dev.202611240000"),
            ("blink-test", "0.1.0"),
        ):
            with self.subTest(identity=ident):
                spec = package.IDENTITY_SPECS[ident]
                with tempfile.TemporaryDirectory() as tmp:
                    td = Path(tmp)
                    app = td / "app"
                    app.mkdir()
                    (app / spec.exe_name).write_bytes(b"MZ")
                    out = td / f"{spec.identity}-setup-{ver}.exe"
                    package.compile_nsis_installer(
                        makensis,
                        nsi_path,
                        spec=spec,
                        version=ver,
                        file_version="0.1.0.0",
                        app_dir=app,
                        icon_path=package.RESOURCES_DIR / spec.icon_file,
                        out_file=out,
                        work_dir=td,
                    )
                    self.assertGreater(out.stat().st_size, 0)

    def test_compile_nsis_passes_desktop_on_update_define_per_identity(self) -> None:
        for ident, expected_flag in (
            ("blink", "-DBLINK_DESKTOP_ON_UPDATE=0"),
            ("blink-test", "-DBLINK_DESKTOP_ON_UPDATE=0"),
            ("blink-dev", "-DBLINK_DESKTOP_ON_UPDATE=1"),
            ("blink-dev-test", "-DBLINK_DESKTOP_ON_UPDATE=1"),
        ):
            with self.subTest(identity=ident):
                spec = package.IDENTITY_SPECS[ident]
                with tempfile.TemporaryDirectory() as tmp:
                    td = Path(tmp)
                    app = td / "app"
                    app.mkdir()
                    (app / spec.exe_name).write_bytes(b"MZ")
                    out = td / f"{spec.identity}-setup.exe"

                    def fake_run(cmd: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
                        out.write_bytes(b"stub-installer")
                        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

                    with mock.patch.object(package.subprocess, "run", side_effect=fake_run) as run_mock:
                        package.compile_nsis_installer(
                            Path("makensis.exe"),
                            package.NSI_PATH,
                            spec=spec,
                            version="0.1.0",
                            file_version="0.1.0.0",
                            app_dir=app,
                            icon_path=package.RESOURCES_DIR / spec.icon_file,
                            out_file=out,
                            work_dir=td,
                        )
                    cmd = run_mock.call_args.args[0]
                    self.assertIn(expected_flag, cmd)

    def test_snapshot_diff_detects_registry_and_start_menu_changes(self) -> None:
        base = {
            "uninstall_keys": {"blink": {"exists": False, "values": {}}},
            "start_menu": {"user_start_menu": []},
            "localappdata": {"localappdata_blink": []},
            "documents": {"documents_blink": []},
            "desktop": [],
        }
        self.assertEqual(package.diff_snapshots(base, dict(base)), {})

        changed = dict(base)
        changed["start_menu"] = {"user_start_menu": ["BLINK Dev Test.lnk"]}
        diff = package.diff_snapshots(base, changed)
        self.assertIn("start_menu", diff)

        docs_changed = dict(base)
        docs_changed["documents"] = {"documents_blink": ["blink-dev-test/"]}
        docs_diff = package.diff_snapshots(base, docs_changed)
        self.assertIn("documents", docs_diff)

    def test_resolve_windows_documents_dir_prefers_known_folder_then_userprofile(self) -> None:
        redirected = Path("mock_redirected") / "Documents"
        self.assertEqual(
            package.resolve_windows_documents_dir(
                {"USERPROFILE": "mock_profile"},
                query_known_folder=lambda: redirected,
            ),
            redirected,
        )
        self.assertEqual(
            package.resolve_windows_documents_dir(
                {"USERPROFILE": "mock_profile"},
                query_known_folder=lambda: None,
            ),
            Path("mock_profile") / "Documents",
        )
        self.assertIsNone(
            package.resolve_windows_documents_dir({}, query_known_folder=lambda: None)
        )
        if sys.platform == "win32":
            live_docs = package._query_known_folder_documents_win32()
            self.assertIsNotNone(live_docs)
            self.assertTrue(str(live_docs).strip())

    def test_capture_host_snapshot_tracks_documents_blink_entries(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            lad = root / "localappdata"
            docs = root / "redirected_docs"
            profile = root / "profile"
            profile_docs = profile / "Documents"
            for d in (lad, docs, profile_docs):
                d.mkdir(parents=True)
            (docs / "blink-dev").mkdir()
            (docs / "other-folder").mkdir()

            fake_env = {
                "LOCALAPPDATA": str(lad),
                "USERPROFILE": str(profile),
            }
            with mock.patch.object(
                package,
                "_snapshot_reg_key",
                return_value={"exists": False, "values": {}},
            ):
                before = package.capture_host_snapshot(
                    fake_env,
                    documents_dir_resolver=lambda _env: docs,
                )
                self.assertEqual(before["documents"]["documents_blink"], ["blink-dev/"])
                self.assertEqual(before["documents"]["userprofile_documents_blink"], [])

                # Simulate a rehearsal leak into Documents.
                (docs / "blink-dev-test").mkdir()
                after = package.capture_host_snapshot(
                    fake_env,
                    documents_dir_resolver=lambda _env: docs,
                )
            diff = package.diff_snapshots(before, after)
            self.assertIn("documents", diff)
            self.assertEqual(
                after["documents"]["documents_blink"],
                ["blink-dev-test/", "blink-dev/"],
            )

    def test_rehearsal_passes_isolated_blink_documents_dir(self) -> None:
        source = (SCRIPTS_DIR / "package.py").read_text(encoding="utf-8")
        self.assertIn('quiet_env["BLINK_DOCUMENTS_DIR"] = str(documents_dir)', source)


class DevAutoInstallDecisionTests(unittest.TestCase):
    OLD = "0.1.0-dev.202611220000"
    NEW = "0.1.0-dev.202611230030"

    def _entry(self) -> package.UninstallEntry:
        return package.UninstallEntry(install_location=Path("mock_programs") / "blink-dev", display_version=self.OLD)

    def _run_case(
        self,
        harness: FakeInstallHarness,
        *,
        channel: str = "blink-dev",
        identity: str | None = None,
        new_version: str = NEW,
        dirty: bool = False,
        env: dict[str, str] | None = None,
        platform_name: str = "win32",
        defer_timeout_s: float = package.WINDOW_DEFER_TIMEOUT_SECONDS,
        branch: str | None = None,
        git_sha: str | None = None,
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
                defer_timeout_s=defer_timeout_s,
                branch=branch,
                git_sha=git_sha,
            )
            self.assertTrue(receipt_path.is_file(), "install-dev.json receipt must be written")
            persisted = json.loads(receipt_path.read_text(encoding="utf-8"))
            self.assertEqual(persisted, receipt)
            return rc, receipt

    def _assert_installed(self, rc: int, receipt: dict[str, object], harness: FakeInstallHarness) -> None:
        self.assertEqual(rc, 0)
        self.assertTrue(receipt["installed"])
        self.assertFalse(receipt["skipped"])
        self.assertIsNone(receipt["reason"])
        self.assertIsNone(receipt["error"])
        self.assertEqual(receipt["newVersion"], self.NEW)
        self.assertEqual(receipt["verifiedRegistryVersion"], self.NEW)
        self.assertEqual(receipt["verifiedExeVersion"], self.NEW)
        self.assertTrue(receipt["relaunched"])
        self.assertTrue(receipt["background"])
        self.assertTrue(receipt["runningInTray"])
        self.assertEqual(len(harness.installer_calls), 1)
        harness.registry.assert_only_dev_key_touched(self)

    def test_receipt_uses_the_shared_camel_case_fields(self) -> None:
        harness = FakeInstallHarness(
            dev_entry=self._entry(), post_install_reg_version=self.NEW, post_install_exe_version=self.NEW
        )
        _, receipt = self._run_case(harness)
        for key in (
            "identity",
            "installed",
            "skipped",
            "reason",
            "error",
            "firstInstall",
            "oldVersion",
            "newVersion",
            "branch",
            "gitSha",
            "installLocation",
            "wasRunning",
            "windowOpen",
            "deferred",
            "deferMs",
            "quitMs",
            "relaunched",
            "background",
            "inJob",
            "elapsedMs",
            "at",
        ):
            self.assertIn(key, receipt)
        for key in receipt:
            self.assertNotIn("_", key, f"receipt field {key!r} is not camelCase")

    def test_not_installed_runs_the_first_install_automatically(self) -> None:
        harness = FakeInstallHarness(dev_entry=None, post_install_reg_version=self.NEW, post_install_exe_version=self.NEW)
        rc, receipt = self._run_case(harness, env={"LOCALAPPDATA": "mock_local"})

        self._assert_installed(rc, receipt, harness)
        self.assertTrue(receipt["firstInstall"])
        self.assertIsNone(receipt["oldVersion"])
        self.assertFalse(receipt["wasRunning"])
        self.assertEqual(harness.quit_calls, [])
        self.assertEqual(harness.direct_calls[0][1], ["--background"])

    def test_pr_branch_install_succeeds_and_records_branch_and_sha(self) -> None:
        harness = FakeInstallHarness(
            dev_entry=self._entry(), post_install_reg_version=self.NEW, post_install_exe_version=self.NEW
        )
        rc, receipt = self._run_case(
            harness,
            branch="fix/47-skip-start-menu-on-dev-reinstall",
            git_sha="abc1234",
            dirty=False,
        )

        self._assert_installed(rc, receipt, harness)
        self.assertEqual(receipt["branch"], "fix/47-skip-start-menu-on-dev-reinstall")
        self.assertEqual(receipt["gitSha"], "abc1234")
        self.assertFalse(receipt["dirty"])

    def test_not_running_installs_verifies_and_launches_background_tray(self) -> None:
        harness = FakeInstallHarness(
            dev_entry=self._entry(), post_install_reg_version=self.NEW, post_install_exe_version=self.NEW
        )
        rc, receipt = self._run_case(harness)

        self._assert_installed(rc, receipt, harness)
        self.assertFalse(receipt["firstInstall"])
        self.assertEqual(receipt["oldVersion"], self.OLD)
        self.assertFalse(receipt["wasRunning"])
        self.assertFalse(receipt["windowOpen"])
        self.assertIsNone(receipt["quitMs"])
        self.assertFalse(receipt["inJob"])
        self.assertEqual(receipt["launchMethod"], "direct")
        self.assertEqual(harness.quit_calls, [])
        self.assertEqual(len(harness.direct_calls), 1)
        self.assertEqual(harness.direct_calls[0][1], ["--background"])

    def test_tray_instance_quits_cleanly_installs_and_relaunches(self) -> None:
        harness = FakeInstallHarness(
            dev_entry=self._entry(),
            running_polls_before_exit=3,
            post_install_reg_version=self.NEW,
            post_install_exe_version=self.NEW,
        )
        rc, receipt = self._run_case(harness, dirty=True)

        self._assert_installed(rc, receipt, harness)
        self.assertTrue(receipt["dirty"])
        self.assertTrue(receipt["wasRunning"])
        self.assertFalse(receipt["windowOpen"])
        self.assertFalse(receipt["deferred"])
        self.assertGreater(int(receipt["quitMs"]), 0)
        self.assertEqual(len(harness.quit_calls), 1)
        self.assertEqual(harness.direct_calls[0][1], ["--background"])

    def test_open_window_defers_the_install_until_it_closes(self) -> None:
        harness = FakeInstallHarness(
            dev_entry=self._entry(),
            stays_running_forever=False,
            running_polls_before_exit=6,
            window_open_polls=3,
            post_install_reg_version=self.NEW,
            post_install_exe_version=self.NEW,
        )
        rc, receipt = self._run_case(harness)

        self._assert_installed(rc, receipt, harness)
        self.assertTrue(receipt["wasRunning"])
        self.assertTrue(receipt["windowOpen"])
        self.assertTrue(receipt["deferred"])
        self.assertGreaterEqual(int(receipt["deferMs"]), 2 * int(package.WINDOW_DEFER_POLL_INTERVAL_SECONDS * 1000))
        self.assertEqual(len(harness.quit_calls), 1, "the tray instance left after the window closed must be asked to quit")
        self.assertTrue(all(exe.name == "blink-dev.exe" for exe in harness.window_checks))

    def test_window_still_open_after_the_limit_skips_without_touching_the_app(self) -> None:
        harness = FakeInstallHarness(dev_entry=self._entry(), stays_running_forever=True, window_open_forever=True)
        rc, receipt = self._run_case(harness, defer_timeout_s=60.0)

        self.assertEqual(rc, 0)
        self.assertFalse(receipt["installed"])
        self.assertTrue(receipt["skipped"])
        self.assertEqual(receipt["reason"], "window_open")
        self.assertTrue(receipt["deferred"])
        self.assertGreaterEqual(int(receipt["deferMs"]), 60_000)
        self.assertIn("--install", str(receipt["guidance"]))
        self.assertEqual(harness.quit_calls, [])
        self.assertEqual(harness.installer_calls, [])
        self.assertEqual(harness.force_kill_calls, 0)

    def test_running_instance_30s_timeout_aborts_without_force_kill(self) -> None:
        harness = FakeInstallHarness(dev_entry=self._entry(), stays_running_forever=True)
        rc, receipt = self._run_case(harness)

        self.assertNotEqual(rc, 0)
        self.assertFalse(receipt["installed"])
        self.assertTrue(receipt["wasRunning"])
        self.assertEqual(receipt["reason"], "quit_timeout")
        self.assertGreaterEqual(int(receipt["quitMs"]), 30_000)
        self.assertEqual(harness.force_kill_calls, 0)
        self.assertEqual(harness.installer_calls, [])
        self.assertEqual(harness.explorer_calls, [])
        self.assertEqual(harness.breakaway_calls, [])
        self.assertEqual(harness.direct_calls, [])
        harness.registry.assert_only_dev_key_touched(self)

    def test_running_instance_busy_aborts_without_force_kill(self) -> None:
        harness = FakeInstallHarness(
            dev_entry=self._entry(),
            running_polls_before_exit=5,
            quit_result=package.QuitRequestResult(ok=False, busy=True, detail='{"ok":false,"reason":"busy"}'),
        )
        rc, receipt = self._run_case(harness)

        self.assertNotEqual(rc, 0)
        self.assertFalse(receipt["installed"])
        self.assertTrue(receipt["wasRunning"])
        self.assertEqual(receipt["reason"], "busy")
        self.assertEqual(harness.force_kill_calls, 0)
        self.assertEqual(harness.installer_calls, [])
        self.assertEqual(harness.direct_calls, [])
        harness.registry.assert_only_dev_key_touched(self)

    def test_process_still_ending_after_the_lock_is_waited_for(self) -> None:
        harness = FakeInstallHarness(
            dev_entry=self._entry(),
            running_polls_before_exit=2,
            exe_running_polls=4,
            post_install_reg_version=self.NEW,
            post_install_exe_version=self.NEW,
        )
        rc, receipt = self._run_case(harness)

        self._assert_installed(rc, receipt, harness)
        self.assertTrue(receipt["wasRunning"])
        self.assertEqual(len(harness.exe_checks), 5)
        self.assertTrue(all(exe.name == "blink-dev.exe" for exe in harness.exe_checks))
        self.assertEqual(harness.exe_running_at_install, [False])

    def test_process_that_outlives_the_lock_aborts_without_force_kill(self) -> None:
        # The lock goes after 20 s; the process then gets only what is left of the same 30 s.
        harness = FakeInstallHarness(dev_entry=self._entry(), running_polls_before_exit=80, exe_running_forever=True)
        rc, receipt = self._run_case(harness)

        self.assertNotEqual(rc, 0)
        self.assertFalse(receipt["installed"])
        self.assertTrue(receipt["wasRunning"])
        self.assertEqual(receipt["reason"], "quit_timeout")
        self.assertGreaterEqual(int(receipt["quitMs"]), 30_000)
        self.assertLess(int(receipt["quitMs"]), 30_500)
        self.assertEqual(harness.force_kill_calls, 0)
        self.assertEqual(harness.installer_calls, [])
        # It is still there: nothing to start again.
        self.assertEqual(harness.direct_calls, [])

    def test_lockless_running_exe_is_waited_for_then_reported(self) -> None:
        harness = FakeInstallHarness(dev_entry=self._entry(), exe_running_forever=True)
        rc, receipt = self._run_case(harness)

        self.assertNotEqual(rc, 0)
        self.assertFalse(receipt["installed"])
        self.assertFalse(receipt["wasRunning"])
        self.assertEqual(receipt["reason"], "process_running")
        self.assertIn("blink-dev.exe", str(receipt["error"]))
        self.assertGreaterEqual(int(receipt["elapsedMs"]), 30_000)
        self.assertGreater(len(harness.exe_checks), 1)
        self.assertEqual(harness.quit_calls, [])
        self.assertEqual(harness.installer_calls, [])
        self.assertEqual(harness.direct_calls, [])
        self.assertEqual(harness.force_kill_calls, 0)

    def test_lockless_exe_that_ends_is_waited_for_then_installed(self) -> None:
        harness = FakeInstallHarness(
            dev_entry=self._entry(),
            exe_running_polls=6,
            post_install_reg_version=self.NEW,
            post_install_exe_version=self.NEW,
        )
        rc, receipt = self._run_case(harness)

        self._assert_installed(rc, receipt, harness)
        self.assertFalse(receipt["wasRunning"])
        self.assertEqual(harness.quit_calls, [])
        self.assertEqual(len(harness.exe_checks), 7)
        self.assertEqual(harness.exe_running_at_install, [False])

    def test_failed_install_starts_the_app_it_closed_again_from_a_whole_folder(self) -> None:
        for label, kwargs, reason in (
            ("stopped before files", {"installer_rc": 5}, "installer_failed_exit_5"),
            ("version", {"post_install_reg_version": self.OLD, "post_install_exe_version": self.OLD}, "version_mismatch"),
        ):
            with self.subTest(label):
                harness = FakeInstallHarness(dev_entry=self._entry(), running_polls_before_exit=2, **kwargs)
                rc, receipt = self._run_case(harness)

                self.assertNotEqual(rc, 0)
                self.assertFalse(receipt["installed"])
                self.assertTrue(receipt["wasRunning"])
                self.assertEqual(receipt["reason"], reason)
                self.assertTrue(receipt["relaunched"])
                self.assertTrue(receipt["background"])
                self.assertEqual(receipt["launchMethod"], "direct")
                self.assertEqual(
                    harness.direct_calls,
                    [(Path("mock_programs") / "blink-dev" / "blink-dev.exe", ["--background"])],
                )
                harness.registry.assert_only_dev_key_touched(self)

    def test_failed_install_leaves_a_partly_written_folder_alone(self) -> None:
        for rc in (8, package.INSTALLER_TIMED_OUT, 2):
            with self.subTest(rc=rc):
                harness = FakeInstallHarness(dev_entry=self._entry(), running_polls_before_exit=2, installer_rc=rc)
                code, receipt = self._run_case(harness)

                self.assertNotEqual(code, 0)
                self.assertTrue(receipt["wasRunning"])
                self.assertEqual(receipt["reason"], f"installer_failed_exit_{rc}")
                self.assertFalse(receipt["relaunched"])
                self.assertIn("--install", str(receipt["guidance"]))
                self.assertEqual(harness.direct_calls, [])
                self.assertEqual(harness.explorer_calls, [])

    def test_installer_failure_returns_nonzero_without_launching(self) -> None:
        harness = FakeInstallHarness(dev_entry=self._entry(), installer_rc=5)
        rc, receipt = self._run_case(harness)

        self.assertNotEqual(rc, 0)
        self.assertFalse(receipt["installed"])
        self.assertEqual(receipt["reason"], "installer_failed_exit_5")
        self.assertIn("5", str(receipt["error"]))
        self.assertEqual(harness.direct_calls, [])
        self.assertEqual(harness.explorer_calls, [])
        harness.registry.assert_only_dev_key_touched(self)

    def test_installer_files_not_written_is_explained(self) -> None:
        harness = FakeInstallHarness(dev_entry=self._entry(), installer_rc=8)
        rc, receipt = self._run_case(harness)

        self.assertNotEqual(rc, 0)
        self.assertFalse(receipt["installed"])
        self.assertEqual(receipt["reason"], "installer_failed_exit_8")
        self.assertIn("could not be written", str(receipt["error"]))
        self.assertEqual(harness.direct_calls, [])
        self.assertEqual(harness.explorer_calls, [])

    def test_missing_uninstall_entry_after_install_fails(self) -> None:
        harness = FakeInstallHarness(dev_entry=None, installer_rc=0, post_install_reg_version=None)
        rc, receipt = self._run_case(harness)

        self.assertNotEqual(rc, 0)
        self.assertFalse(receipt["installed"])
        self.assertTrue(receipt["firstInstall"])
        self.assertEqual(receipt["reason"], "uninstall_entry_missing")
        self.assertEqual(harness.direct_calls, [])

    def test_registry_or_exe_version_mismatch_fails_without_launching(self) -> None:
        for label, reg_v, exe_v in (
            ("registry_mismatch", self.OLD, self.NEW),
            ("exe_mismatch", self.NEW, self.OLD),
        ):
            with self.subTest(label):
                harness = FakeInstallHarness(
                    dev_entry=self._entry(),
                    post_install_reg_version=reg_v,
                    post_install_exe_version=exe_v,
                )
                rc, receipt = self._run_case(harness)

                self.assertNotEqual(rc, 0)
                self.assertFalse(receipt["installed"])
                self.assertEqual(receipt["reason"], "version_mismatch")
                self.assertEqual(receipt["verifiedRegistryVersion"], reg_v)
                self.assertEqual(receipt["verifiedExeVersion"], exe_v)
                self.assertEqual(harness.direct_calls, [])
                self.assertEqual(harness.explorer_calls, [])
                harness.registry.assert_only_dev_key_touched(self)

    def test_job_object_launch_fallback_order_and_in_job_true_receipt(self) -> None:
        def harness(**kwargs: bool) -> FakeInstallHarness:
            return FakeInstallHarness(
                dev_entry=self._entry(),
                post_install_reg_version=self.NEW,
                post_install_exe_version=self.NEW,
                in_job=True,
                **kwargs,
            )

        # 1. Explorer shell succeeds -> detached from job.
        h1 = harness(explorer_succeeds=True)
        rc1, rec1 = self._run_case(h1)
        self.assertEqual(rc1, 0)
        self.assertEqual(rec1["launchMethod"], "explorer_shell")
        self.assertFalse(rec1["inJob"])
        self.assertEqual(h1.explorer_calls[0][1], ["--background"])
        self.assertEqual(h1.breakaway_calls, [])
        self.assertEqual(h1.direct_calls, [])

        # 2. Explorer unavailable -> breakaway succeeds.
        h2 = harness(explorer_succeeds=False, breakaway_succeeds=True)
        rc2, rec2 = self._run_case(h2)
        self.assertEqual(rc2, 0)
        self.assertEqual(rec2["launchMethod"], "breakaway")
        self.assertFalse(rec2["inJob"])
        self.assertEqual(len(h2.explorer_calls), 1)
        self.assertEqual(len(h2.breakaway_calls), 1)
        self.assertEqual(h2.direct_calls, [])

        # 3. Both unavailable -> direct launch records inJob=True + Start Menu guidance.
        h3 = harness(explorer_succeeds=False, breakaway_succeeds=False, direct_succeeds=True)
        rc3, rec3 = self._run_case(h3)
        self.assertEqual(rc3, 0)
        self.assertEqual(rec3["launchMethod"], "direct_in_job")
        self.assertTrue(rec3["inJob"])
        self.assertIn("Start Menu", str(rec3["guidance"]))
        self.assertEqual(h3.direct_calls[0][1], ["--background"])

    def test_env_disable_and_ci_flags_skip_cleanly(self) -> None:
        for env_map, expected_reason in (
            ({"BLINK_DEV_AUTO_INSTALL": "0"}, "disabled_by_env"),
            ({"CI": "true"}, "ci_environment"),
            ({"CI": "1"}, "ci_environment"),
        ):
            with self.subTest(expected_reason):
                harness = FakeInstallHarness(dev_entry=self._entry())
                rc, receipt = self._run_case(harness, env=env_map)
                self.assertEqual(rc, 0)
                self.assertTrue(receipt["skipped"])
                self.assertFalse(receipt["installed"])
                self.assertEqual(receipt["reason"], expected_reason)
                self.assertEqual(harness.registry.read_keys, [])
                self.assertEqual(harness.installer_calls, [])
                self.assertEqual(harness.direct_calls, [])

    def test_non_windows_install_reports_skipped(self) -> None:
        harness = FakeInstallHarness(dev_entry=None)
        rc, receipt = self._run_case(harness, platform_name="linux")
        self.assertEqual(rc, 0)
        self.assertTrue(receipt["skipped"])
        self.assertEqual(receipt["reason"], "non_windows_platform")
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
                self.assertFalse(receipt["installed"])
                self.assertEqual(receipt["reason"], "invalid_channel_for_install")
                self.assertEqual(harness.registry.read_keys, [])
                self.assertEqual(harness.registry.written_keys, [])
                self.assertEqual(harness.installer_calls, [])

    def test_real_dev_uninstall_reader_targets_only_blink_dev_identity(self) -> None:
        with mock.patch.object(package, "read_uninstall_entry_for_identity", return_value=None) as patched:
            result = package.read_dev_uninstall_entry()
        self.assertIsNone(result)
        patched.assert_called_once_with("blink-dev")

    def test_exe_process_probe_matches_the_full_image_path(self) -> None:
        if sys.platform != "win32":
            self.skipTest("Windows only")
        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.GetCurrentProcess.restype = wintypes.HANDLE
        kernel32.QueryFullProcessImageNameW.argtypes = [
            wintypes.HANDLE,
            wintypes.DWORD,
            wintypes.LPWSTR,
            ctypes.POINTER(wintypes.DWORD),
        ]
        size = wintypes.DWORD(32768)
        buf = ctypes.create_unicode_buffer(size.value)
        self.assertTrue(kernel32.QueryFullProcessImageNameW(kernel32.GetCurrentProcess(), 0, buf, ctypes.byref(size)))
        this_image = Path(buf.value)
        self.assertTrue(package.is_exe_process_running(this_image))
        with tempfile.TemporaryDirectory() as tmp:
            self.assertFalse(package.is_exe_process_running(Path(tmp) / this_image.name))

    def test_window_probe_ignores_hidden_windows_of_other_programs(self) -> None:
        if sys.platform != "win32":
            self.skipTest("Windows-only window probe")
        self.assertFalse(package.is_app_window_open(Path("mock_programs") / "blink-dev" / "blink-dev.exe"))


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
            self.assertTrue(receipt["skipped"])
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

    def test_read_git_state_reports_branch_and_detached_head(self) -> None:
        with mock.patch.object(
            package.subprocess,
            "run",
            side_effect=[
                subprocess.CompletedProcess(["git"], 0, stdout="1234abc\n", stderr=""),
                subprocess.CompletedProcess(["git"], 0, stdout="", stderr=""),
                subprocess.CompletedProcess(["git"], 0, stdout="fix/47-skip-start-menu\n", stderr=""),
            ],
        ):
            state = package.read_git_state()
        self.assertEqual(state, package.GitState(sha="1234abc", dirty=False, branch="fix/47-skip-start-menu"))

        with mock.patch.object(
            package.subprocess,
            "run",
            side_effect=[
                subprocess.CompletedProcess(["git"], 0, stdout="1234abc\n", stderr=""),
                subprocess.CompletedProcess(["git"], 0, stdout=" M scripts/package.py\n", stderr=""),
                subprocess.CompletedProcess(["git"], 1, stdout="", stderr=""),
            ],
        ):
            detached = package.read_git_state()
        self.assertEqual(detached, package.GitState(sha="1234abc", dirty=True, branch=None))


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
