"""Windows desktop packaging, dev auto-install, and rehearsal runner for BLINK.

Standard-library only (Python 3.12+). Supports:
  - Packaging Windows per-user installers via Flutter + NSIS 3.13 (DEC-029):
      python scripts/package.py [--channel blink-dev|blink] [--version <ver>]
  - Dev channel local auto-install and update to the system tray (engineering.md 2.2):
      python scripts/package.py --install
  - Quiet isolated test-identity upgrade/uninstall rehearsal (AC-11 / M2-K08):
      python scripts/package.py --rehearsal
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable, Mapping, Protocol
import urllib.request
import uuid
import zipfile


REPO_ROOT = Path(__file__).resolve().parents[1]
CLIENT_DIR = REPO_ROOT / "apps" / "blink_client"
NSI_PATH = CLIENT_DIR / "windows" / "packaging" / "blink.nsi"
RESOURCES_DIR = CLIENT_DIR / "windows" / "runner" / "resources"
DIST_ROOT = REPO_ROOT / "dist"
ARTIFACTS_PACKAGE_DIR = REPO_ROOT / "artifacts" / "package"

# The pinned NSIS build (DEC-029). package.py fetches this exact archive once into
# the ignored .tools/ folder and checks its SHA-256 before using it; blink.nsi also
# refuses any other makensis version. BLINK_MAKENSIS may name another makensis.exe
# of the same version (an offline copy, for example).
NSIS_VERSION = "3.13"
NSIS_ZIP_URL = "https://downloads.sourceforge.net/project/nsis/NSIS%203/3.13/nsis-3.13.zip"
NSIS_ZIP_SHA256 = "ba63dffc4410ee89193e1cb5a41989991bd77c61068da17e3156d136b7b0b3d8"
NSIS_CACHE_DIR = REPO_ROOT / ".tools" / f"nsis-{NSIS_VERSION}"
NSIS_DOWNLOAD_TIMEOUT_SECONDS = 120.0

UNINSTALL_REG_ROOT = r"Software\Microsoft\Windows\CurrentVersion\Uninstall"
QUIT_WAIT_TIMEOUT_SECONDS = 30.0
QUIT_POLL_INTERVAL_SECONDS = 0.25
# While the BLINK Dev window is open the install waits for it to close (or hide
# to the tray), at most this long, then skips and says so (#20).
WINDOW_DEFER_TIMEOUT_SECONDS = 600.0
# A silent install waits up to 30 s for BLINK to quit and then copies files; this only stops a hang.
INSTALLER_TIMEOUT_SECONDS = 600.0
# run_silent_installer's result when the installer did not finish within INSTALLER_TIMEOUT_SECONDS.
INSTALLER_TIMED_OUT = -1
# blink.nsi's BLINK_EXIT_* codes, explained in the install-dev receipt (test_package checks every code is here).
INSTALLER_EXIT_MEANINGS = {
    INSTALLER_TIMED_OUT: f"the installer did not finish within {int(INSTALLER_TIMEOUT_SECONDS // 60)} minutes",
    3: "BLINK reported busy and kept running",
    4: "BLINK did not exit, or its exe stayed in use, within 30 s",
    5: "BLINK is running, but asking it to quit failed",
    7: "the install folder holds another program's Uninstall.exe",
    8: "some files could not be written (held open or no write permission); the uninstall entry was left as it was, run it again",
}
# Installer exits that stop before any file is touched (blink.nsi): BLINK Dev can be started again from its folder.
INSTALLER_EXITS_BEFORE_FILES = frozenset({3, 4, 5, 7})
WINDOW_DEFER_POLL_INTERVAL_SECONDS = 2.0
REHEARSAL_QUIT_TIMEOUT_SECONDS = 5.0
TRAY_VERIFY_TIMEOUT_SECONDS = 5.0

CREATE_NO_WINDOW = 0x08000000
DETACHED_PROCESS = 0x00000008
CREATE_NEW_PROCESS_GROUP = 0x00000200
CREATE_BREAKAWAY_FROM_JOB = 0x01000000

FORMAL_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
DEV_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")
LEADING_SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)")
FLUTTER_VERSION_RE = re.compile(r"Flutter\s+(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)")


class PackageError(RuntimeError):
    """Raised on packaging, verification, or configuration errors."""


@dataclass(frozen=True)
class IdentitySpec:
    identity: str
    channel: str
    app_id: str
    product_name: str
    file_description: str
    icon_file: str
    desktop_on_update: bool = False

    @property
    def exe_name(self) -> str:
        return f"{self.identity}.exe"

    @property
    def mutex_name(self) -> str:
        return f"{self.identity}-instance"

    @property
    def pipe_name(self) -> str:
        return rf"\\.\pipe\{self.identity}-control"

    @property
    def uninstall_key_name(self) -> str:
        return self.app_id

    @property
    def uninstall_subkey(self) -> str:
        return rf"{UNINSTALL_REG_ROOT}\{self.uninstall_key_name}"


IDENTITY_SPECS: dict[str, IdentitySpec] = {
    "blink": IdentitySpec(
        identity="blink",
        channel="blink",
        app_id="io.github.chialecode.blink",
        product_name="BLINK",
        file_description="BLINK Desktop Client",
        icon_file="blink.ico",
        desktop_on_update=False,
    ),
    "blink-dev": IdentitySpec(
        identity="blink-dev",
        channel="blink-dev",
        app_id="io.github.chialecode.blink-dev",
        product_name="BLINK Dev",
        file_description="BLINK Desktop Client (Dev)",
        icon_file="blink-dev.ico",
        desktop_on_update=True,
    ),
    "blink-test": IdentitySpec(
        identity="blink-test",
        channel="blink",
        app_id="io.github.chialecode.blink-test",
        product_name="BLINK Test",
        file_description="BLINK Desktop Client (Test)",
        icon_file="blink.ico",
        desktop_on_update=False,
    ),
    "blink-dev-test": IdentitySpec(
        identity="blink-dev-test",
        channel="blink-dev",
        app_id="io.github.chialecode.blink-dev-test",
        product_name="BLINK Dev Test",
        file_description="BLINK Desktop Client (Dev Test)",
        icon_file="blink-dev.ico",
        desktop_on_update=True,
    ),
}


@dataclass(frozen=True)
class VersionInfo:
    version: str
    base_version: str
    file_version_comma: str
    file_version_str: str
    dirty: bool


@dataclass(frozen=True)
class GitState:
    sha: str
    dirty: bool
    branch: str | None = None


@dataclass(frozen=True)
class PackageResult:
    spec: IdentitySpec
    version_info: VersionInfo
    git_state: GitState
    flutter_version: str
    output_dir: Path
    installer_path: Path
    sha256: str
    size_bytes: int
    built_at_utc: str
    build_info: dict[str, Any]


@dataclass(frozen=True)
class UninstallEntry:
    install_location: Path
    display_version: str
    uninstall_string: str = ""
    quiet_uninstall_string: str = ""


@dataclass(frozen=True)
class QuitRequestResult:
    ok: bool
    busy: bool = False
    detail: str = ""


class Clock(Protocol):
    def monotonic(self) -> float: ...
    def sleep(self, seconds: float) -> None: ...
    def utc_now(self) -> datetime: ...


class SystemClock:
    def monotonic(self) -> float:
        return time.monotonic()

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)

    def utc_now(self) -> datetime:
        return datetime.now(timezone.utc)


@dataclass
class DevInstallDeps:
    """Injectable dependencies for engineering.md 2.2 dev auto-install."""

    read_dev_uninstall_entry: Callable[[], UninstallEntry | None]
    is_running: Callable[[str], bool]
    request_quit_for_update: Callable[[Path, str, float], QuitRequestResult]
    run_installer: Callable[[Path], int]
    read_exe_product_version: Callable[[Path], str]
    is_in_job_object: Callable[[], bool]
    launch_via_explorer_shell: Callable[[Path, list[str]], bool]
    launch_with_breakaway: Callable[[Path, list[str]], bool]
    launch_direct: Callable[[Path, list[str]], bool]
    verify_running_in_tray: Callable[[str, float], bool]
    clock: Clock
    # True while a visible top-level window of the installed blink-dev.exe is open.
    is_window_open: Callable[[Path], bool] = lambda _exe: False
    # True while a process of the installed blink-dev.exe has not ended (its files stay locked until then).
    is_exe_running: Callable[[Path], bool] = lambda _exe: False


def utc_iso(dt: datetime | None = None) -> str:
    current = dt or datetime.now(timezone.utc)
    return current.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def atomic_write_bytes(path: Path, data: bytes) -> None:
    """Atomically write bytes via same-directory temp file, fsync, and os.replace."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.parent / f".{path.name}.{os.getpid()}.{uuid.uuid4().hex[:8]}.blink-tmp"
    try:
        with tmp_path.open("wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, path)
    except Exception:
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def atomic_write_text(path: Path, text: str) -> None:
    normalized = text.replace("\r\n", "\n")
    atomic_write_bytes(path, normalized.encode("utf-8"))


def atomic_write_json(path: Path, payload: Mapping[str, Any]) -> None:
    rendered = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
    atomic_write_text(path, rendered)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def atomic_replace_directory(staging_dir: Path, dest_dir: Path) -> None:
    """Atomically replace dest_dir with staging_dir so only the latest artifact set remains."""
    dest_dir.parent.mkdir(parents=True, exist_ok=True)
    suffix = f"{os.getpid()}-{uuid.uuid4().hex[:8]}"
    sibling_new = dest_dir.parent / f".{dest_dir.name}.staging-{suffix}"
    sibling_old = dest_dir.parent / f".{dest_dir.name}.old-{suffix}"

    if sibling_new.exists():
        shutil.rmtree(sibling_new)
    shutil.copytree(staging_dir, sibling_new)

    moved_old = False
    try:
        if dest_dir.exists():
            os.replace(dest_dir, sibling_old)
            moved_old = True
        os.replace(sibling_new, dest_dir)
    except Exception:
        if moved_old and sibling_old.exists() and not dest_dir.exists():
            try:
                os.replace(sibling_old, dest_dir)
            except OSError:
                pass
        if sibling_new.exists():
            shutil.rmtree(sibling_new, ignore_errors=True)
        raise
    else:
        if moved_old and sibling_old.exists():
            shutil.rmtree(sibling_old, ignore_errors=True)


def compute_version(
    channel: str,
    explicit_version: str | None,
    *,
    dirty: bool,
    now_utc: datetime | None = None,
) -> VersionInfo:
    """Compute product and numeric file versions for blink / blink-dev."""
    if channel not in ("blink", "blink-dev"):
        raise PackageError(f"Unsupported channel: {channel!r} (expected 'blink' or 'blink-dev')")

    raw_ver = explicit_version.strip() if explicit_version is not None else ""
    if channel == "blink":
        if not raw_ver:
            raise PackageError("--version is required for formal channel 'blink' (e.g. --version 0.1.0)")
        if not FORMAL_VERSION_RE.fullmatch(raw_ver):
            raise PackageError(
                f"Invalid formal version {raw_ver!r}: expected MAJOR.MINOR.PATCH (e.g. 0.1.0)"
            )
        base_version = raw_ver
    else:
        if raw_ver:
            if not DEV_VERSION_RE.fullmatch(raw_ver):
                raise PackageError(
                    f"Invalid dev version {raw_ver!r}: expected MAJOR.MINOR.PATCH[-prerelease]"
                )
            base_version = raw_ver
        else:
            ts = (now_utc or datetime.now(timezone.utc)).astimezone(timezone.utc).strftime("%Y%m%d%H%M")
            base_version = f"0.1.0-dev.{ts}"

    match = LEADING_SEMVER_RE.match(base_version)
    if not match:
        raise PackageError(f"Cannot extract numeric FileVersion from {base_version!r}")
    major, minor, patch = match.groups()

    full_version = f"{base_version}+dirty" if dirty else base_version
    return VersionInfo(
        version=full_version,
        base_version=base_version,
        file_version_comma=f"{major},{minor},{patch},0",
        file_version_str=f"{major}.{minor}.{patch}.0",
        dirty=dirty,
    )


def build_cmake_env(
    base_env: Mapping[str, str],
    spec: IdentitySpec,
    version_info: VersionInfo,
) -> dict[str, str]:
    """Construct environment variables consumed by windows/runner/CMakeLists.txt."""
    env = dict(base_env)
    env.update(
        {
            "BLINK_PRODUCT_VERSION": version_info.version,
            "BLINK_FILE_VERSION": version_info.file_version_comma,
            "BLINK_FILE_VERSION_STR": version_info.file_version_str,
            "BLINK_PRODUCT_NAME": spec.product_name,
            "BLINK_FILE_DESCRIPTION": spec.file_description,
            "BLINK_INTERNAL_NAME": spec.identity,
            "BLINK_ORIGINAL_FILENAME": spec.exe_name,
            "BLINK_ICON_FILE": spec.icon_file,
        }
    )
    return env


def _subprocess_flags() -> int:
    return CREATE_NO_WINDOW if sys.platform == "win32" else 0


def find_flutter_executable(env: Mapping[str, str] | None = None) -> Path:
    effective_env = env if env is not None else os.environ
    for name in ("flutter.bat", "flutter") if sys.platform == "win32" else ("flutter",):
        found = shutil.which(name, path=effective_env.get("PATH"))
        if found:
            return Path(found)

    local_app_data = effective_env.get("LOCALAPPDATA", "").strip()
    if local_app_data:
        candidate = Path(local_app_data) / "Programs" / "flutter" / "bin" / "flutter.bat"
        if candidate.is_file():
            return candidate

    raise PackageError(
        "Flutter executable not found in PATH or %LOCALAPPDATA%\\Programs\\flutter\\bin\\flutter.bat"
    )


def find_makensis_executable(
    env: Mapping[str, str] | None = None,
    *,
    cache_dir: Path | None = None,
    fetch: bool = True,
    download: Callable[[str], bytes] | None = None,
) -> Path:
    """Return makensis.exe of the pinned NSIS build, fetching the verified archive once if missing.

    BLINK_MAKENSIS overrides the location; blink.nsi itself rejects any version but NSIS_VERSION.
    """
    effective_env = env if env is not None else os.environ
    override = effective_env.get("BLINK_MAKENSIS", "").strip()
    if override:
        candidate = Path(override)
        if not candidate.is_file():
            raise PackageError(f"BLINK_MAKENSIS does not name a file: {override}")
        return candidate

    target = cache_dir if cache_dir is not None else NSIS_CACHE_DIR
    makensis = target / "makensis.exe"
    if makensis.is_file():
        return makensis
    if not fetch:
        raise PackageError(
            f"NSIS {NSIS_VERSION} not found at .tools/{target.name}/makensis.exe; "
            "run scripts/package.py once to fetch it, or set BLINK_MAKENSIS"
        )
    fetch_pinned_nsis(target, download=download)
    if not makensis.is_file():
        raise PackageError(f"NSIS {NSIS_VERSION} archive did not contain makensis.exe")
    return makensis


def _download_bytes(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "blink-package-script"})
    with urllib.request.urlopen(request, timeout=NSIS_DOWNLOAD_TIMEOUT_SECONDS) as response:
        return response.read()


