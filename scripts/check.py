"""Two-tier quality gate and pinned Linux Flutter installer for BLINK.

Usage:
    python -B scripts/check.py --quick
    python -B scripts/check.py --ci
    python -B scripts/check.py
    python -B scripts/check.py --install-linux-flutter <dest_dir>

Uses Python 3.12 standard library only. Runs quietly with zero popups.
"""

from __future__ import annotations

import argparse
from collections.abc import Callable, Mapping
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request

sys.dont_write_bytecode = True

OFFICIAL_FLUTTER_BASE_URL = "https://storage.googleapis.com/flutter_infra_release/releases"
FLUTTER_VERSION_TEXT_RE = re.compile(r"Flutter\s+([0-9]+\.[0-9]+\.[0-9]+(?:-[^\s\u2022]+)?)")
SHA64_RE = re.compile(r"^[0-9a-f]{64}$")
DOWNLOAD_CHUNK_BYTES = 1024 * 1024
USER_AGENT = "blink-quality-gate/1"


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class StepResult:
    name: str
    status: str  # "passed" | "failed" | "not-run"
    duration_seconds: float
    detail: str = ""
    output: str = ""


RunnerFn = Callable[[list[str], Path, dict[str, str]], CommandResult]
ToolFinderFn = Callable[[str], str | None]
DownloaderFn = Callable[[str, Path], None]


def find_tool(
    name: str,
    *,
    platform: str | None = None,
    env: Mapping[str, str] | None = None,
) -> str | None:
    """Locate a CLI executable via PATH, with Windows fallback for Flutter/Dart."""
    effective_env = env if env is not None else os.environ
    found = shutil.which(name, path=effective_env.get("PATH"))
    if found:
        return found

    effective_platform = platform if platform is not None else sys.platform
    if effective_platform == "win32" and name in ("flutter", "dart"):
        local_app_data = effective_env.get("LOCALAPPDATA", "").strip()
        if local_app_data:
            flutter_bin = Path(local_app_data) / "Programs" / "flutter" / "bin"
            for suffix in (".bat", ".exe"):
                candidate = flutter_bin / f"{name}{suffix}"
                if candidate.is_file():
                    return str(candidate)
    return None