def fetch_pinned_nsis(target: Path, *, download: Callable[[str], bytes] | None = None) -> None:
    """Download the pinned NSIS zip, check its SHA-256 and unpack it into `target` atomically."""
    print(f"[package] Fetching NSIS {NSIS_VERSION} (pinned SHA-256) into .tools/{target.name}...")
    try:
        data = (download or _download_bytes)(NSIS_ZIP_URL)
    except OSError as exc:
        raise PackageError(
            f"Could not download NSIS {NSIS_VERSION} from {NSIS_ZIP_URL}: {exc}. "
            "Download it by hand and set BLINK_MAKENSIS, or retry when online."
        ) from exc
    digest = hashlib.sha256(data).hexdigest()
    if digest != NSIS_ZIP_SHA256:
        raise PackageError(
            f"NSIS {NSIS_VERSION} archive SHA-256 mismatch: expected {NSIS_ZIP_SHA256}, got {digest}; not using it"
        )

    root = f"nsis-{NSIS_VERSION}/"
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = target.parent / f".{target.name}.staging-{uuid.uuid4().hex}"
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for info in archive.infolist():
                name = info.filename.replace("\\", "/")
                if not name.startswith(root):
                    raise PackageError(f"Unexpected entry in NSIS archive: {info.filename!r}")
                rel = PurePosixPath(name[len(root):])
                if not rel.parts:
                    continue
                if rel.is_absolute() or any(part == ".." or ":" in part for part in rel.parts):
                    raise PackageError(f"Unsafe path in NSIS archive: {info.filename!r}")
                dest = staging.joinpath(*rel.parts)
                if info.is_dir():
                    dest.mkdir(parents=True, exist_ok=True)
                    continue
                dest.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(info) as src, open(dest, "wb") as dst:
                    shutil.copyfileobj(src, dst)
        if target.exists():
            shutil.rmtree(target)
        os.replace(staging, target)
    finally:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)


def nsis_escape(text: str) -> str:
    """Escape text for an NSIS double-quoted string ($ starts a variable)."""
    return text.replace("$", "$$")


def render_remove_files_nsh(app_dir: Path) -> str:
    """Return the BLINK_REMOVE_INSTALLED_FILES macro: every staged file, then its folders deepest first."""
    files: list[PurePosixPath] = []
    folders: set[PurePosixPath] = set()
    for path in app_dir.rglob("*"):
        if not path.is_file():
            continue
        rel = PurePosixPath(path.relative_to(app_dir).as_posix())
        files.append(rel)
        for parent in rel.parents:
            if parent != PurePosixPath("."):
                folders.add(parent)
    if not files:
        raise PackageError(f"No files to install in {app_dir}")

    def win(rel: PurePosixPath) -> str:
        return nsis_escape(str(rel).replace("/", "\\"))

    lines = [
        "; Generated by scripts/package.py: the files this version installs. Do not edit.",
        "!macro BLINK_REMOVE_INSTALLED_FILES",
    ]
    lines += [f'  Delete "$INSTDIR\\{win(rel)}"' for rel in sorted(files, key=str)]
    lines += [
        f'  RMDir "$INSTDIR\\{win(rel)}"'
        for rel in sorted(folders, key=lambda d: (-len(d.parts), str(d)))
    ]
    lines.append("!macroend")
    return "\n".join(lines) + "\n"


def read_git_state(repo_root: Path = REPO_ROOT) -> GitState:
    sha_proc = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=_subprocess_flags(),
    )
    if sha_proc.returncode != 0:
        raise PackageError(f"Failed to read git HEAD: {sha_proc.stderr.strip()}")
    sha = sha_proc.stdout.strip()

    status_proc = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=_subprocess_flags(),
    )
    if status_proc.returncode != 0:
        raise PackageError(f"Failed to read git status: {status_proc.stderr.strip()}")
    dirty = bool(status_proc.stdout.strip())

    branch_proc = subprocess.run(
        ["git", "symbolic-ref", "--short", "-q", "HEAD"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=_subprocess_flags(),
    )
    branch = branch_proc.stdout.strip() if branch_proc.returncode == 0 and branch_proc.stdout.strip() else None
    return GitState(sha=sha, dirty=dirty, branch=branch)


def read_flutter_version(flutter_exe: Path, env: Mapping[str, str] | None = None) -> str:
    proc = subprocess.run(
        [str(flutter_exe), "--version", "--suppress-analytics"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=dict(env) if env is not None else None,
        creationflags=_subprocess_flags(),
    )
    if proc.returncode != 0:
        raise PackageError(f"Failed to query Flutter version: {proc.stderr.strip() or proc.stdout.strip()}")
    match = FLUTTER_VERSION_RE.search(proc.stdout)
    if match:
        return match.group(1)
    flutter_ver_file = REPO_ROOT / ".flutter-version"
    if flutter_ver_file.is_file():
        return flutter_ver_file.read_text(encoding="utf-8").strip()
    raise PackageError("Unable to parse Flutter version from `flutter --version`")


def invalidate_windows_cmake_version_cache(client_dir: Path = CLIENT_DIR) -> None:
    """Clear generated CMake/resource cache artifacts under build/windows/ without dirtying tracked files."""
    win_build_dir = client_dir / "build" / "windows"
    if not win_build_dir.is_dir():
        return

    for target_name in ("CMakeCache.txt", "blink_version.h", "Runner.res", "blink_client.exe"):
        for match in win_build_dir.rglob(target_name):
            if match.is_file():
                try:
                    match.unlink()
                except OSError:
                    pass


def read_exe_product_version(exe_path: Path) -> str:
    """Read StringFileInfo ProductVersion from a Windows PE executable using version.dll."""
    if sys.platform != "win32":
        raise PackageError("Reading Windows PE ProductVersion requires Windows")
    if not exe_path.is_file():
        raise PackageError(f"Executable not found: {exe_path}")

    import ctypes
    from ctypes import wintypes

    version_dll = ctypes.WinDLL("version", use_last_error=True)

    get_size = version_dll.GetFileVersionInfoSizeW
    get_size.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
    get_size.restype = wintypes.DWORD

    get_info = version_dll.GetFileVersionInfoW
    get_info.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID]
    get_info.restype = wintypes.BOOL

    query_val = version_dll.VerQueryValueW
    query_val.argtypes = [
        wintypes.LPCVOID,
        wintypes.LPCWSTR,
        ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(wintypes.UINT),
    ]
    query_val.restype = wintypes.BOOL

    dummy = wintypes.DWORD(0)
    size = get_size(str(exe_path), ctypes.byref(dummy))
    if not size:
        raise PackageError(
            f"GetFileVersionInfoSizeW failed for {exe_path.name} (err={ctypes.get_last_error()})"
        )

    buf = ctypes.create_string_buffer(size)
    if not get_info(str(exe_path), 0, size, buf):
        raise PackageError(
            f"GetFileVersionInfoW failed for {exe_path.name} (err={ctypes.get_last_error()})"
        )

    ptr = ctypes.c_void_p()
    length = wintypes.UINT(0)
    translations: list[tuple[int, int]] = []
    if query_val(buf, r"\VarFileInfo\Translation", ctypes.byref(ptr), ctypes.byref(length)) and length.value >= 4:
        count = length.value // 4
        arr = (wintypes.WORD * (count * 2)).from_address(ptr.value)
        for idx in range(count):
            translations.append((int(arr[2 * idx]), int(arr[2 * idx + 1])))

    for fallback in ((0x0409, 0x04B0), (0x0409, 0x04E4), (0x0000, 0x04B0)):
        if fallback not in translations:
            translations.append(fallback)

    for lang, codepage in translations:
        subblock = rf"\StringFileInfo\{lang:04x}{codepage:04x}\ProductVersion"
        vptr = ctypes.c_void_p()
        vlen = wintypes.UINT(0)
        if query_val(buf, subblock, ctypes.byref(vptr), ctypes.byref(vlen)) and vlen.value > 0:
            value = ctypes.wstring_at(vptr.value).rstrip("\x00").strip()
            if value:
                return value

    raise PackageError(f"ProductVersion string resource not found in {exe_path.name}")


def is_instance_running(identity: str) -> bool:
    """Check whether the named single-instance mutex `<identity>-instance` currently exists."""
    if sys.platform != "win32":
        return False

    import ctypes
    from ctypes import wintypes

    synchronize = 0x00100000
    error_access_denied = 5

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    open_mutex = kernel32.OpenMutexW
    open_mutex.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR]
    open_mutex.restype = wintypes.HANDLE

    close_handle = kernel32.CloseHandle
    close_handle.argtypes = [wintypes.HANDLE]
    close_handle.restype = wintypes.BOOL

    handle = open_mutex(synchronize, False, f"{identity}-instance")
    if handle:
        close_handle(handle)
        return True
    return ctypes.get_last_error() == error_access_denied


def is_exe_process_running(exe_path: Path) -> bool:
    """True while a process whose image is exe_path has not ended.

    The single-instance mutex is released before the process has ended and let go of its image
    files, so the dev install waits on this too before it runs the installer (#31).
    """
    if sys.platform != "win32":
        return False

    import ctypes
    from ctypes import wintypes

    synchronize = 0x00100000
    process_query_limited_information = 0x1000
    wait_timeout = 0x00000102

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.K32EnumProcesses.argtypes = [ctypes.POINTER(wintypes.DWORD), wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    kernel32.K32EnumProcesses.restype = wintypes.BOOL
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.QueryFullProcessImageNameW.argtypes = [
        wintypes.HANDLE,
        wintypes.DWORD,
        wintypes.LPWSTR,
        ctypes.POINTER(wintypes.DWORD),
    ]
    kernel32.QueryFullProcessImageNameW.restype = wintypes.BOOL
    kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel32.WaitForSingleObject.restype = wintypes.DWORD
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL

    size = wintypes.DWORD(0)
    buf = ctypes.create_unicode_buffer(32768)
    count = 1024
    while True:
        pids = (wintypes.DWORD * count)()
        needed = wintypes.DWORD(0)
        if not kernel32.K32EnumProcesses(pids, ctypes.sizeof(pids), ctypes.byref(needed)):
            raise OSError(ctypes.get_last_error(), "EnumProcesses failed")
        if needed.value < ctypes.sizeof(pids):
            break
        count *= 2

    # The kernel reports the image path with links and junctions resolved.
    wanted = os.path.normcase(os.path.realpath(str(exe_path)))
    for pid in pids[: needed.value // ctypes.sizeof(wintypes.DWORD)]:
        if not pid:
            continue
        handle = kernel32.OpenProcess(synchronize | process_query_limited_information, False, pid)
        if not handle:
            continue
        try:
            size.value = len(buf)
            if not kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
                continue
            # A process that has ended but is still held open by someone is signalled and no longer maps its files.
            if os.path.normcase(buf.value) == wanted and kernel32.WaitForSingleObject(handle, 0) == wait_timeout:
                return True
        finally:
            kernel32.CloseHandle(handle)
    return False


def send_pipe_command(identity: str, cmd: str, *, timeout_s: float = 5.0) -> dict[str, Any]:
    """Send a single-line JSON command over `\\\\.\\pipe\\<identity>-control` and parse JSON reply."""
    if sys.platform != "win32":
        raise PackageError("Named pipe IPC requires Windows")

    import ctypes
    from ctypes import wintypes

    generic_read = 0x80000000
    generic_write = 0x40000000
    open_existing = 3
    file_flag_overlapped = 0x40000000
    invalid_handle = ctypes.c_void_p(-1).value
    error_pipe_busy = 231
    error_io_pending = 997
    error_broken_pipe = 109
    error_more_data = 234
    wait_object_0 = 0
    max_reply_bytes = 65536

    class _Overlapped(ctypes.Structure):
        _fields_ = [
            ("Internal", ctypes.c_size_t),
            ("InternalHigh", ctypes.c_size_t),
            ("Offset", wintypes.DWORD),
            ("OffsetHigh", wintypes.DWORD),
            ("hEvent", wintypes.HANDLE),
        ]

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    create_file = kernel32.CreateFileW
    create_file.argtypes = [
        wintypes.LPCWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.LPVOID,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.HANDLE,
    ]
    create_file.restype = wintypes.HANDLE

    wait_pipe = kernel32.WaitNamedPipeW
    wait_pipe.argtypes = [wintypes.LPCWSTR, wintypes.DWORD]
    wait_pipe.restype = wintypes.BOOL

    create_event = kernel32.CreateEventW
    create_event.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR]
    create_event.restype = wintypes.HANDLE

    reset_event = kernel32.ResetEvent
    reset_event.argtypes = [wintypes.HANDLE]
    reset_event.restype = wintypes.BOOL

    write_file = kernel32.WriteFile
    write_file.argtypes = [
        wintypes.HANDLE,
        wintypes.LPCVOID,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
        ctypes.POINTER(_Overlapped),
    ]
    write_file.restype = wintypes.BOOL

    read_file = kernel32.ReadFile
    read_file.argtypes = [
        wintypes.HANDLE,
        wintypes.LPVOID,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
        ctypes.POINTER(_Overlapped),
    ]
    read_file.restype = wintypes.BOOL

    wait_single = kernel32.WaitForSingleObject
    wait_single.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    wait_single.restype = wintypes.DWORD

    get_overlapped = kernel32.GetOverlappedResult
    get_overlapped.argtypes = [
        wintypes.HANDLE,
        ctypes.POINTER(_Overlapped),
        ctypes.POINTER(wintypes.DWORD),
        wintypes.BOOL,
    ]
    get_overlapped.restype = wintypes.BOOL

    cancel_io_ex = kernel32.CancelIoEx
    cancel_io_ex.argtypes = [wintypes.HANDLE, ctypes.POINTER(_Overlapped)]
    cancel_io_ex.restype = wintypes.BOOL

    close_handle = kernel32.CloseHandle
    close_handle.argtypes = [wintypes.HANDLE]
    close_handle.restype = wintypes.BOOL

    pipe_name = rf"\\.\pipe\{identity}-control"
    deadline = time.monotonic() + timeout_s
    handle = invalid_handle

    while True:
        handle = create_file(
            pipe_name,
            generic_read | generic_write,
            0,
            None,
            open_existing,
            file_flag_overlapped,
            None,
        )
        if handle != invalid_handle:
            break
        err = ctypes.get_last_error()
        remaining = deadline - time.monotonic()
        if err == error_pipe_busy and remaining > 0:
            wait_pipe(pipe_name, max(50, int(min(remaining, 0.5) * 1000)))
            continue
        raise OSError(err, f"Cannot open control pipe {pipe_name} (err={err})")

    event = create_event(None, True, False, None)
    if not event:
        close_handle(handle)
        raise OSError(ctypes.get_last_error(), "CreateEventW failed")

    try:
        payload = (json.dumps({"cmd": cmd}, separators=(",", ":")) + "\n").encode("utf-8")
        ov = _Overlapped()
        ov.hEvent = event
        written = wintypes.DWORD(0)

        if not write_file(handle, payload, len(payload), ctypes.byref(written), ctypes.byref(ov)):
            err = ctypes.get_last_error()
            if err != error_io_pending:
                raise OSError(err, f"WriteFile failed on {pipe_name} (err={err})")
            rem_ms = max(1, int((deadline - time.monotonic()) * 1000))
            wait_res = wait_single(event, rem_ms)
            if wait_res != wait_object_0:
                cancel_io_ex(handle, ctypes.byref(ov))
                get_overlapped(handle, ctypes.byref(ov), ctypes.byref(written), True)
                raise TimeoutError(f"Timed out writing to {pipe_name}")
            if not get_overlapped(handle, ctypes.byref(ov), ctypes.byref(written), False):
                raise OSError(ctypes.get_last_error(), f"GetOverlappedResult(write) failed on {pipe_name}")

        received = bytearray()
        chunk_buf = ctypes.create_string_buffer(4096)
        while len(received) < max_reply_bytes:
            rem_s = deadline - time.monotonic()
            if rem_s <= 0:
                raise TimeoutError(f"Timed out reading reply from {pipe_name}")
            reset_event(event)
            ov_read = _Overlapped()
            ov_read.hEvent = event
            nread = wintypes.DWORD(0)
            ok = read_file(handle, chunk_buf, len(chunk_buf), ctypes.byref(nread), ctypes.byref(ov_read))
            if not ok:
                err = ctypes.get_last_error()
                if err == error_io_pending:
                    wait_res = wait_single(event, max(1, int(rem_s * 1000)))
                    if wait_res != wait_object_0:
                        cancel_io_ex(handle, ctypes.byref(ov_read))
                        get_overlapped(handle, ctypes.byref(ov_read), ctypes.byref(nread), True)
                        raise TimeoutError(f"Timed out waiting for reply from {pipe_name}")
                    if not get_overlapped(handle, ctypes.byref(ov_read), ctypes.byref(nread), False):
                        err2 = ctypes.get_last_error()
                        if err2 == error_broken_pipe:
                            break
                        if err2 != error_more_data:
                            raise OSError(err2, f"GetOverlappedResult(read) failed on {pipe_name}")
                elif err == error_broken_pipe:
                    break
                elif err != error_more_data:
                    raise OSError(err, f"ReadFile failed on {pipe_name} (err={err})")

            if nread.value == 0:
                break
            received.extend(chunk_buf.raw[: nread.value])
            if b"\n" in received:
                break

        line = received.split(b"\n", 1)[0].decode("utf-8").strip()
        if not line:
            raise PackageError(f"Empty reply from {pipe_name}")
        parsed = json.loads(line)
        if not isinstance(parsed, dict):
            raise PackageError(f"Non-object JSON reply from {pipe_name}: {line!r}")
        return parsed
    finally:
        close_handle(event)
        close_handle(handle)


def is_in_job_object() -> bool:
    """Detect whether the current process is assigned to a Windows Job Object."""
    if sys.platform != "win32":
        return False

    import ctypes
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    kernel32.IsProcessInJob.argtypes = [
        wintypes.HANDLE,
        wintypes.HANDLE,
        ctypes.POINTER(wintypes.BOOL),
    ]
    kernel32.IsProcessInJob.restype = wintypes.BOOL

    in_job = wintypes.BOOL(0)
    ok = kernel32.IsProcessInJob(kernel32.GetCurrentProcess(), None, ctypes.byref(in_job))
    if not ok:
        return False
    return bool(in_job.value)


def launch_via_explorer_shell(exe_path: Path, args: list[str]) -> bool:
    """Launch exe via explorer.exe desktop IShellWindows -> ShellExecute so child escapes our Job Object."""
    if sys.platform != "win32":
        return False

    ps_script = (
        "$ErrorActionPreference = 'Stop'; "
        "$t = [Type]::GetTypeFromCLSID([Guid]'9BA05972-F6A8-11CF-A442-00A0C90A8F39'); "
        "$sw = [Activator]::CreateInstance($t); "
        "$hwnd = 0; "
        "$desktop = $sw.FindWindowSW(0, 0, 8, [ref]$hwnd, 1); "
        "if ($null -eq $desktop) { exit 2 }; "
        "$app = $desktop.Document.Application; "
        "if ($null -eq $app) { exit 3 }; "
        "$app.ShellExecute($env:BLINK_LAUNCH_EXE, $env:BLINK_LAUNCH_ARGS, $env:BLINK_LAUNCH_DIR, 'open', 0)"
    )
    env = dict(os.environ)
    env["BLINK_LAUNCH_EXE"] = str(exe_path)
    env["BLINK_LAUNCH_ARGS"] = " ".join(args)
    env["BLINK_LAUNCH_DIR"] = str(exe_path.parent)
    try:
        proc = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-NonInteractive",
                "-WindowStyle",
                "Hidden",
                "-Command",
                ps_script,
            ],
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
            creationflags=CREATE_NO_WINDOW,
        )
        return proc.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def launch_with_breakaway(exe_path: Path, args: list[str]) -> bool:
    """Fallback launch requesting CREATE_BREAKAWAY_FROM_JOB."""
    if sys.platform != "win32":
        return False
    try:
        subprocess.Popen(
            [str(exe_path), *args],
            cwd=str(exe_path.parent),
            creationflags=CREATE_BREAKAWAY_FROM_JOB | DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP,
            close_fds=True,
        )
        return True
    except OSError:
        return False


def launch_direct(exe_path: Path, args: list[str]) -> bool:
    """Direct detached launch (remains inside Job Object if caller is in a Job Object)."""
    try:
        flags = (DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP) if sys.platform == "win32" else 0
        subprocess.Popen(
            [str(exe_path), *args],
            cwd=str(exe_path.parent),
            creationflags=flags,
            close_fds=True,
        )
        return True
    except OSError:
        return False


def read_uninstall_entry_for_identity(identity: str) -> UninstallEntry | None:
    """Read HKCU Uninstall key for the specified BLINK identity ONLY."""
    if sys.platform != "win32":
        return None
    if identity not in IDENTITY_SPECS:
        raise PackageError(f"Unknown BLINK identity: {identity!r}")

    import winreg

    spec = IDENTITY_SPECS[identity]
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, spec.uninstall_subkey, 0, winreg.KEY_READ) as key:
            def _read_str(name: str) -> str:
                try:
                    value, _ = winreg.QueryValueEx(key, name)
                    return str(value).strip()
                except FileNotFoundError:
                    return ""

            install_loc = _read_str("InstallLocation")
            display_ver = _read_str("DisplayVersion")
            uninst = _read_str("UninstallString")
            quiet_uninst = _read_str("QuietUninstallString")
            if not install_loc:
                return None
            return UninstallEntry(
                install_location=Path(install_loc),
                display_version=display_ver,
                uninstall_string=uninst,
                quiet_uninstall_string=quiet_uninst,
            )
    except FileNotFoundError:
        return None


def read_dev_uninstall_entry() -> UninstallEntry | None:
    """Strictly read ONLY the blink-dev HKCU Uninstall key (never blink or test identities)."""
    return read_uninstall_entry_for_identity("blink-dev")