def build_tool_env(
    tool_path: str | None = None,
    base_env: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Build quiet subprocess environment, ensuring Flutter bin dir is on PATH."""
    env = dict(base_env if base_env is not None else os.environ)
    env["BLINK_QUIET"] = "1"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["FLUTTER_SUPPRESS_ANALYTICS"] = "true"
    if tool_path:
        parent = str(Path(tool_path).resolve().parent)
        current_path = env.get("PATH", "")
        parts = current_path.split(os.pathsep) if current_path else []
        if not any(os.path.normcase(p) == os.path.normcase(parent) for p in parts):
            env["PATH"] = f"{parent}{os.pathsep}{current_path}" if current_path else parent
    return env


def default_runner(cmd: list[str], cwd: Path, env: dict[str, str]) -> CommandResult:
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd),
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdin=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0,
            check=False,
        )
        return CommandResult(proc.returncode, proc.stdout, proc.stderr)
    except OSError as exc:
        return CommandResult(127, "", str(exc))


def parse_flutter_version_output(output: str) -> str | None:
    """Extract Flutter version from JSON (`--version --machine`) or plain text output."""
    stripped = output.strip()
    if stripped.startswith("{"):
        try:
            data = json.loads(stripped)
            if isinstance(data, dict) and isinstance(data.get("frameworkVersion"), str):
                return data["frameworkVersion"].strip()
        except json.JSONDecodeError:
            pass
    match = FLUTTER_VERSION_TEXT_RE.search(output)
    if match:
        return match.group(1).strip()
    return None


def _summarize_failure(res: CommandResult) -> str:
    combined = (res.stderr.strip() or res.stdout.strip()).splitlines()
    if not combined:
        return f"exit code {res.returncode}"
    tail = " | ".join(line.strip() for line in combined[-6:] if line.strip())
    return f"exit code {res.returncode}: {tail[:400]}"


def _format_failure_output(res: CommandResult, max_lines: int = 60) -> str:
    parts = [text.strip() for text in (res.stdout, res.stderr) if text.strip()]
    if not parts:
        return ""
    lines = "\n".join(parts).splitlines()
    if len(lines) > max_lines:
        lines = [f"... ({len(lines) - max_lines} earlier line(s) omitted) ...", *lines[-max_lines:]]
    return "\n".join(lines)


def _has_package_config(root: Path, app_dir: Path) -> bool:
    return (root / ".dart_tool" / "package_config.json").is_file() or (
        app_dir / ".dart_tool" / "package_config.json"
    ).is_file()


def check_docs_step(root: Path, runner: RunnerFn) -> StepResult:
    t0 = time.monotonic()
    script = root / "scripts" / "check_docs.py"
    if not script.is_file():
        return StepResult("docs", "failed", time.monotonic() - t0, "missing scripts/check_docs.py")
    res = runner([sys.executable, "-B", str(script), "--root", str(root)], root, build_tool_env())
    if res.returncode != 0:
        return StepResult("docs", "failed", time.monotonic() - t0, _summarize_failure(res), _format_failure_output(res))
    return StepResult("docs", "passed", time.monotonic() - t0)


def check_git_diff_step(root: Path, runner: RunnerFn, tool_finder: ToolFinderFn) -> StepResult:
    t0 = time.monotonic()
    git = tool_finder("git")
    if not git:
        return StepResult("git-diff", "failed", time.monotonic() - t0, "git executable not found")
    env = build_tool_env(git)
    has_head = runner([git, "rev-parse", "--verify", "HEAD"], root, env)
    cmd = [git, "diff", "--check", "HEAD"] if has_head.returncode == 0 else [git, "diff", "--check"]
    res = runner(cmd, root, env)
    if res.returncode != 0:
        return StepResult("git-diff", "failed", time.monotonic() - t0, _summarize_failure(res), _format_failure_output(res))
    return StepResult("git-diff", "passed", time.monotonic() - t0)


def check_flutter_version_step(root: Path, runner: RunnerFn, tool_finder: ToolFinderFn) -> StepResult:
    t0 = time.monotonic()
    version_file = root / ".flutter-version"
    if not version_file.is_file():
        return StepResult("flutter-version", "failed", time.monotonic() - t0, "missing .flutter-version")
    expected = version_file.read_text(encoding="utf-8").strip()
    if not expected:
        return StepResult("flutter-version", "failed", time.monotonic() - t0, ".flutter-version is empty")

    flutter = tool_finder("flutter")
    if not flutter:
        return StepResult("flutter-version", "failed", time.monotonic() - t0, "flutter executable not found")

    res = runner([flutter, "--suppress-analytics", "--version"], root, build_tool_env(flutter))
    if res.returncode != 0:
        return StepResult("flutter-version", "failed", time.monotonic() - t0, _summarize_failure(res))

    installed = parse_flutter_version_output(res.stdout) or parse_flutter_version_output(res.stderr)
    if not installed:
        return StepResult(
            "flutter-version",
            "failed",
            time.monotonic() - t0,
            f"unable to parse version from flutter --version output: {res.stdout.strip()[:200]}",
        )
    if installed != expected:
        return StepResult(
            "flutter-version",
            "failed",
            time.monotonic() - t0,
            f".flutter-version expects {expected}, but flutter reports {installed}",
        )
    return StepResult("flutter-version", "passed", time.monotonic() - t0, f"Flutter {installed}")


def check_python_tests_step(root: Path, runner: RunnerFn) -> StepResult:
    t0 = time.monotonic()
    scripts_dir = root / "scripts"
    test_files = sorted(scripts_dir.glob("test_*.py")) if scripts_dir.is_dir() else []
    if not test_files:
        return StepResult("python-tests", "failed", time.monotonic() - t0, "no scripts/test_*.py files found")

    env = build_tool_env()
    for test_file in test_files:
        res = runner([sys.executable, "-B", str(test_file)], root, env)
        if res.returncode != 0:
            return StepResult(
                "python-tests",
                "failed",
                time.monotonic() - t0,
                f"{test_file.name}: {_summarize_failure(res)}",
                _format_failure_output(res),
            )
    names = ", ".join(p.name for p in test_files)
    return StepResult("python-tests", "passed", time.monotonic() - t0, f"{len(test_files)} suite(s): {names}")


def check_dart_format_step(root: Path, runner: RunnerFn, tool_finder: ToolFinderFn) -> StepResult:
    t0 = time.monotonic()
    dart = tool_finder("dart")
    if not dart:
        return StepResult("dart-format", "failed", time.monotonic() - t0, "dart executable not found")
    res = runner(
        [dart, "format", "--output=none", "--set-exit-if-changed", "."],
        root,
        build_tool_env(dart),
    )
    if res.returncode != 0:
        return StepResult("dart-format", "failed", time.monotonic() - t0, _summarize_failure(res), _format_failure_output(res))
    return StepResult("dart-format", "passed", time.monotonic() - t0)


def check_flutter_analyze_step(root: Path, runner: RunnerFn, tool_finder: ToolFinderFn) -> StepResult:
    t0 = time.monotonic()
    app_dir = root / "apps" / "blink_client"
    if not app_dir.is_dir():
        return StepResult("flutter-analyze", "failed", time.monotonic() - t0, "missing apps/blink_client")
    flutter = tool_finder("flutter")
    if not flutter:
        return StepResult("flutter-analyze", "failed", time.monotonic() - t0, "flutter executable not found")

    cmd = [flutter, "--suppress-analytics", "analyze"]
    if _has_package_config(root, app_dir):
        cmd.append("--no-pub")
    cmd.append("--fatal-infos")
    res = runner(cmd, app_dir, build_tool_env(flutter))
    if res.returncode != 0:
        return StepResult(
            "flutter-analyze",
            "failed",
            time.monotonic() - t0,
            _summarize_failure(res),
            _format_failure_output(res),
        )
    return StepResult("flutter-analyze", "passed", time.monotonic() - t0)


def check_flutter_test_step(root: Path, runner: RunnerFn, tool_finder: ToolFinderFn) -> StepResult:
    t0 = time.monotonic()
    app_dir = root / "apps" / "blink_client"
    if not app_dir.is_dir():
        return StepResult("flutter-test", "failed", time.monotonic() - t0, "missing apps/blink_client")
    flutter = tool_finder("flutter")
    if not flutter:
        return StepResult("flutter-test", "failed", time.monotonic() - t0, "flutter executable not found")

    cmd = [flutter, "--suppress-analytics", "test"]
    if _has_package_config(root, app_dir):
        cmd.append("--no-pub")
    res = runner(cmd, app_dir, build_tool_env(flutter))
    if res.returncode != 0:
        return StepResult(
            "flutter-test",
            "failed",
            time.monotonic() - t0,
            _summarize_failure(res),
            _format_failure_output(res),
        )
    return StepResult("flutter-test", "passed", time.monotonic() - t0)


def _run_python_script_step(name: str, script_rel: str, args: list[str], root: Path, runner: RunnerFn) -> StepResult:
    t0 = time.monotonic()
    script = root / script_rel
    if not script.is_file():
        return StepResult(name, "failed", time.monotonic() - t0, f"missing {script_rel}")
    res = runner([sys.executable, "-B", str(script), *args], root, build_tool_env())
    if res.returncode != 0:
        return StepResult(name, "failed", time.monotonic() - t0, _summarize_failure(res), _format_failure_output(res))
    return StepResult(name, "passed", time.monotonic() - t0)


def run_gate(
    root: Path,
    *,
    mode: str = "full",
    platform: str | None = None,
    runner: RunnerFn | None = None,
    tool_finder: ToolFinderFn | None = None,
) -> tuple[int, list[StepResult]]:
    """Run quick, ci, or full quality gate and return (exit_code, step_results)."""
    root = root.resolve()
    effective_platform = platform if platform is not None else sys.platform
    exec_cmd = runner if runner is not None else default_runner
    locate = tool_finder if tool_finder is not None else (lambda name: find_tool(name, platform=effective_platform))

    results: list[StepResult] = [
        check_docs_step(root, exec_cmd),
        check_git_diff_step(root, exec_cmd, locate),
        check_flutter_version_step(root, exec_cmd, locate),
        check_python_tests_step(root, exec_cmd),
        check_dart_format_step(root, exec_cmd, locate),
        check_flutter_analyze_step(root, exec_cmd, locate),
        check_flutter_test_step(root, exec_cmd, locate),
    ]

    if mode == "full":
        results.append(
            _run_python_script_step(
                "deps-audit",
                "scripts/deps.py",
                ["--audit", "--root", str(root)],
                root,
                exec_cmd,
            )
        )
        win_steps = (
            ("package-dev", ["--channel", "blink-dev"]),
            ("package-release", ["--channel", "blink", "--version", "0.1.0"]),
            ("package-rehearsal", ["--rehearsal"]),
        )
        if effective_platform != "win32":
            for step_name, _ in win_steps:
                results.append(
                    StepResult(
                        step_name,
                        "not-run",
                        0.0,
                        f"Windows-only packaging/rehearsal step skipped on {effective_platform}",
                    )
                )
        else:
            earlier_failed = any(step.status == "failed" for step in results)
            for step_name, pkg_args in win_steps:
                if earlier_failed:
                    results.append(
                        StepResult(step_name, "not-run", 0.0, "skipped after earlier gate failure")
                    )
                    continue
                step_res = _run_python_script_step(
                    step_name, "scripts/package.py", pkg_args, root, exec_cmd
                )
                results.append(step_res)
                if step_res.status == "failed":
                    earlier_failed = True

    any_failed = any(step.status == "failed" for step in results)
    return (1 if any_failed else 0), results


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(DOWNLOAD_CHUNK_BYTES)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest().lower()


def verify_archive_sha256(archive_path: Path, expected_sha256: str) -> tuple[bool, str]:
    actual = sha256_file(archive_path)
    return actual == expected_sha256.strip().lower(), actual


def load_linux_flutter_spec(root: Path) -> tuple[str, str, str]:
    """Read and validate pinned Linux Flutter archive URL and SHA-256 from repo metadata."""
    version_file = root / ".flutter-version"
    checksums_file = root / "scripts" / "flutter-checksums.json"
    if not version_file.is_file():
        raise ValueError("missing .flutter-version")
    if not checksums_file.is_file():
        raise ValueError("missing scripts/flutter-checksums.json")

    pinned_version = version_file.read_text(encoding="utf-8").strip()
    if not pinned_version:
        raise ValueError(".flutter-version is empty")

    data = json.loads(checksums_file.read_text(encoding="utf-8"))
    checksum_version = str(data.get("version", "")).strip()
    if checksum_version != pinned_version:
        raise ValueError(
            f"flutter-checksums.json version ({checksum_version!r}) != .flutter-version ({pinned_version!r})"
        )

    base_url = str(data.get("baseUrl", "")).strip().rstrip("/")
    if base_url != OFFICIAL_FLUTTER_BASE_URL:
        raise ValueError(
            f"flutter-checksums.json baseUrl ({base_url!r}) must equal {OFFICIAL_FLUTTER_BASE_URL!r}"
        )

    linux = data.get("archives", {}).get("linux")
    if not isinstance(linux, dict):
        raise ValueError("flutter-checksums.json missing archives.linux entry")

    archive_rel = str(linux.get("archive", "")).strip().lstrip("/")
    expected_sha = str(linux.get("sha256", "")).strip().lower()
    if not archive_rel or ".." in Path(archive_rel).parts:
        raise ValueError(f"invalid Linux Flutter archive path: {archive_rel!r}")
    if not SHA64_RE.fullmatch(expected_sha):
        raise ValueError(f"invalid Linux Flutter SHA-256 digest: {expected_sha!r}")

    download_url = f"{base_url}/{archive_rel}"
    return pinned_version, download_url, expected_sha


def default_download_file(url: str, dest_path: Path) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    max_attempts = 3
    for attempt in range(1, max_attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=300) as resp, dest_path.open("wb") as out:
                while True:
                    chunk = resp.read(DOWNLOAD_CHUNK_BYTES)
                    if not chunk:
                        break
                    out.write(chunk)
            return
        except (urllib.error.URLError, TimeoutError, OSError):
            if attempt >= max_attempts:
                raise
            time.sleep(1.0 * attempt)


def _extract_tar_xz(archive_path: Path, dest_dir: Path) -> None:
    if sys.platform != "win32" and shutil.which("tar"):
        proc = subprocess.run(
            ["tar", "-xJf", str(archive_path), "-C", str(dest_dir)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdin=subprocess.DEVNULL,
            check=False,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"tar extraction failed: {proc.stderr.strip() or proc.stdout.strip()}")
        return
    with tarfile.open(archive_path, mode="r:xz") as tf:
        tf.extractall(dest_dir, filter="tar")


def install_linux_flutter(
    root: Path,
    dest_dir: Path,
    *,
    downloader: DownloaderFn | None = None,
    extract: bool = True,
) -> int:
    """Download pinned Linux Flutter archive, verify SHA-256 strictly, and extract."""
    root = root.resolve()
    dest_dir = dest_dir.resolve()
    try:
        pinned_version, download_url, expected_sha = load_linux_flutter_spec(root)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FAIL: invalid Flutter checksum metadata: {exc}", file=sys.stderr)
        return 1

    dest_dir.mkdir(parents=True, exist_ok=True)
    tmp_archive = dest_dir / f".flutter-linux-{pinned_version}.tar.xz.part"
    fetch = downloader if downloader is not None else default_download_file

    try:
        fetch(download_url, tmp_archive)
        ok, actual_sha = verify_archive_sha256(tmp_archive, expected_sha)
        if not ok:
            print(
                f"FAIL: Linux Flutter archive SHA-256 mismatch for {pinned_version}: "
                f"expected {expected_sha}, got {actual_sha}",
                file=sys.stderr,
            )
            return 1

        if extract:
            flutter_dir = dest_dir / "flutter"
            if flutter_dir.exists():
                shutil.rmtree(flutter_dir)
            _extract_tar_xz(tmp_archive, dest_dir)
            flutter_bin = flutter_dir / "bin" / "flutter"
            if not flutter_bin.is_file():
                print(
                    "FAIL: extracted Linux Flutter archive did not contain flutter/bin/flutter",
                    file=sys.stderr,
                )
                return 1
    except (urllib.error.URLError, OSError, RuntimeError, tarfile.TarError) as exc:
        print(f"FAIL: Linux Flutter installation error: {exc}", file=sys.stderr)
        return 1
    finally:
        if tmp_archive.exists():
            try:
                tmp_archive.unlink()
            except OSError:
                pass

    print(f"PASS: verified Linux Flutter {pinned_version} archive (SHA-256 {expected_sha})")
    return 0


def print_gate_summary(mode: str, results: list[StepResult]) -> None:
    print(f"BLINK quality gate ({mode}):")
    for step in results:
        suffix = f" - {step.detail}" if step.detail else ""
        print(f"  [{step.status.upper():7s}] {step.name:18s} ({step.duration_seconds:.2f}s){suffix}")
    failed = [s for s in results if s.status == "failed"]
    not_run = [s for s in results if s.status == "not-run"]
    if failed:
        for step in failed:
            if step.output:
                print(f"--- {step.name} output ---\n{step.output}", file=sys.stderr)
        print(
            f"FAIL: {len(failed)} step(s) failed ({', '.join(s.name for s in failed)}).",
            file=sys.stderr,
        )
    else:
        note = f" ({len(not_run)} not-run)" if not_run else ""
        print(f"PASS: quality gate ({mode}) passed{note}.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument(
        "--quick",
        action="store_true",
        help="Run quick gate (docs, git diff, flutter version, Python tests, format, analyze, flutter test).",
    )
    mode_group.add_argument(
        "--ci",
        action="store_true",
        help="Run Linux CI gate subset.",
    )
    mode_group.add_argument(
        "--install-linux-flutter",
        type=Path,
        default=None,
        metavar="DEST_DIR",
        help="Download and SHA-256 verify the pinned official Linux Flutter archive into DEST_DIR.",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Repository root directory.",
    )
    args = parser.parse_args(argv)

    if args.install_linux_flutter is not None:
        return install_linux_flutter(args.root, args.install_linux_flutter)

    mode = "quick" if args.quick else ("ci" if args.ci else "full")
    exit_code, results = run_gate(args.root, mode=mode)
    print_gate_summary(mode, results)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