def request_quit_for_update_process(
    exe_path: Path,
    identity: str,
    timeout_s: float,
    *,
    env: Mapping[str, str] | None = None,
) -> QuitRequestResult:
    """Invoke `<exe_path> --quit-for-update` and classify accepted / busy / error without force-killing."""
    del identity
    try:
        proc = subprocess.run(
            [str(exe_path), "--quit-for-update"],
            cwd=str(exe_path.parent),
            env=dict(env) if env is not None else None,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout_s,
            creationflags=_subprocess_flags(),
        )
    except subprocess.TimeoutExpired:
        return QuitRequestResult(ok=False, busy=False, detail="quit_for_update_helper_timeout")
    except OSError as exc:
        return QuitRequestResult(ok=False, busy=False, detail=f"quit_for_update_launch_error: {exc}")

    combined = f"{proc.stdout}\n{proc.stderr}".strip()
    if proc.returncode == 0:
        return QuitRequestResult(ok=True, busy=False, detail=combined or "accepted")

    lowered = combined.lower()
    if proc.returncode == 2 or '"reason":"busy"' in lowered.replace(" ", "") or "busy" in lowered:
        return QuitRequestResult(ok=False, busy=True, detail=combined or "busy")
    return QuitRequestResult(
        ok=False,
        busy=False,
        detail=combined or f"quit_for_update_exit_{proc.returncode}",
    )


def silent_install_command(
    installer_path: Path,
    *,
    extra_args: list[str] | None = None,
    install_dir: Path | None = None,
) -> str:
    """Command line for a silent NSIS install.

    /D= must come last and stay unquoted even with spaces: NSIS takes the rest of the line as the
    folder and only recognises /D= after a space, so it cannot go through list quoting.
    """
    cmd = subprocess.list2cmdline([str(installer_path), "/S", *(extra_args or [])])
    if install_dir is not None:
        cmd += f" /D={install_dir}"
    return cmd


def run_silent_installer(
    installer_path: Path,
    *,
    extra_args: list[str] | None = None,
    install_dir: Path | None = None,
    timeout_s: float = INSTALLER_TIMEOUT_SECONDS,
) -> int:
    """Run the installer silently; its exit code, or INSTALLER_TIMED_OUT when it hung."""
    cmd = silent_install_command(installer_path, extra_args=extra_args, install_dir=install_dir)
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=_subprocess_flags(),
            timeout=timeout_s,
        )
    except subprocess.TimeoutExpired:
        return INSTALLER_TIMED_OUT
    return proc.returncode


def is_app_window_open(exe_path: Path) -> bool:
    """True when a process running exe_path shows a visible, unowned, non-tool top-level window.

    A window hidden to the tray is not visible; a minimized one still counts as open.
    """
    if sys.platform != "win32":
        return False

    import ctypes
    from ctypes import wintypes

    user32 = ctypes.WinDLL("user32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    gw_owner = 4
    gwl_exstyle = -20
    ws_ex_toolwindow = 0x00000080
    process_query_limited_information = 0x1000

    enum_proc_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user32.EnumWindows.argtypes = [enum_proc_type, wintypes.LPARAM]
    user32.EnumWindows.restype = wintypes.BOOL
    user32.IsWindowVisible.argtypes = [wintypes.HWND]
    user32.IsWindowVisible.restype = wintypes.BOOL
    user32.GetWindow.argtypes = [wintypes.HWND, wintypes.UINT]
    user32.GetWindow.restype = wintypes.HWND
    user32.GetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int]
    user32.GetWindowLongW.restype = wintypes.LONG
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.QueryFullProcessImageNameW.argtypes = [
        wintypes.HANDLE,
        wintypes.DWORD,
        wintypes.LPWSTR,
        ctypes.POINTER(wintypes.DWORD),
    ]
    kernel32.QueryFullProcessImageNameW.restype = wintypes.BOOL
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL

    # The kernel reports the image path with links and junctions resolved.
    wanted = os.path.normcase(os.path.realpath(str(exe_path)))
    image_by_pid: dict[int, str] = {}
    found = False

    def image_of(pid: int) -> str:
        if pid not in image_by_pid:
            image = ""
            handle = kernel32.OpenProcess(process_query_limited_information, False, pid)
            if handle:
                try:
                    size = wintypes.DWORD(32768)
                    buf = ctypes.create_unicode_buffer(size.value)
                    if kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
                        image = os.path.normcase(buf.value)
                finally:
                    kernel32.CloseHandle(handle)
            image_by_pid[pid] = image
        return image_by_pid[pid]

    def on_window(hwnd: int, _lparam: int) -> bool:
        nonlocal found
        if not user32.IsWindowVisible(hwnd) or user32.GetWindow(hwnd, gw_owner):
            return True
        if user32.GetWindowLongW(hwnd, gwl_exstyle) & ws_ex_toolwindow:
            return True
        pid = wintypes.DWORD(0)
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if pid.value and image_of(pid.value) == wanted:
            found = True
            return False
        return True

    user32.EnumWindows(enum_proc_type(on_window), 0)
    return found


def verify_running_in_tray_windows(identity: str, timeout_s: float) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if is_instance_running(identity):
            try:
                reply = send_pipe_command(identity, "ping", timeout_s=1.0)
                if reply.get("ok") is True:
                    return True
            except (OSError, TimeoutError, PackageError, json.JSONDecodeError):
                pass
        time.sleep(0.2)
    return is_instance_running(identity)


def build_default_dev_install_deps() -> DevInstallDeps:
    return DevInstallDeps(
        read_dev_uninstall_entry=read_dev_uninstall_entry,
        is_running=is_instance_running,
        request_quit_for_update=request_quit_for_update_process,
        run_installer=run_silent_installer,
        read_exe_product_version=read_exe_product_version,
        is_in_job_object=is_in_job_object,
        launch_via_explorer_shell=launch_via_explorer_shell,
        launch_with_breakaway=launch_with_breakaway,
        launch_direct=launch_direct,
        verify_running_in_tray=verify_running_in_tray_windows,
        clock=SystemClock(),
        is_window_open=is_app_window_open,
        is_exe_running=is_exe_process_running,
    )


def _locate_windows_release_dir(client_dir: Path, exe_name: str = "blink_client.exe") -> Path:
    candidates = ("blink_client.exe", exe_name) if exe_name != "blink_client.exe" else ("blink_client.exe",)
    preferred = client_dir / "build" / "windows" / "x64" / "runner" / "Release"
    for name in candidates:
        if (preferred / name).is_file():
            return preferred

    win_build = client_dir / "build" / "windows"
    if win_build.is_dir():
        for name in candidates:
            for exe in win_build.glob(f"*/runner/Release/{name}"):
                if exe.is_file():
                    return exe.parent
    raise PackageError("Windows release executable not found after flutter build")


def compile_nsis_installer(
    makensis_exe: Path,
    nsi_path: Path,
    *,
    spec: IdentitySpec,
    version: str,
    file_version: str,
    app_dir: Path,
    icon_path: Path,
    out_file: Path,
    work_dir: Path,
) -> None:
    """Write the uninstall file list next to the staged app and compile blink.nsi into out_file."""
    files_nsh = work_dir / "installed-files.nsh"
    atomic_write_text(files_nsh, render_remove_files_nsh(app_dir))
    cmd = [
        str(makensis_exe),
        "-V2",
        # Warnings fail the build: the script must stay warning-free.
        "-WX",
        "-INPUTCHARSET",
        "UTF8",
        "-OUTPUTCHARSET",
        "UTF8",
        f"-DBLINK_IDENTITY={spec.identity}",
        f"-DBLINK_APP_ID={spec.app_id}",
        f"-DBLINK_PRODUCT_NAME={spec.product_name}",
        f"-DBLINK_VERSION={version}",
        f"-DBLINK_FILE_VERSION={file_version}",
        f"-DBLINK_SOURCE_DIR={app_dir}",
        f"-DBLINK_ICON={icon_path}",
        f"-DBLINK_OUT_FILE={out_file}",
        f"-DBLINK_FILES_NSH={files_nsh}",
        f"-DBLINK_DESKTOP_ON_UPDATE={'1' if spec.desktop_on_update else '0'}",
        str(nsi_path),
    ]
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=_subprocess_flags(),
    )
    if proc.returncode != 0:
        detail = f"{proc.stdout}\n{proc.stderr}".strip()
        raise PackageError(f"makensis failed (rc={proc.returncode}):\n{detail}")
    if not out_file.is_file() or out_file.stat().st_size == 0:
        raise PackageError(f"Expected installer missing or empty: {out_file.name}")


def build_windows_package(
    identity: str,
    *,
    explicit_version: str | None = None,
    dest_dir: Path | None = None,
    repo_root: Path = REPO_ROOT,
    client_dir: Path = CLIENT_DIR,
    nsi_path: Path = NSI_PATH,
    resources_dir: Path = RESOURCES_DIR,
    env: Mapping[str, str] | None = None,
) -> PackageResult:
    """Build Windows release, verify PE ProductVersion, compile the NSIS installer, and stage atomically."""
    if sys.platform != "win32":
        raise PackageError("Windows packaging requires a Windows host")
    if identity not in IDENTITY_SPECS:
        raise PackageError(f"Unknown identity: {identity!r}")

    spec = IDENTITY_SPECS[identity]
    effective_env = dict(env if env is not None else os.environ)
    flutter_exe = find_flutter_executable(effective_env)
    makensis_exe = find_makensis_executable(effective_env)

    if not nsi_path.is_file():
        raise PackageError(f"NSIS script not found: {nsi_path}")
    icon_path = resources_dir / spec.icon_file
    if not icon_path.is_file():
        raise PackageError(f"Channel icon not found: {icon_path}")

    git_state = read_git_state(repo_root)
    version_info = compute_version(spec.channel, explicit_version, dirty=git_state.dirty)
    flutter_version = read_flutter_version(flutter_exe, effective_env)

    build_env = build_cmake_env(effective_env, spec, version_info)
    invalidate_windows_cmake_version_cache(client_dir)

    flutter_cmd = [
        str(flutter_exe),
        "build",
        "windows",
        "--release",
        "--suppress-analytics",
        f"--dart-define=BLINK_CHANNEL={spec.channel}",
        f"--dart-define=BLINK_IDENTITY={spec.identity}",
        f"--dart-define=BLINK_VERSION={version_info.version}",
        f"--dart-define=BLINK_GIT_SHA={git_state.sha}",
    ]
    print(f"[package] Building Windows release for {spec.identity} ({version_info.version})...")
    build_proc = subprocess.run(
        flutter_cmd,
        cwd=client_dir,
        env=build_env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=_subprocess_flags(),
    )
    if build_proc.returncode != 0:
        detail = (build_proc.stderr or build_proc.stdout).strip()
        raise PackageError(f"flutter build windows failed (rc={build_proc.returncode}):\n{detail}")

    release_dir = _locate_windows_release_dir(client_dir, spec.exe_name)

    with tempfile.TemporaryDirectory(prefix=f"blink-stage-{spec.identity}-") as tmp_str:
        tmp_root = Path(tmp_str)
        staged_app_dir = tmp_root / "app"
        staged_out_dir = tmp_root / "out"
        staged_out_dir.mkdir(parents=True, exist_ok=True)

        shutil.copytree(release_dir, staged_app_dir)
        original_exe = staged_app_dir / "blink_client.exe"
        renamed_exe = staged_app_dir / spec.exe_name
        if original_exe.is_file() and original_exe != renamed_exe:
            os.replace(original_exe, renamed_exe)
        if not renamed_exe.is_file():
            raise PackageError(f"Expected staged executable not found: {spec.exe_name}")

        actual_pv = read_exe_product_version(renamed_exe)
        if actual_pv != version_info.version:
            raise PackageError(
                f"Staged {spec.exe_name} ProductVersion mismatch: "
                f"expected {version_info.version!r}, got {actual_pv!r}"
            )

        output_base = f"{spec.identity}-setup-{version_info.version}"
        installer_filename = f"{output_base}.exe"
        staged_installer = staged_out_dir / installer_filename
        print(f"[package] Compiling NSIS installer {installer_filename}...")
        compile_nsis_installer(
            makensis_exe,
            nsi_path,
            spec=spec,
            version=version_info.version,
            file_version=version_info.file_version_str,
            app_dir=staged_app_dir,
            icon_path=icon_path,
            out_file=staged_installer,
            work_dir=tmp_root,
        )
        if not staged_installer.is_file() or staged_installer.stat().st_size == 0:
            raise PackageError(f"Expected installer missing or empty: {installer_filename}")

        digest = sha256_file(staged_installer)
        size_bytes = staged_installer.stat().st_size
        built_at_utc = utc_iso()

        atomic_write_text(staged_out_dir / "SHA256SUMS.txt", f"{digest}  {installer_filename}\n")
        build_info: dict[str, Any] = {
            "version": version_info.version,
            "file_version": version_info.file_version_str,
            "channel": spec.channel,
            "identity": spec.identity,
            "app_id": spec.app_id,
            "product_name": spec.product_name,
            "git_sha": git_state.sha,
            "git_branch": git_state.branch,
            "dirty": version_info.dirty,
            "flutter_version": flutter_version,
            "installer": installer_filename,
            "sha256": digest,
            "size_bytes": size_bytes,
            "built_at_utc": built_at_utc,
        }
        atomic_write_json(staged_out_dir / "build-info.json", build_info)

        # Validate staging output before atomic publish.
        sums_line = (staged_out_dir / "SHA256SUMS.txt").read_text(encoding="utf-8").strip()
        if sums_line != f"{digest}  {installer_filename}":
            raise PackageError("Staging SHA256SUMS.txt validation failed")
        parsed_info = json.loads((staged_out_dir / "build-info.json").read_text(encoding="utf-8"))
        if parsed_info.get("sha256") != digest or parsed_info.get("version") != version_info.version:
            raise PackageError("Staging build-info.json validation failed")

        target_dir = dest_dir if dest_dir is not None else (DIST_ROOT / spec.channel)
        atomic_replace_directory(staged_out_dir, target_dir)

    final_installer = target_dir / installer_filename
    return PackageResult(
        spec=spec,
        version_info=version_info,
        git_state=git_state,
        flutter_version=flutter_version,
        output_dir=target_dir,
        installer_path=final_installer,
        sha256=digest,
        size_bytes=size_bytes,
        built_at_utc=built_at_utc,
        build_info=build_info,
    )


def _display_installer_path(installer_path: Path | None, repo_root: Path) -> str | None:
    if installer_path is None:
        return None
    try:
        return installer_path.resolve().relative_to(repo_root.resolve()).as_posix()
    except ValueError:
        return installer_path.as_posix()


def new_install_receipt(
    *,
    identity: str,
    new_version: str | None,
    dirty: bool | None,
    installer: str | None,
    at: str,
    branch: str | None = None,
    git_sha: str | None = None,
) -> dict[str, Any]:
    """install-dev.json with every field present (the unified camelCase ones plus BLINK's own)."""
    return {
        "identity": identity,
        "installed": False,
        "skipped": False,
        "reason": None,
        "error": None,
        "firstInstall": False,
        "oldVersion": None,
        "newVersion": new_version,
        "branch": branch,
        "gitSha": git_sha,
        "dirty": dirty,
        "installLocation": None,
        "installer": installer,
        "wasRunning": False,
        "windowOpen": False,
        "deferred": False,
        "deferMs": None,
        "quitMs": None,
        "verifiedRegistryVersion": None,
        "verifiedExeVersion": None,
        "relaunched": False,
        "background": False,
        "launchMethod": None,
        "runningInTray": False,
        "inJob": False,
        "guidance": None,
        "elapsedMs": 0,
        "at": at,
    }


def run_dev_auto_install(
    *,
    channel: str,
    identity: str | None = None,
    installer_path: Path | None,
    new_version: str | None,
    dirty: bool,
    env: Mapping[str, str],
    deps: DevInstallDeps,
    receipt_path: Path,
    repo_root: Path = REPO_ROOT,
    platform_name: str | None = None,
    quit_timeout_s: float = QUIT_WAIT_TIMEOUT_SECONDS,
    poll_interval_s: float = QUIT_POLL_INTERVAL_SECONDS,
    defer_timeout_s: float = WINDOW_DEFER_TIMEOUT_SECONDS,
    defer_poll_interval_s: float = WINDOW_DEFER_POLL_INTERVAL_SECONDS,
    branch: str | None = None,
    git_sha: str | None = None,
) -> tuple[int, dict[str, Any]]:
    """Install the freshly built blink-dev on this machine (engineering.md 2.2, DEC-029).

    Works on both clean PR branches (for pre-review testing) and main; installs on first use too;
    waits while the BLINK Dev window is open (up to defer_timeout_s), asks a tray-only instance
    to save and quit (never force-killed), installs silently, checks the uninstall entry and the
    exe version, then starts it in the tray. The receipt uses the shared camelCase fields.
    """
    eff_platform = platform_name if platform_name is not None else sys.platform
    eff_identity = identity if identity is not None else channel
    rel_installer = _display_installer_path(installer_path, repo_root)
    started = deps.clock.monotonic()
    receipt = new_install_receipt(
        identity=eff_identity,
        new_version=new_version,
        dirty=dirty,
        installer=rel_installer,
        at=utc_iso(deps.clock.utc_now()),
        branch=branch,
        git_sha=git_sha,
    )

    def elapsed_ms(since: float) -> int:
        return int(round(max(0.0, deps.clock.monotonic() - since) * 1000))

    def finish(exit_code: int, **fields: Any) -> tuple[int, dict[str, Any]]:
        receipt.update(fields)
        receipt["elapsedMs"] = elapsed_ms(started)
        atomic_write_json(receipt_path, receipt)
        return exit_code, receipt

    def skip(reason: str, guidance: str) -> tuple[int, dict[str, Any]]:
        return finish(0, skipped=True, reason=reason, guidance=guidance)

    # Set once BLINK Dev was running and agreed to quit for this install.
    quit_for_install = False

    def start_in_tray(exe: Path) -> tuple[bool, dict[str, Any]]:
        """Start exe --background, outside this command's job object when it can; the receipt fields."""
        launch_args = ["--background"]
        guidance: str | None = None
        if deps.is_in_job_object():
            if deps.launch_via_explorer_shell(exe, launch_args):
                launched, launch_method, child_in_job = True, "explorer_shell", False
            elif deps.launch_with_breakaway(exe, launch_args):
                launched, launch_method, child_in_job = True, "breakaway", False
            else:
                launched = deps.launch_direct(exe, launch_args)
                launch_method, child_in_job = "direct_in_job", True
                guidance = (
                    "BLINK Dev was launched inside the current job object (inJob=true) and may exit "
                    "when this command session ends. Please open BLINK Dev once from the Start Menu."
                )
        else:
            launched = deps.launch_direct(exe, launch_args)
            launch_method, child_in_job = "direct", False
        fields: dict[str, Any] = {"launchMethod": launch_method, "inJob": child_in_job}
        if launched:
            fields.update(
                relaunched=True,
                background=True,
                runningInTray=deps.verify_running_in_tray("blink-dev", TRAY_VERIFY_TIMEOUT_SECONDS),
                guidance=guidance,
            )
        return launched, fields

    def fail(reason: str, error: str, *, folder_intact: bool = True) -> tuple[int, dict[str, Any]]:
        """A failed install. When this install had closed BLINK Dev, start it again in the tray, but only
        from a folder the installer left whole (it stopped before touching files, or finished writing)."""
        fields: dict[str, Any] = {"reason": reason, "error": error}
        if quit_for_install and folder_intact:
            _, launch_fields = start_in_tray(installed_exe)
            fields.update(launch_fields)
        elif quit_for_install:
            fields["guidance"] = (
                "BLINK Dev was not started again: its folder may be partly written. Run "
                "`python -B scripts/package.py --install` again."
            )
        return finish(1, **fields)

    # Guard 0: --install strictly accepts the blink-dev channel and identity (never blink or test identities).
    if channel != "blink-dev" or eff_identity != "blink-dev":
        return fail(
            "invalid_channel_for_install",
            "--install is strictly restricted to the blink-dev channel and identity.",
        )

    # Guard 1: environment skip flags (BLINK_DEV_AUTO_INSTALL=0 or CI=true).
    if env.get("BLINK_DEV_AUTO_INSTALL", "").strip() == "0":
        return skip("disabled_by_env", "Skipped because BLINK_DEV_AUTO_INSTALL=0.")
    if env.get("CI", "").strip().lower() in ("true", "1"):
        return skip("ci_environment", "Skipped because CI is enabled.")
    if eff_platform != "win32":
        return skip("non_windows_platform", f"Windows-only dev auto-install skipped on {eff_platform}.")
    if installer_path is None or not new_version:
        return fail("missing_installer", "No blink-dev installer was built or provided.")

    # Step 1: read ONLY the blink-dev uninstall entry; without one this is the first install.
    existing = deps.read_dev_uninstall_entry()
    if existing is not None and str(existing.install_location).strip() not in ("", "."):
        install_dir = existing.install_location
        receipt["oldVersion"] = existing.display_version or None
    else:
        receipt["firstInstall"] = True
        local_app_data = env.get("LOCALAPPDATA", "").strip()
        install_dir = Path(local_app_data) / "Programs" / "blink-dev" if local_app_data else Path("blink-dev")
    receipt["installLocation"] = str(install_dir)
    installed_exe = install_dir / "blink-dev.exe"

    # Step 2: an open window means the user is working in BLINK Dev: wait for it to close or hide
    # to the tray (bounded), then ask the tray instance to save and quit (max 30 s, never force-killed).
    still_running = deps.is_running("blink-dev")
    receipt["wasRunning"] = still_running
    if still_running and deps.is_window_open(installed_exe):
        receipt["windowOpen"] = True
        receipt["deferred"] = True
        defer_start = deps.clock.monotonic()
        while still_running and deps.is_window_open(installed_exe):
            waited = deps.clock.monotonic() - defer_start
            if waited >= defer_timeout_s:
                receipt["deferMs"] = elapsed_ms(defer_start)
                return skip(
                    "window_open",
                    (
                        f"The BLINK Dev window stayed open for {int(defer_timeout_s)}s, so this build was not "
                        "installed. Close the window (or hide it to the tray) and run "
                        "`python -B scripts/package.py --install` again."
                    ),
                )
            deps.clock.sleep(min(defer_poll_interval_s, defer_timeout_s - waited))
            still_running = deps.is_running("blink-dev")
        receipt["deferMs"] = elapsed_ms(defer_start)

    quit_start = deps.clock.monotonic()
    if still_running:
        quit_res = deps.request_quit_for_update(installed_exe, "blink-dev", quit_timeout_s)
        if quit_res.busy:
            return finish(
                1,
                reason="busy",
                error="Running BLINK Dev reported busy; aborted without force-killing.",
                quitMs=elapsed_ms(quit_start),
            )
        if not quit_res.ok:
            return finish(
                1,
                reason=quit_res.detail or "quit_request_failed",
                error="Failed to request graceful quit from BLINK Dev; aborted without force-killing.",
                quitMs=elapsed_ms(quit_start),
            )
        quit_for_install = True
        while deps.is_running("blink-dev"):
            waited = deps.clock.monotonic() - quit_start
            if waited >= quit_timeout_s:
                return finish(
                    1,
                    reason="quit_timeout",
                    error=(
                        f"BLINK Dev did not exit within {int(quit_timeout_s)}s after --quit-for-update; "
                        "aborted without force-killing."
                    ),
                    quitMs=elapsed_ms(quit_start),
                )
            deps.clock.sleep(min(poll_interval_s, quit_timeout_s - waited))

    # The single-instance lock goes before the process has ended and let go of its files, and a
    # blink-dev.exe without the lock (still exiting, or hung) holds them too: wait for the process
    # itself within the same limit, never ending it (#31).
    while deps.is_exe_running(installed_exe):
        waited = deps.clock.monotonic() - quit_start
        if waited >= quit_timeout_s:
            if still_running:
                return finish(
                    1,
                    reason="quit_timeout",
                    error=(
                        f"BLINK Dev released its lock but its process did not end within {int(quit_timeout_s)}s "
                        "after --quit-for-update; aborted without force-killing."
                    ),
                    quitMs=elapsed_ms(quit_start),
                )
            return finish(
                1,
                reason="process_running",
                error=(
                    f"{installed_exe} was still running after {int(quit_timeout_s)}s without the single-instance "
                    "lock (still exiting or hung), so its files are locked; aborted without force-killing."
                ),
            )
        deps.clock.sleep(min(poll_interval_s, quit_timeout_s - waited))
    if still_running:
        receipt["quitMs"] = elapsed_ms(quit_start)

    # Step 3: silent install, then check both the uninstall entry and the installed exe.
    rc = deps.run_installer(installer_path)
    if rc != 0:
        meaning = INSTALLER_EXIT_MEANINGS.get(rc)
        detail = f": {meaning}" if meaning else ""
        return fail(
            f"installer_failed_exit_{rc}",
            f"Silent installer exited with non-zero code {rc}{detail}.",
            folder_intact=rc in INSTALLER_EXITS_BEFORE_FILES,
        )

    post_entry = deps.read_dev_uninstall_entry()
    if post_entry is None:
        return fail("uninstall_entry_missing", "The blink-dev uninstall entry is missing after a silent install.")
    reg_version = post_entry.display_version
    receipt["verifiedRegistryVersion"] = reg_version
    receipt["installLocation"] = str(post_entry.install_location)
    post_exe = post_entry.install_location / "blink-dev.exe"
    try:
        exe_version = deps.read_exe_product_version(post_exe)
    except Exception as exc:
        return fail("version_read_failed", f"Could not read ProductVersion from installed blink-dev.exe: {exc}")
    receipt["verifiedExeVersion"] = exe_version
    if reg_version != new_version or exe_version != new_version:
        return fail(
            "version_mismatch",
            f"Version mismatch after install: expected={new_version!r}, registry={reg_version!r}, exe={exe_version!r}.",
        )
    receipt["installed"] = True

    # Step 4: always start the installed blink-dev.exe --background, leaving this command's job object if any.
    launched, launch_fields = start_in_tray(post_exe)
    if not launched:
        return finish(
            1,
            reason="launch_failed",
            error="Installed successfully, but failed to launch blink-dev.exe --background.",
            **launch_fields,
        )
    # Step 5: write the final receipt.
    return finish(0, **launch_fields)


def _snapshot_reg_key(subkey: str) -> dict[str, Any]:
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, subkey, 0, winreg.KEY_READ) as key:
            values: dict[str, str] = {}
            idx = 0
            while True:
                try:
                    name, val, _ = winreg.EnumValue(key, idx)
                    values[name] = str(val)
                    idx += 1
                except OSError:
                    break
            return {"exists": True, "values": dict(sorted(values.items()))}
    except FileNotFoundError:
        return {"exists": False, "values": {}}


def _scan_matching_entries(base_dir: Path, prefix_or_contains: str, *, recursive: bool, contains: bool) -> list[str]:
    if not base_dir.is_dir():
        return []
    found: list[str] = []
    needle = prefix_or_contains.lower()
    if recursive:
        for root_str, dirs, files in os.walk(base_dir):
            root_path = Path(root_str)
            for name in sorted(dirs):
                low = name.lower()
                if (needle in low) if contains else low.startswith(needle):
                    found.append((root_path / name).relative_to(base_dir).as_posix() + "/")
            for name in sorted(files):
                low = name.lower()
                if (needle in low) if contains else low.startswith(needle):
                    found.append((root_path / name).relative_to(base_dir).as_posix())
    else:
        for child in sorted(base_dir.iterdir(), key=lambda p: p.name.lower()):
            low = child.name.lower()
            if (needle in low) if contains else low.startswith(needle):
                suffix = "/" if child.is_dir() else ""
                found.append(child.name + suffix)
    return sorted(found)


def _query_known_folder_documents_win32() -> Path | None:
    """Query the real Windows Documents directory via SHGetKnownFolderPath(FOLDERID_Documents)."""
    if sys.platform != "win32":
        return None

    import ctypes
    from ctypes import wintypes

    class _GUID(ctypes.Structure):
        _fields_ = [
            ("Data1", wintypes.DWORD),
            ("Data2", wintypes.WORD),
            ("Data3", wintypes.WORD),
            ("Data4", ctypes.c_ubyte * 8),
        ]

    # FOLDERID_Documents = {FDD39AD0-238F-46AF-ADB4-6C85480369C7}
    folderid_documents = _GUID(
        0xFDD39AD0,
        0x238F,
        0x46AF,
        (ctypes.c_ubyte * 8)(0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7),
    )
    kf_flag_dont_verify = 0x00004000

    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    sh_get_known_folder_path = shell32.SHGetKnownFolderPath
    sh_get_known_folder_path.argtypes = [
        ctypes.POINTER(_GUID),
        wintypes.DWORD,
        wintypes.HANDLE,
        ctypes.POINTER(ctypes.c_void_p),
    ]
    sh_get_known_folder_path.restype = ctypes.c_long

    ole32 = ctypes.WinDLL("ole32", use_last_error=True)
    co_task_mem_free = ole32.CoTaskMemFree
    co_task_mem_free.argtypes = [ctypes.c_void_p]
    co_task_mem_free.restype = None

    path_ptr = ctypes.c_void_p()
    try:
        hr = sh_get_known_folder_path(
            ctypes.byref(folderid_documents),
            kf_flag_dont_verify,
            None,
            ctypes.byref(path_ptr),
        )
        if hr < 0 or not path_ptr.value:
            return None
        resolved = ctypes.wstring_at(path_ptr.value).strip()
        return Path(resolved) if resolved else None
    finally:
        if path_ptr.value:
            co_task_mem_free(path_ptr.value)


def resolve_windows_documents_dir(
    env: Mapping[str, str] | None = None,
    *,
    query_known_folder: Callable[[], Path | None] | None = None,
) -> Path | None:
    """Resolve the host Windows Documents folder via SHGetKnownFolderPath(FOLDERID_Documents),
    falling back to %USERPROFILE%\\Documents.
    """
    effective_env = env if env is not None else os.environ
    known: Path | None = None
    if query_known_folder is not None:
        known = query_known_folder()
    elif sys.platform == "win32":
        try:
            known = _query_known_folder_documents_win32()
        except OSError:
            known = None
    if known is not None:
        return known
    userprofile = effective_env.get("USERPROFILE", "").strip()
    if userprofile:
        return Path(userprofile) / "Documents"
    return None


def capture_host_snapshot(
    env: Mapping[str, str] | None = None,
    *,
    exclude_dir: Path | None = None,
    documents_dir_resolver: Callable[[Mapping[str, str]], Path | None] | None = None,
) -> dict[str, Any]:
    """Capture real host state (blink & blink-dev Uninstall keys, Start Menu, %LOCALAPPDATA%\\blink*, <Documents>\\blink*)."""
    effective_env = env if env is not None else os.environ
    uninstall_snapshot = {
        ident: _snapshot_reg_key(IDENTITY_SPECS[ident].uninstall_subkey)
        for ident in ("blink", "blink-dev", "blink-test", "blink-dev-test")
    }

    start_menu_entries: dict[str, list[str]] = {}
    appdata = effective_env.get("APPDATA", "").strip()
    if appdata:
        user_sm = Path(appdata) / "Microsoft" / "Windows" / "Start Menu" / "Programs"
        start_menu_entries["user_start_menu"] = _scan_matching_entries(
            user_sm, "blink", recursive=True, contains=True
        )
    program_data = effective_env.get("PROGRAMDATA", "").strip()
    if program_data:
        common_sm = Path(program_data) / "Microsoft" / "Windows" / "Start Menu" / "Programs"
        start_menu_entries["common_start_menu"] = _scan_matching_entries(
            common_sm, "blink", recursive=True, contains=True
        )

    local_entries: dict[str, list[str]] = {}
    local_app_data = effective_env.get("LOCALAPPDATA", "").strip()
    excluded_name = exclude_dir.name.lower() if exclude_dir is not None else None
    if local_app_data:
        lad_path = Path(local_app_data)
        top = [
            e
            for e in _scan_matching_entries(lad_path, "blink", recursive=False, contains=False)
            if excluded_name is None or e.rstrip("/").lower() != excluded_name
        ]
        local_entries["localappdata_blink"] = top
        local_entries["localappdata_programs_blink"] = _scan_matching_entries(
            lad_path / "Programs", "blink", recursive=False, contains=False
        )

    documents_entries: dict[str, list[str]] = {}
    docs_resolver = documents_dir_resolver or resolve_windows_documents_dir
    docs_path = docs_resolver(effective_env)
    if docs_path is not None:
        documents_entries["documents_blink"] = [
            e
            for e in _scan_matching_entries(docs_path, "blink", recursive=False, contains=False)
            if excluded_name is None or e.rstrip("/").lower() != excluded_name
        ]

    desktop_entries: list[str] = []
    userprofile = effective_env.get("USERPROFILE", "").strip()
    if userprofile:
        desktop_entries = _scan_matching_entries(
            Path(userprofile) / "Desktop", "blink", recursive=False, contains=True
        )
        fallback_docs = Path(userprofile) / "Documents"
        if docs_path is None or os.path.normcase(str(fallback_docs)) != os.path.normcase(str(docs_path)):
            documents_entries["userprofile_documents_blink"] = [
                e
                for e in _scan_matching_entries(fallback_docs, "blink", recursive=False, contains=False)
                if excluded_name is None or e.rstrip("/").lower() != excluded_name
            ]

    return {
        "uninstall_keys": uninstall_snapshot,
        "start_menu": start_menu_entries,
        "localappdata": local_entries,
        "documents": documents_entries,
        "desktop": desktop_entries,
    }


def diff_snapshots(before: Mapping[str, Any], after: Mapping[str, Any]) -> dict[str, Any]:
    diff: dict[str, Any] = {}
    for key in sorted(set(before.keys()) | set(after.keys())):
        if before.get(key) != after.get(key):
            diff[key] = {"before": before.get(key), "after": after.get(key)}
    return diff


def _wait_for_pipe_ping(identity: str, *, timeout_s: float = 10.0) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_s
    last_err: str = "pipe not ready"
    while time.monotonic() < deadline:
        try:
            reply = send_pipe_command(identity, "ping", timeout_s=1.5)
            if reply.get("ok") is True:
                return reply
            last_err = f"unexpected ping reply: {reply!r}"
        except Exception as exc:
            last_err = str(exc)
        time.sleep(0.2)
    raise PackageError(f"Control pipe ping failed for {identity} within {timeout_s}s: {last_err}")


def _wait_for_mutex_release(identity: str, *, timeout_s: float) -> float:
    start = time.monotonic()
    while is_instance_running(identity):
        if time.monotonic() - start >= timeout_s:
            raise PackageError(f"Mutex {identity}-instance still held after {timeout_s:.1f}s")
        time.sleep(0.1)
    return round(time.monotonic() - start, 3)


def _validate_lifecycle_json(
    data_dir: Path,
    *,
    expected_version: str,
    expected_identity: str,
    expected_window_visible: bool = False,
) -> dict[str, Any]:
    lifecycle_path = data_dir / "run" / "lifecycle.json"
    if not lifecycle_path.is_file():
        raise PackageError(f"Expected lifecycle.json not found at {lifecycle_path.name}")
    parsed = json.loads(lifecycle_path.read_text(encoding="utf-8"))
    if not isinstance(parsed, dict):
        raise PackageError("lifecycle.json is not a JSON object")

    exit_reason = str(parsed.get("exitReason", "")).strip()
    if exit_reason.replace("-", "_") != "quit_for_update":
        raise PackageError(f"Unexpected lifecycle.json exitReason: {exit_reason!r}")
    if parsed.get("windowWasVisible") is not expected_window_visible:
        raise PackageError(
            f"Unexpected lifecycle.json windowWasVisible: {parsed.get('windowWasVisible')!r}"
        )
    if parsed.get("version") != expected_version:
        raise PackageError(
            f"Unexpected lifecycle.json version: expected {expected_version!r}, got {parsed.get('version')!r}"
        )
    if parsed.get("identity") != expected_identity:
        raise PackageError(
            f"Unexpected lifecycle.json identity: expected {expected_identity!r}, got {parsed.get('identity')!r}"
        )
    if not str(parsed.get("timestampUtc", "")).strip():
        raise PackageError("Missing timestampUtc in lifecycle.json")
    return parsed


def _resolve_uninstaller_path(entry: UninstallEntry | None, install_dir: Path) -> Path:
    candidates: list[Path] = []
    if entry is not None:
        for raw in (entry.quiet_uninstall_string, entry.uninstall_string):
            cleaned = raw.strip()
            if not cleaned:
                continue
            if cleaned.startswith('"'):
                end_quote = cleaned.find('"', 1)
                if end_quote > 1:
                    candidates.append(Path(cleaned[1:end_quote]))
            else:
                candidates.append(Path(cleaned.split()[0]))
    candidates.append(install_dir / "Uninstall.exe")
    for cand in candidates:
        if cand.is_file():
            return cand
    raise PackageError("Uninstaller executable Uninstall.exe not found for blink-dev-test")


def _resolve_windows_shell_dir(csidl: int) -> Path | None:
    if sys.platform != "win32":
        return None
    import ctypes
    from ctypes import wintypes

    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    get_folder = shell32.SHGetFolderPathW
    get_folder.argtypes = [wintypes.HWND, ctypes.c_int, wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR]
    get_folder.restype = ctypes.c_long
    buf = ctypes.create_unicode_buffer(32768)
    if get_folder(None, csidl, None, 0, buf) == 0 and buf.value:
        return Path(buf.value)
    return None


def resolve_user_shortcut_paths(
    spec: IdentitySpec,
    env: Mapping[str, str] | None = None,
) -> tuple[Path | None, Path | None]:
    """Return (start_menu_lnk, desktop_lnk) matching NSIS $SMPROGRAMS and $DESKTOP."""
    effective_env = env if env is not None else os.environ
    sm_dir: Path | None = None
    desktop_dir: Path | None = None
    if sys.platform == "win32" and env is None:
        sm_dir = _resolve_windows_shell_dir(0x0002)  # CSIDL_PROGRAMS
        desktop_dir = _resolve_windows_shell_dir(0x0010)  # CSIDL_DESKTOPDIRECTORY
    if sm_dir is None:
        appdata = effective_env.get("APPDATA", "").strip()
        if appdata:
            sm_dir = Path(appdata) / "Microsoft" / "Windows" / "Start Menu" / "Programs"
    if desktop_dir is None:
        userprofile = effective_env.get("USERPROFILE", "").strip()
        if userprofile:
            desktop_dir = Path(userprofile) / "Desktop"
    lnk_name = f"{spec.product_name}.lnk"
    return (sm_dir / lnk_name if sm_dir is not None else None), (desktop_dir / lnk_name if desktop_dir is not None else None)


def _unlink_with_retry(path: Path, *, timeout_s: float = 5.0) -> None:
    deadline = time.monotonic() + timeout_s
    while True:
        try:
            path.unlink()
            return
        except FileNotFoundError:
            return
        except OSError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.1)


def run_rehearsal(
    *,
    receipt_path: Path = ARTIFACTS_PACKAGE_DIR / "rehearsal.json",
    repo_root: Path = REPO_ROOT,
    env: Mapping[str, str] | None = None,
) -> tuple[int, dict[str, Any]]:
    """Run M2-K08 + M2-K05 + AC-11 quiet isolated test-identity install/upgrade/uninstall rehearsal."""
    if sys.platform != "win32":
        report = {
            "status": "not-run",
            "identity": "blink-dev-test",
            "reason": "non_windows_platform",
            "timestamp_utc": utc_iso(),
        }
        atomic_write_json(receipt_path, report)
        print(f"not-run: Windows rehearsal skipped on {sys.platform}")
        return 0, report

    effective_env = dict(env if env is not None else os.environ)
    identity = "blink-dev-test"
    spec = IDENTITY_SPECS[identity]

    if is_instance_running(identity):
        raise PackageError(f"Rehearsal aborted: {spec.mutex_name} is already running before rehearsal")

    tmp_root = Path(tempfile.mkdtemp(prefix="blink-rehearsal-"))
    install_dir = tmp_root / "install"
    data_dir = tmp_root / "data"
    documents_dir = tmp_root / "documents"
    pkg_a_dir = tmp_root / "pkg-a"
    pkg_b_dir = tmp_root / "pkg-b"

    before_snapshot = capture_host_snapshot(effective_env, exclude_dir=tmp_root)
    steps: dict[str, Any] = {}
    residue: list[str] = []
    spawned_procs: list[subprocess.Popen[str]] = []
    installed_for_cleanup = False
    version_a: str | None = None
    version_b: str | None = None
    git_sha: str | None = None
    dirty = False
    flutter_version: str | None = None
    uninstalled_cleanly = False
    error_message: str | None = None

    quiet_env = dict(effective_env)
    quiet_env["BLINK_DATA_DIR"] = str(data_dir)
    quiet_env["BLINK_DOCUMENTS_DIR"] = str(documents_dir)
    quiet_env["BLINK_QUIET"] = "1"

    try:
        ts = datetime.now(timezone.utc).strftime("%Y%m%d%H%M")
        pkg_a = build_windows_package(
            identity,
            explicit_version=f"0.1.0-dev.{ts}.1",
            dest_dir=pkg_a_dir,
            repo_root=repo_root,
            env=effective_env,
        )
        pkg_b = build_windows_package(
            identity,
            explicit_version=f"0.1.0-dev.{ts}.2",
            dest_dir=pkg_b_dir,
            repo_root=repo_root,
            env=effective_env,
        )
        version_a = pkg_a.version_info.version
        version_b = pkg_b.version_info.version
        git_sha = pkg_b.git_state.sha
        dirty = pkg_b.version_info.dirty
        flutter_version = pkg_b.flutter_version
        if version_a == version_b:
            raise PackageError("Rehearsal requires two distinct versions A and B")
        steps["build_a_b"] = {"status": "passed", "versionA": version_a, "versionB": version_b}

        # Step R1: Silent install A into isolated temp dir without desktop shortcut.
        sm_lnk, desktop_lnk = resolve_user_shortcut_paths(spec, None if env is None else effective_env)
        rc_a = run_silent_installer(pkg_a.installer_path, extra_args=["/NODESKTOP"], install_dir=install_dir)
        if rc_a != 0:
            raise PackageError(f"Rehearsal installer A failed with exit code {rc_a}")
        installed_for_cleanup = True

        entry_a = read_uninstall_entry_for_identity(identity)
        exe_path = install_dir / spec.exe_name
        if entry_a is None or entry_a.display_version != version_a:
            raise PackageError(
                f"Uninstall DisplayVersion mismatch after A install: got {entry_a.display_version if entry_a else None!r}"
            )
        pv_a = read_exe_product_version(exe_path)
        if pv_a != version_a:
            raise PackageError(f"PE ProductVersion mismatch after A install: expected {version_a!r}, got {pv_a!r}")
        sm_mtime_a: int | None = None
        if sm_lnk is not None:
            if not sm_lnk.is_file():
                raise PackageError(f"First install did not create Start Menu shortcut: {sm_lnk.name}")
            sm_mtime_a = sm_lnk.stat().st_mtime_ns
        if desktop_lnk is not None and desktop_lnk.exists():
            raise PackageError(f"First install with /NODESKTOP unexpectedly created Desktop shortcut: {desktop_lnk.name}")
        steps["install_a"] = {
            "status": "passed",
            "registryVersion": entry_a.display_version,
            "exeVersion": pv_a,
            "startMenuCreated": sm_mtime_a is not None,
            "desktopSkipped": desktop_lnk is not None and not desktop_lnk.exists(),
        }

        # Step R2: Verify --quit-for-update with no running instance exits 0 immediately (M2-K05).
        t0 = time.monotonic()
        no_run_proc = subprocess.run(
            [str(exe_path), "--quit-for-update"],
            cwd=str(install_dir),
            env=quiet_env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=REHEARSAL_QUIT_TIMEOUT_SECONDS,
            creationflags=_subprocess_flags(),
        )
        no_run_elapsed = round(time.monotonic() - t0, 3)
        if no_run_proc.returncode != 0:
            raise PackageError(f"No-running --quit-for-update exited with {no_run_proc.returncode}")
        steps["no_running_quit"] = {"status": "passed", "elapsedSeconds": no_run_elapsed}

        # Step R3: Launch A --background quiet + verify pipe ping (M2-K05).
        proc_a = subprocess.Popen(
            [str(exe_path), "--background"],
            cwd=str(install_dir),
            env=quiet_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=_subprocess_flags(),
        )
        spawned_procs.append(proc_a)
        ping_a = _wait_for_pipe_ping(identity, timeout_s=10.0)
        if proc_a.poll() is not None:
            raise PackageError(f"Instance A exited prematurely (rc={proc_a.returncode})")
        steps["launch_a_ping"] = {"status": "passed", "ping": ping_a}

        # Step R4: Launch 2nd instance (no args) -> forwards focus & exits 0 while 1st stays alive (M2-K05).
        second_proc = subprocess.run(
            [str(exe_path)],
            cwd=str(install_dir),
            env=quiet_env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10.0,
            creationflags=_subprocess_flags(),
        )
        if second_proc.returncode != 0:
            raise PackageError(f"Second instance focus handoff exited with {second_proc.returncode}")
        if proc_a.poll() is not None:
            raise PackageError(f"First instance exited unexpectedly after 2nd instance handoff (rc={proc_a.returncode})")
        ping_after_focus = _wait_for_pipe_ping(identity, timeout_s=5.0)
        steps["second_instance_focus"] = {"status": "passed", "pingAfterFocus": ping_after_focus}

        # Step R5: Upgrade running A -> B via --quit-for-update (< 5s) + lifecycle.json + silent install B + double version check.
        quit_a_start = time.monotonic()
        quit_a_res = request_quit_for_update_process(
            exe_path, identity, REHEARSAL_QUIT_TIMEOUT_SECONDS, env=quiet_env
        )
        if not quit_a_res.ok:
            raise PackageError(f"Rehearsal quit-for-update A failed: {quit_a_res.detail}")
        try:
            proc_a.wait(timeout=REHEARSAL_QUIT_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired as exc:
            raise PackageError(f"Instance A did not exit within {REHEARSAL_QUIT_TIMEOUT_SECONDS}s") from exc
        _wait_for_mutex_release(identity, timeout_s=REHEARSAL_QUIT_TIMEOUT_SECONDS)
        quit_a_elapsed = round(time.monotonic() - quit_a_start, 3)
        if quit_a_elapsed >= REHEARSAL_QUIT_TIMEOUT_SECONDS:
            raise PackageError(f"Instance A quit took {quit_a_elapsed}s (>= {REHEARSAL_QUIT_TIMEOUT_SECONDS}s)")

        lifecycle_a = _validate_lifecycle_json(
            data_dir, expected_version=version_a, expected_identity=identity, expected_window_visible=False
        )
        time.sleep(0.25)

        rc_b = run_silent_installer(pkg_b.installer_path, extra_args=["/NODESKTOP"], install_dir=install_dir)
        if rc_b != 0:
            raise PackageError(f"Rehearsal installer B failed with exit code {rc_b}")

        entry_b = read_uninstall_entry_for_identity(identity)
        if entry_b is None or entry_b.display_version != version_b:
            raise PackageError(
                f"Uninstall DisplayVersion mismatch after B install: got {entry_b.display_version if entry_b else None!r}"
            )
        pv_b = read_exe_product_version(exe_path)
        if pv_b != version_b:
            raise PackageError(f"PE ProductVersion mismatch after B install: expected {version_b!r}, got {pv_b!r}")
        if sm_lnk is not None and sm_mtime_a is not None:
            if not sm_lnk.is_file():
                raise PackageError(f"Silent over-install unexpectedly removed Start Menu shortcut: {sm_lnk.name}")
            sm_mtime_b = sm_lnk.stat().st_mtime_ns
            if sm_mtime_b != sm_mtime_a:
                raise PackageError(
                    f"Silent over-install modified existing Start Menu shortcut {sm_lnk.name} "
                    f"(mtime_ns {sm_mtime_a} -> {sm_mtime_b})"
                )
        if desktop_lnk is not None and desktop_lnk.exists():
            raise PackageError(
                f"Silent over-install with /NODESKTOP unexpectedly created Desktop shortcut: {desktop_lnk.name}"
            )
        steps["upgrade_a_to_b"] = {
            "status": "passed",
            "quitAElapsedSeconds": quit_a_elapsed,
            "lifecycleA": lifecycle_a,
            "registryVersionB": entry_b.display_version,
            "exeVersionB": pv_b,
            "startMenuUntouched": sm_mtime_a is not None,
            "desktopSkipped": desktop_lnk is not None and not desktop_lnk.exists(),
        }

        # Step R6: Launch B --background quiet, ping, then --quit-for-update.
        proc_b = subprocess.Popen(
            [str(exe_path), "--background"],
            cwd=str(install_dir),
            env=quiet_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=_subprocess_flags(),
        )
        spawned_procs.append(proc_b)
        ping_b = _wait_for_pipe_ping(identity, timeout_s=10.0)
        if proc_b.poll() is not None:
            raise PackageError(f"Instance B exited prematurely (rc={proc_b.returncode})")

        quit_b_start = time.monotonic()
        quit_b_res = request_quit_for_update_process(
            exe_path, identity, REHEARSAL_QUIT_TIMEOUT_SECONDS, env=quiet_env
        )
        if not quit_b_res.ok:
            raise PackageError(f"Rehearsal quit-for-update B failed: {quit_b_res.detail}")
        try:
            proc_b.wait(timeout=REHEARSAL_QUIT_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired as exc:
            raise PackageError(f"Instance B did not exit within {REHEARSAL_QUIT_TIMEOUT_SECONDS}s") from exc
        _wait_for_mutex_release(identity, timeout_s=REHEARSAL_QUIT_TIMEOUT_SECONDS)
        quit_b_elapsed = round(time.monotonic() - quit_b_start, 3)

        lifecycle_b = _validate_lifecycle_json(
            data_dir, expected_version=version_b, expected_identity=identity, expected_window_visible=False
        )
        steps["launch_b_and_quit"] = {
            "status": "passed",
            "ping": ping_b,
            "quitBElapsedSeconds": quit_b_elapsed,
            "lifecycleB": lifecycle_b,
        }

        # Step R6b: Delete ONLY the test-identity Start Menu shortcut, reinstall silently with /NODESKTOP,
        # and confirm Start Menu stays absent (never recreated) while /NODESKTOP still keeps Desktop clean.
        if sm_lnk is not None:
            _unlink_with_retry(sm_lnk)
            if sm_lnk.exists():
                raise PackageError(f"Could not delete test Start Menu shortcut before reinstall check: {sm_lnk.name}")
            rc_b2 = run_silent_installer(pkg_b.installer_path, extra_args=["/NODESKTOP"], install_dir=install_dir)
            if rc_b2 != 0:
                raise PackageError(f"Rehearsal reinstall B failed with exit code {rc_b2}")
            if sm_lnk.exists():
                raise PackageError(f"Silent over-install unexpectedly recreated deleted Start Menu shortcut: {sm_lnk.name}")
            if desktop_lnk is not None and desktop_lnk.exists():
                raise PackageError(
                    f"Silent reinstall with /NODESKTOP unexpectedly created Desktop shortcut: {desktop_lnk.name}"
                )
            steps["reinstall_keeps_deleted_start_menu_absent"] = {
                "status": "passed",
                "startMenuAbsent": True,
                "desktopSkipped": desktop_lnk is not None and not desktop_lnk.exists(),
            }

        # Step R7: Silent uninstall & clean residue check (also confirm user data dir was preserved by uninstaller).
        time.sleep(0.25)
        unins_exe = _resolve_uninstaller_path(entry_b, install_dir)
        unins_proc = subprocess.run(
            [str(unins_exe), "/S"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=30.0,
            creationflags=_subprocess_flags(),
        )
        if unins_proc.returncode != 0:
            raise PackageError(f"Silent uninstaller exited with {unins_proc.returncode}")
        installed_for_cleanup = False

        # The NSIS uninstaller re-runs itself from a temp copy and returns at once: wait for that
        # copy to remove the install dir and the uninstall entry.
        wait_deadline = time.monotonic() + 8.0
        while time.monotonic() < wait_deadline:
            reg_still = read_uninstall_entry_for_identity(identity) is not None
            dir_still = install_dir.exists()
            if not reg_still and not dir_still:
                break
            time.sleep(0.2)

        data_preserved = (data_dir / "run" / "lifecycle.json").is_file()
        if not data_preserved:
            residue.append("uninstaller unexpectedly deleted user data dir")

        if read_uninstall_entry_for_identity(identity) is not None:
            residue.append(f"HKCU\\{spec.uninstall_subkey}")
        if install_dir.exists():
            leftovers = [p.relative_to(install_dir).as_posix() for p in install_dir.rglob("*")]
            residue.append(f"install_dir still exists (entries: {leftovers})")

        if sm_lnk is not None and sm_lnk.exists():
            residue.append(f"Start Menu shortcut still exists: {sm_lnk.name}")
        if desktop_lnk is not None and desktop_lnk.exists():
            residue.append(f"Desktop shortcut still exists: {desktop_lnk.name}")

        if residue:
            steps["uninstall_clean"] = {"status": "failed", "residue": list(residue)}
            raise PackageError("Rehearsal uninstall left residue:\n  - " + "\n  - ".join(residue))

        uninstalled_cleanly = True
        steps["uninstall_clean"] = {"status": "passed", "userDataPreserved": data_preserved}

    except Exception as exc:
        error_message = str(exc)
    finally:
        # Clean up ONLY test-identity rehearsal processes we spawned.
        for proc in spawned_procs:
            if proc.poll() is None:
                try:
                    exe_candidate = install_dir / spec.exe_name
                    if exe_candidate.is_file():
                        request_quit_for_update_process(exe_candidate, identity, 3.0, env=quiet_env)
                    proc.wait(timeout=3.0)
                except Exception:
                    try:
                        proc.terminate()
                        proc.wait(timeout=3.0)
                    except Exception:
                        pass

        # If failure happened mid-rehearsal while test-identity was installed, attempt its own uninstaller.
        if installed_for_cleanup:
            try:
                cur_entry = read_uninstall_entry_for_identity(identity)
                unins_fallback = _resolve_uninstaller_path(cur_entry, install_dir)
                subprocess.run(
                    [str(unins_fallback), "/S"],
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=30.0,
                    creationflags=_subprocess_flags(),
                )
            except Exception:
                pass

        # Only remove our own temporary rehearsal directory if uninstall succeeded cleanly.
        if uninstalled_cleanly and tmp_root.exists():
            shutil.rmtree(tmp_root, ignore_errors=True)

    after_snapshot = capture_host_snapshot(effective_env, exclude_dir=tmp_root)
    snapshot_diff = diff_snapshots(before_snapshot, after_snapshot)
    snapshot_match = not snapshot_diff
    steps["snapshot_match"] = {"status": "passed" if snapshot_match else "failed", "diff": snapshot_diff}

    if not snapshot_match:
        msg = f"Host snapshot mismatch after rehearsal: {json.dumps(snapshot_diff, ensure_ascii=False)}"
        error_message = f"{error_message}\n{msg}" if error_message else msg

    overall_ok = error_message is None and snapshot_match and not residue
    report = {
        "status": "passed" if overall_ok else "failed",
        "identity": identity,
        "version_a": version_a,
        "version_b": version_b,
        "git_sha": git_sha,
        "dirty": dirty,
        "flutter_version": flutter_version,
        "steps": steps,
        "residue": residue,
        "snapshot_match": snapshot_match,
        "snapshot_diff": snapshot_diff,
        "error": error_message,
        "timestamp_utc": utc_iso(),
    }
    atomic_write_json(receipt_path, report)

    if not overall_ok:
        print(f"FAIL: rehearsal failed: {error_message}", file=sys.stderr)
        if residue:
            print("Residue detected (non-rehearsal items were NOT touched):", file=sys.stderr)
            for item in residue:
                print(f"  - {item}", file=sys.stderr)
        return 1, report

    print(
        f"PASS: rehearsal succeeded ({identity}: {version_a} -> {version_b}, "
        "clean uninstall, host snapshot exact match)."
    )
    return 0, report


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Build BLINK Windows installers, auto-install blink-dev, or run isolated rehearsal."
    )
    parser.add_argument(
        "--channel",
        choices=("blink-dev", "blink"),
        default="blink-dev",
        help="Target release channel (default: blink-dev).",
    )
    parser.add_argument(
        "--version",
        type=str,
        default=None,
        help="Explicit version (required for --channel blink, e.g. 0.1.0; optional for blink-dev).",
    )
    parser.add_argument(
        "--install",
        action="store_true",
        help="Build blink-dev and install it on this machine (first install too; engineering.md 2.2).",
    )
    parser.add_argument(
        "--rehearsal",
        action="store_true",
        help="Run quiet isolated blink-dev-test install/upgrade/uninstall rehearsal (M2-K08 / AC-11).",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    if args.install and args.rehearsal:
        print("FAIL: --install and --rehearsal cannot be combined.", file=sys.stderr)
        return 1

    if args.rehearsal:
        if args.channel != "blink-dev" or args.version is not None:
            print(
                "FAIL: --rehearsal uses blink-dev-test only and cannot be combined with --channel blink or --version.",
                file=sys.stderr,
            )
            return 1
        try:
            rc, _ = run_rehearsal()
            return rc
        except PackageError as exc:
            print(f"FAIL: {exc}", file=sys.stderr)
            return 1

    if args.install:
        receipt_path = ARTIFACTS_PACKAGE_DIR / "install-dev.json"
        deps = build_default_dev_install_deps()

        # Refuse non-blink-dev channel before any env skip or build.
        if args.channel != "blink-dev":
            rc, receipt = run_dev_auto_install(
                channel=args.channel,
                installer_path=None,
                new_version=None,
                dirty=False,
                env=os.environ,
                deps=deps,
                receipt_path=receipt_path,
            )
            print(f"FAIL: {receipt.get('error') or receipt.get('reason')}", file=sys.stderr)
            return rc

        # Fast-path env skip (BLINK_DEV_AUTO_INSTALL=0 / CI=true) or non-Windows without requiring build tools.
        if (
            os.environ.get("BLINK_DEV_AUTO_INSTALL", "").strip() == "0"
            or os.environ.get("CI", "").strip().lower() in ("true", "1")
            or sys.platform != "win32"
        ):
            rc, receipt = run_dev_auto_install(
                channel=args.channel,
                installer_path=None,
                new_version=None,
                dirty=False,
                env=os.environ,
                deps=deps,
                receipt_path=receipt_path,
            )
            print(f"skipped: {receipt.get('guidance') or receipt.get('reason')}")
            return rc

        try:
            pkg = build_windows_package(
                "blink-dev",
                explicit_version=args.version,
                dest_dir=DIST_ROOT / "blink-dev",
            )
        except PackageError as exc:
            try:
                gs = read_git_state()
            except PackageError:
                gs = None
            failed = new_install_receipt(
                identity="blink-dev",
                new_version=None,
                dirty=gs.dirty if gs is not None else None,
                installer=None,
                at=utc_iso(),
                branch=gs.branch if gs is not None else None,
                git_sha=gs.sha if gs is not None else None,
            )
            failed.update(reason="build_failed", error=str(exc))
            atomic_write_json(receipt_path, failed)
            print(f"FAIL: {exc}", file=sys.stderr)
            return 1

        rc, receipt = run_dev_auto_install(
            channel="blink-dev",
            installer_path=pkg.installer_path,
            new_version=pkg.version_info.version,
            dirty=pkg.version_info.dirty,
            env=os.environ,
            deps=deps,
            receipt_path=receipt_path,
            branch=pkg.git_state.branch,
            git_sha=pkg.git_state.sha,
        )
        if rc != 0:
            print(f"FAIL: dev auto-install failed ({receipt.get('reason')}): {receipt.get('error')}", file=sys.stderr)
        elif receipt["skipped"]:
            print(f"SKIPPED ({receipt.get('reason')}): {receipt.get('guidance')}")
        else:
            print(
                f"INSTALLED: blink-dev {receipt['newVersion']} "
                f"(branch={receipt['branch']}, gitSha={receipt['gitSha']}, "
                f"firstInstall={receipt['firstInstall']}, wasRunning={receipt['wasRunning']}, "
                f"deferred={receipt['deferred']}, runningInTray={receipt['runningInTray']}, "
                f"inJob={receipt['inJob']}, launch={receipt['launchMethod']})."
            )
            if receipt.get("guidance"):
                print(f"NOTE: {receipt['guidance']}")
        return rc

    # Standard packaging mode.
    if sys.platform != "win32":
        print(f"not-run: Windows packaging for channel '{args.channel}' skipped on {sys.platform}.")
        return 0

    try:
        pkg = build_windows_package(
            args.channel,
            explicit_version=args.version,
            dest_dir=DIST_ROOT / args.channel,
        )
    except PackageError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    rel_installer = _display_installer_path(pkg.installer_path, REPO_ROOT)
    print(
        f"PASS: packaged {pkg.spec.identity} {pkg.version_info.version} -> {rel_installer} "
        f"(sha256={pkg.sha256[:16]}..., dirty={pkg.version_info.dirty})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
