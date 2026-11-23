"""Zero-dependency dependency inventory, 7-day cooldown, OSV, Flutter & Action SHA audit for BLINK.

Run from any directory:
    python -B scripts/deps.py
    python -B scripts/deps.py --audit

Uses Python 3.12 standard library only. Atomically writes artifacts/audit/deps.json.
On network failure, records status="not-run" and exits non-zero (never fakes a pass).
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
import fnmatch
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True

FLUTTER_RELEASES_BASE = "https://storage.googleapis.com/flutter_infra_release/releases"
PUB_API_BASE = "https://pub.dev/api/packages"
OSV_BATCH_URL = "https://api.osv.dev/v1/querybatch"
OSV_VULN_URL = "https://api.osv.dev/v1/vulns"
GITHUB_API_BASE = "https://api.github.com"

DEFAULT_COOLDOWN_DAYS = 7
OSV_BATCH_SIZE = 500
HTTP_TIMEOUT_SECONDS = 20
USER_AGENT = "blink-deps-audit/1"

SHA40_RE = re.compile(r"^[0-9a-f]{40}$")
SHA64_RE = re.compile(r"^[0-9a-f]{64}$")
SEMVER_RE = re.compile(r"^v?(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$")
ACTION_USES_RE = re.compile(
    r"^\s*(?:-\s*)?uses:\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)?)@([^\s#]+)(?:\s*#\s*(\S+))?"
)


class NetworkError(RuntimeError):
    """Raised when an upstream API cannot be reached or is rate-limited."""


class HttpStatusError(RuntimeError):
    """Raised on deterministic non-transient HTTP 4xx responses."""

    def __init__(self, code: int, url: str, body: str = "") -> None:
        super().__init__(f"HTTP {code} for {url}")
        self.code = code
        self.url = url
        self.body = body


@dataclass(frozen=True, order=True)
class SemVer:
    major: int
    minor: int
    patch: int
    prerelease: str | None = None

    @property
    def is_stable(self) -> bool:
        return self.prerelease is None


@dataclass(frozen=True)
class DirectDependency:
    name: str
    section: str
    pubspec: str
    constraint: str
    source: str


@dataclass(frozen=True)
class LockedPackage:
    name: str
    dependency: str
    source: str
    version: str
    url: str = ""


@dataclass(frozen=True)
class ActionRef:
    workflow: str
    line: int
    action: str
    repo: str
    pinned_ref: str
    comment_tag: str | None


def parse_semver(raw: str) -> SemVer | None:
    match = SEMVER_RE.match(raw.strip())
    if not match:
        return None
    major = int(match.group(1))
    minor = int(match.group(2))
    patch = int(match.group(3) or 0)
    prerelease = match.group(4)
    return SemVer(major=major, minor=minor, patch=patch, prerelease=prerelease)


def compare_stable_versions(left: str, right: str) -> int:
    """Compare two version strings numerically; returns -1, 0, or 1."""
    sv_l = parse_semver(left)
    sv_r = parse_semver(right)
    if sv_l is not None and sv_r is not None:
        key_l = (sv_l.major, sv_l.minor, sv_l.patch)
        key_r = (sv_r.major, sv_r.minor, sv_r.patch)
        if key_l < key_r:
            return -1
        if key_l > key_r:
            return 1
        return 0
    if left < right:
        return -1
    if left > right:
        return 1
    return 0


def parse_iso_utc(raw: str) -> datetime:
    text = raw.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    dt = datetime.fromisoformat(text)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def format_iso_utc(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def strip_yaml_comment(line: str) -> str:
    in_single = False
    in_double = False
    for idx, ch in enumerate(line):
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            return line[:idx]
    return line


def unquote_yaml_scalar(value: str) -> str:
    cleaned = value.strip()
    if len(cleaned) >= 2 and cleaned[0] == cleaned[-1] and cleaned[0] in ("'", '"'):
        return cleaned[1:-1]
    return cleaned


def parse_pubspec(pubspec_path: Path, rel_pubspec: str) -> tuple[list[str], list[DirectDependency]]:
    """Parse workspace entries and direct dependencies from a Dart/Flutter pubspec.yaml."""
    lines = pubspec_path.read_text(encoding="utf-8").splitlines()
    workspace_members: list[str] = []
    deps: list[DirectDependency] = []

    section: str | None = None
    dep_indent: int | None = None
    current_dep_name: str | None = None
    current_dep_section: str | None = None
    current_dep_source: str = "hosted"
    current_dep_constraint: str = ""

    def flush_dep() -> None:
        nonlocal current_dep_name, current_dep_section, current_dep_source, current_dep_constraint
        if current_dep_name is not None and current_dep_section is not None:
            deps.append(
                DirectDependency(
                    name=current_dep_name,
                    section=current_dep_section,
                    pubspec=rel_pubspec,
                    constraint=current_dep_constraint,
                    source=current_dep_source,
                )
            )
        current_dep_name = None
        current_dep_section = None
        current_dep_source = "hosted"
        current_dep_constraint = ""

    for raw_line in lines:
        cleaned = strip_yaml_comment(raw_line).rstrip()
        if not cleaned.strip():
            continue
        indent = len(cleaned) - len(cleaned.lstrip(" "))
        stripped = cleaned.strip()

        if indent == 0:
            flush_dep()
            dep_indent = None
            if stripped.endswith(":"):
                key = stripped[:-1].strip()
                section = key if key in ("workspace", "dependencies", "dev_dependencies") else None
            else:
                section = None
            continue

        if section == "workspace":
            if stripped.startswith("- "):
                member = unquote_yaml_scalar(stripped[2:])
                if member:
                    workspace_members.append(member)
            continue

        if section in ("dependencies", "dev_dependencies"):
            if dep_indent is None:
                dep_indent = indent
            if indent == dep_indent and ":" in stripped:
                flush_dep()
                key, _, rest = stripped.partition(":")
                pkg_name = unquote_yaml_scalar(key)
                value = unquote_yaml_scalar(rest)
                current_dep_name = pkg_name
                current_dep_section = section
                if value:
                    current_dep_source = "hosted"
                    current_dep_constraint = value
                else:
                    current_dep_source = "hosted"
                    current_dep_constraint = ""
            elif indent > dep_indent and current_dep_name is not None and ":" in stripped:
                sub_key, _, sub_rest = stripped.partition(":")
                sub_key = sub_key.strip()
                sub_val = unquote_yaml_scalar(sub_rest)
                if sub_key == "sdk":
                    current_dep_source = "sdk"
                    current_dep_constraint = f"sdk:{sub_val}"
                elif sub_key == "path":
                    current_dep_source = "path"
                    current_dep_constraint = f"path:{sub_val}"
                elif sub_key == "git":
                    current_dep_source = "git"
                    current_dep_constraint = "git"
                elif sub_key == "version" and sub_val:
                    current_dep_constraint = sub_val

    flush_dep()
    return workspace_members, deps


def parse_pubspec_lock(lock_path: Path) -> dict[str, LockedPackage]:
    """Parse packages from a Dart/Flutter pubspec.lock file."""
    lines = lock_path.read_text(encoding="utf-8").splitlines()
    packages: dict[str, LockedPackage] = {}
    in_packages = False
    in_description = False
    pkg_indent: int | None = None
    field_indent: int | None = None
    cur_name: str | None = None
    cur_fields: dict[str, str] = {}

    def flush_pkg() -> None:
        nonlocal cur_name, cur_fields
        if cur_name is not None:
            packages[cur_name] = LockedPackage(
                name=cur_name,
                dependency=cur_fields.get("dependency", ""),
                source=cur_fields.get("source", ""),
                version=cur_fields.get("version", ""),
                url=cur_fields.get("url", ""),
            )
        cur_name = None
        cur_fields = {}

    for raw_line in lines:
        cleaned = strip_yaml_comment(raw_line).rstrip()
        if not cleaned.strip():
            continue
        indent = len(cleaned) - len(cleaned.lstrip(" "))
        stripped = cleaned.strip()

        if indent == 0:
            flush_pkg()
            in_packages = stripped == "packages:"
            in_description = False
            pkg_indent = None
            field_indent = None
            continue

        if not in_packages:
            continue

        if pkg_indent is None:
            pkg_indent = indent

        if indent == pkg_indent and stripped.endswith(":"):
            flush_pkg()
            cur_name = unquote_yaml_scalar(stripped[:-1])
            in_description = False
            field_indent = None
            continue

        if cur_name is None:
            continue

        if field_indent is None and indent > pkg_indent:
            field_indent = indent

        if field_indent is not None and indent == field_indent and ":" in stripped:
            key, _, rest = stripped.partition(":")
            key = key.strip()
            val = unquote_yaml_scalar(rest)
            in_description = key == "description" and not val
            if key in ("dependency", "source", "version"):
                cur_fields[key] = val
        elif in_description and field_indent is not None and indent > field_indent and ":" in stripped:
            key, _, rest = stripped.partition(":")
            if key.strip() == "url":
                cur_fields["url"] = unquote_yaml_scalar(rest)

    flush_pkg()
    return packages


def parse_workflow_actions(workflow_path: Path, rel_workflow: str) -> list[ActionRef]:
    """Extract GitHub Action uses: references from a workflow YAML file."""
    refs: list[ActionRef] = []
    for line_no, line in enumerate(workflow_path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        match = ACTION_USES_RE.match(line)
        if not match:
            continue
        action_full = match.group(1).strip()
        pinned_ref = match.group(2).strip()
        comment_tag = match.group(3).strip() if match.group(3) else None
        if action_full.startswith("./") or action_full.startswith("docker://"):
            continue
        parts = action_full.split("/")
        repo = "/".join(parts[:2])
        refs.append(
            ActionRef(
                workflow=rel_workflow,
                line=line_no,
                action=action_full,
                repo=repo,
                pinned_ref=pinned_ref,
                comment_tag=comment_tag,
            )
        )
    return refs


def load_actions_policy(policy_path: Path) -> tuple[list[str] | None, bool]:
    if not policy_path.is_file():
        return None, True
    data = json.loads(policy_path.read_text(encoding="utf-8"))
    selected = data.get("selectedActions", {})
    patterns = selected.get("patterns_allowed")
    permissions = data.get("permissions", {})
    sha_required = bool(permissions.get("sha_pinning_required", True))
    return (list(patterns) if isinstance(patterns, list) else None), sha_required


def load_and_validate_exceptions(path: Path, today: date) -> tuple[list[dict[str, str]], list[str]]:
    """Validate scripts/deps-exceptions.json entries and reject expired reviewBy dates."""
    errors: list[str] = []
    valid: list[dict[str, str]] = []
    if not path.is_file():
        return [], [f"missing exceptions file: {path.name}"]
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [], [f"invalid exceptions JSON ({path.name}): {exc}"]

    if not isinstance(raw, dict) or not isinstance(raw.get("exceptions"), list):
        return [], [f"{path.name}: top-level JSON must be an object with an 'exceptions' list"]

    for idx, entry in enumerate(raw["exceptions"]):
        prefix = f"{path.name}[{idx}]"
        if not isinstance(entry, dict):
            errors.append(f"{prefix}: exception entry must be an object")
            continue
        missing = [
            field
            for field in ("id", "package", "reason", "reviewBy")
            if not isinstance(entry.get(field), str) or not entry[field].strip()
        ]
        if missing:
            errors.append(f"{prefix}: missing required non-empty field(s): {', '.join(missing)}")
            continue

        review_raw = entry["reviewBy"].strip()
        if len(review_raw) != 10:
            errors.append(f"{prefix}: reviewBy must use ISO YYYY-MM-DD format (got {review_raw!r})")
            continue
        try:
            review_date = date.fromisoformat(review_raw)
        except ValueError:
            errors.append(f"{prefix}: invalid ISO reviewBy date: {review_raw!r}")
            continue

        if review_date < today:
            errors.append(
                f"{prefix}: exception {entry['id']} for {entry['package']} expired on "
                f"{review_raw} (today {today.isoformat()})"
            )
            continue

        valid.append(
            {
                "id": entry["id"].strip(),
                "package": entry["package"].strip(),
                "reason": entry["reason"].strip(),
                "reviewBy": review_raw,
            }
        )

    return valid, errors


def atomic_write_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(f"{path.name}.blink-tmp")
    encoded = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
    with tmp_path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(encoded)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp_path, path)


def _probe_gh_auth_token() -> str | None:
    gh = shutil.which("gh")
    if not gh:
        return None
    try:
        proc = subprocess.run(
            [gh, "auth", "token"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=5,
            stdin=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    token = proc.stdout.strip()
    return token or None


class UrllibHttpClient:
    """Minimal Python stdlib JSON HTTP client with GitHub rate-limit awareness."""

    def __init__(self, timeout: int = HTTP_TIMEOUT_SECONDS) -> None:
        self.timeout = timeout
        self._gh_token_checked = False
        self._gh_token: str | None = (
            os.environ.get("GITHUB_TOKEN", "").strip()
            or os.environ.get("GH_TOKEN", "").strip()
            or None
        )

    def _github_headers(self, extra: dict[str, str] | None = None, *, token: str | None = None) -> dict[str, str]:
        headers = {
            "Accept": "application/vnd.github+json",
            "User-Agent": USER_AGENT,
        }
        if extra:
            headers.update(extra)
        effective_token = token if token is not None else self._gh_token
        if effective_token:
            headers["Authorization"] = f"Bearer {effective_token}"
        return headers

    def _request_json(
        self,
        url: str,
        *,
        method: str = "GET",
        payload: dict[str, object] | None = None,
        headers: dict[str, str] | None = None,
    ) -> object:
        req_headers = {"User-Agent": USER_AGENT}
        if headers:
            req_headers.update(headers)
        data_bytes: bytes | None = None
        if payload is not None:
            data_bytes = json.dumps(payload).encode("utf-8")
            req_headers.setdefault("Content-Type", "application/json")

        req = urllib.request.Request(url, data=data_bytes, headers=req_headers, method=method)
        max_attempts = 3
        for attempt in range(1, max_attempts + 1):
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    raw = resp.read().decode("utf-8")
                    return json.loads(raw)
            except urllib.error.HTTPError as exc:
                body = ""
                try:
                    body = exc.read().decode("utf-8", errors="replace")[:500]
                except OSError:
                    pass
                remaining = exc.headers.get("X-RateLimit-Remaining", "") if exc.headers else ""
                is_rate_limit = exc.code == 429 or (
                    exc.code == 403 and (remaining == "0" or "rate limit" in body.lower())
                )
                if is_rate_limit:
                    raise NetworkError(f"rate-limited (HTTP {exc.code}) for {url}") from exc
                if exc.code >= 500:
                    if attempt < max_attempts:
                        time.sleep(0.5 * attempt)
                        continue
                    raise NetworkError(f"upstream server error (HTTP {exc.code}) for {url}") from exc
                raise HttpStatusError(exc.code, url, body) from exc
            except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
                if attempt < max_attempts:
                    time.sleep(0.5 * attempt)
                    continue
                raise NetworkError(f"network error fetching {url}: {exc}") from exc
        raise NetworkError(f"exhausted retries fetching {url}")

    def get_json(self, url: str, headers: dict[str, str] | None = None) -> object:
        is_github = url.startswith(GITHUB_API_BASE)
        if not is_github:
            return self._request_json(url, method="GET", headers=headers)

        try:
            return self._request_json(url, method="GET", headers=self._github_headers(headers))
        except NetworkError as first_err:
            if "rate-limited" in str(first_err) and not self._gh_token and not self._gh_token_checked:
                self._gh_token_checked = True
                token = _probe_gh_auth_token()
                if token:
                    self._gh_token = token
                    return self._request_json(
                        url, method="GET", headers=self._github_headers(headers, token=token)
                    )
            raise

    def post_json(
        self,
        url: str,
        payload: dict[str, object],
        headers: dict[str, str] | None = None,
    ) -> object:
        return self._request_json(url, method="POST", payload=payload, headers=headers)


def audit_flutter(
    root: Path,
    client: object,
    now_utc: datetime,
    cooldown_days: int,
) -> tuple[dict[str, object], list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []

    version_file = root / ".flutter-version"
    checksums_file = root / "scripts" / "flutter-checksums.json"

    if not version_file.is_file():
        return {"ok": False}, ["missing .flutter-version"], warnings
    pinned_version = version_file.read_text(encoding="utf-8").strip()
    if not pinned_version:
        return {"ok": False}, [".flutter-version is empty"], warnings

    if not checksums_file.is_file():
        return {"pinnedVersion": pinned_version, "ok": False}, ["missing scripts/flutter-checksums.json"], warnings

    try:
        checksums_data = json.loads(checksums_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return {"pinnedVersion": pinned_version, "ok": False}, [f"invalid scripts/flutter-checksums.json: {exc}"], warnings

    checksum_version = str(checksums_data.get("version", "")).strip()
    base_url = str(checksums_data.get("baseUrl", "")).strip().rstrip("/")
    archives = checksums_data.get("archives", {})

    if checksum_version != pinned_version:
        errors.append(
            f"flutter-checksums.json version ({checksum_version!r}) != .flutter-version ({pinned_version!r})"
        )
    if base_url != FLUTTER_RELEASES_BASE:
        errors.append(
            f"flutter-checksums.json baseUrl ({base_url!r}) must equal {FLUTTER_RELEASES_BASE!r}"
        )

    platform_results: dict[str, dict[str, object]] = {}
    latest_stable_version: str | None = None
    latest_stable_published: datetime | None = None

    for platform in ("windows", "linux"):
        manifest_url = f"{FLUTTER_RELEASES_BASE}/releases_{platform}.json"
        manifest = client.get_json(manifest_url)
        if not isinstance(manifest, dict) or not isinstance(manifest.get("releases"), list):
            errors.append(f"invalid Flutter release manifest format for {platform}")
            continue

        releases = manifest["releases"]
        expected = archives.get(platform) if isinstance(archives, dict) else None
        if not isinstance(expected, dict):
            errors.append(f"flutter-checksums.json missing archives.{platform}")
            continue

        expected_arch = str(expected.get("arch", "x64")).strip()
        expected_archive = str(expected.get("archive", "")).strip()
        expected_sha = str(expected.get("sha256", "")).strip().lower()
        if not SHA64_RE.fullmatch(expected_sha):
            errors.append(f"flutter-checksums.json archives.{platform}.sha256 is not a 64-char hex digest")

        matched_entry = None
        for rel in releases:
            if not isinstance(rel, dict):
                continue
            if rel.get("channel") != "stable" or rel.get("version") != pinned_version:
                continue
            rel_arch = rel.get("dart_sdk_arch")
            if rel_arch and rel_arch != expected_arch:
                continue
            matched_entry = rel
            break

        if matched_entry is None:
            errors.append(
                f"Flutter {pinned_version} ({platform}/{expected_arch}) not found in official release manifest"
            )
            platform_results[platform] = {
                "expectedArchive": expected_archive,
                "expectedSha256": expected_sha,
                "manifestArchive": None,
                "manifestSha256": None,
                "ok": False,
            }
        else:
            manifest_archive = str(matched_entry.get("archive", "")).strip()
            manifest_sha = str(matched_entry.get("sha256", "")).strip().lower()
            archive_ok = manifest_archive == expected_archive
            sha_ok = manifest_sha == expected_sha
            if not archive_ok:
                errors.append(
                    f"Flutter {platform} archive mismatch: checksums has {expected_archive!r}, "
                    f"manifest has {manifest_archive!r}"
                )
            if not sha_ok:
                errors.append(
                    f"Flutter {platform} SHA-256 mismatch: checksums has {expected_sha}, "
                    f"manifest has {manifest_sha}"
                )
            platform_results[platform] = {
                "expectedArchive": expected_archive,
                "expectedSha256": expected_sha,
                "manifestArchive": manifest_archive,
                "manifestSha256": manifest_sha,
                "ok": archive_ok and sha_ok,
            }

        cur_hash = manifest.get("current_release", {}).get("stable")
        cur_entry = next(
            (r for r in releases if isinstance(r, dict) and r.get("hash") == cur_hash),
            None,
        )
        if cur_entry and cur_entry.get("version") and cur_entry.get("release_date"):
            cand_ver = str(cur_entry["version"]).strip()
            cand_dt = parse_iso_utc(str(cur_entry["release_date"]))
            if latest_stable_version is None or compare_stable_versions(cand_ver, latest_stable_version) > 0:
                latest_stable_version = cand_ver
                latest_stable_published = cand_dt
            elif cand_ver == latest_stable_version and (
                latest_stable_published is None or cand_dt > latest_stable_published
            ):
                latest_stable_published = cand_dt

    cooldown_status = "unknown"
    age_days: float | None = None
    if latest_stable_version is not None and latest_stable_published is not None:
        age_days = round((now_utc - latest_stable_published).total_seconds() / 86400.0, 2)
        if compare_stable_versions(pinned_version, latest_stable_version) >= 0:
            cooldown_status = "up-to-date"
        elif now_utc - latest_stable_published >= timedelta(days=cooldown_days):
            cooldown_status = "upgrade-eligible"
            warnings.append(
                f"Flutter {latest_stable_version} released {format_iso_utc(latest_stable_published)} "
                f"({age_days:.1f}d >= {cooldown_days}d cooldown; pinned {pinned_version})"
            )
        else:
            cooldown_status = "cooling-down"

    info: dict[str, object] = {
        "pinnedVersion": pinned_version,
        "checksumFileVersion": checksum_version,
        "latestStable": latest_stable_version,
        "latestStablePublishedUtc": format_iso_utc(latest_stable_published) if latest_stable_published else None,
        "latestStableAgeDays": age_days,
        "cooldownStatus": cooldown_status,
        "checksums": platform_results,
    }
    return info, errors, warnings


def audit_direct_dependencies(
    root: Path,
    locked: dict[str, LockedPackage],
    client: object,
    now_utc: datetime,
    cooldown_days: int,
) -> tuple[list[dict[str, object]], list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    results: list[dict[str, object]] = []

    root_pubspec = root / "pubspec.yaml"
    if not root_pubspec.is_file():
        return results, ["missing root pubspec.yaml"], warnings

    workspace_members, direct_deps = parse_pubspec(root_pubspec, "pubspec.yaml")
    seen_pubspecs = {"pubspec.yaml"}
    candidate_members = list(workspace_members)
    if "apps/blink_client" not in candidate_members and (root / "apps" / "blink_client" / "pubspec.yaml").is_file():
        candidate_members.append("apps/blink_client")

    for member in candidate_members:
        rel_pubspec = f"{member.strip().rstrip('/')}/pubspec.yaml"
        if rel_pubspec in seen_pubspecs:
            continue
        seen_pubspecs.add(rel_pubspec)
        member_path = root / rel_pubspec
        if not member_path.is_file():
            errors.append(f"workspace member pubspec not found: {rel_pubspec}")
            continue
        _, member_deps = parse_pubspec(member_path, rel_pubspec)
        direct_deps.extend(member_deps)

    hosted_direct = [d for d in direct_deps if d.source == "hosted"]
    pub_cache: dict[str, dict[str, object]] = {}

    for dep in sorted(hosted_direct, key=lambda d: (d.pubspec, d.section, d.name)):
        locked_pkg = locked.get(dep.name)
        if locked_pkg is None:
            errors.append(f"direct dependency {dep.name} ({dep.pubspec}) not found in pubspec.lock")
            continue

        if dep.name not in pub_cache:
            url = f"{PUB_API_BASE}/{urllib.parse.quote(dep.name, safe='')}"
            try:
                data = client.get_json(url)
            except HttpStatusError as exc:
                errors.append(f"pub.dev lookup failed for {dep.name}: {exc}")
                continue
            if not isinstance(data, dict):
                errors.append(f"unexpected pub.dev payload for {dep.name}")
                continue
            pub_cache[dep.name] = data

        pkg_data = pub_cache[dep.name]
        raw_versions = pkg_data.get("versions")
        if not isinstance(raw_versions, list) or not raw_versions:
            latest_obj = pkg_data.get("latest")
            raw_versions = [latest_obj] if isinstance(latest_obj, dict) else []

        stable_releases: list[tuple[SemVer, str, datetime]] = []
        for entry in raw_versions:
            if not isinstance(entry, dict):
                continue
            if entry.get("retracted"):
                continue
            ver_str = str(entry.get("version", "")).strip()
            pub_raw = str(entry.get("published", "")).strip()
            if not ver_str or not pub_raw:
                continue
            sv = parse_semver(ver_str)
            if sv is None or not sv.is_stable:
                continue
            stable_releases.append((sv, ver_str, parse_iso_utc(pub_raw)))

        if not stable_releases:
            errors.append(f"no stable release metadata returned by pub.dev for {dep.name}")
            continue

        stable_releases.sort(key=lambda item: (item[0].major, item[0].minor, item[0].patch))
        _, latest_ver, latest_dt = stable_releases[-1]
        locked_dt = next(
            (dt for _sv, ver, dt in stable_releases if ver == locked_pkg.version),
            None,
        )
        cutoff = now_utc - timedelta(days=cooldown_days)
        eligible_releases = [item for item in stable_releases if item[2] <= cutoff]
        latest_eligible_ver = eligible_releases[-1][1] if eligible_releases else None
        latest_eligible_dt = eligible_releases[-1][2] if eligible_releases else None

        age_days = round((now_utc - latest_dt).total_seconds() / 86400.0, 2)
        if compare_stable_versions(locked_pkg.version, latest_ver) >= 0:
            cooldown_status = "up-to-date"
        elif latest_eligible_ver is not None and compare_stable_versions(latest_eligible_ver, locked_pkg.version) > 0:
            cooldown_status = "upgrade-eligible"
            elig_age = round((now_utc - latest_eligible_dt).total_seconds() / 86400.0, 1) if latest_eligible_dt else 0.0
            warnings.append(
                f"{dep.name}: locked {locked_pkg.version}, eligible upgrade {latest_eligible_ver} "
                f"({elig_age:.1f}d >= {cooldown_days}d cooldown; latest stable {latest_ver})"
            )
        else:
            cooldown_status = "cooling-down"

        results.append(
            {
                "name": dep.name,
                "section": dep.section,
                "pubspec": dep.pubspec,
                "constraint": dep.constraint,
                "lockedVersion": locked_pkg.version,
                "lockedVersionPublishedUtc": format_iso_utc(locked_dt) if locked_dt else None,
                "latestStable": latest_ver,
                "latestStablePublishedUtc": format_iso_utc(latest_dt),
                "latestStableAgeDays": age_days,
                "latestEligible": latest_eligible_ver,
                "cooldownStatus": cooldown_status,
            }
        )

    return results, errors, warnings


def audit_osv(
    root: Path,
    locked: dict[str, LockedPackage],
    client: object,
    today: date,
) -> tuple[dict[str, object], list[str]]:
    errors: list[str] = []
    exceptions_path = root / "scripts" / "deps-exceptions.json"
    valid_exceptions, exc_errors = load_and_validate_exceptions(exceptions_path, today)
    errors.extend(exc_errors)

    hosted_pkgs = sorted(
        (pkg for pkg in locked.values() if pkg.source == "hosted" and pkg.version),
        key=lambda p: p.name,
    )

    findings: list[dict[str, object]] = []
    vuln_detail_cache: dict[str, dict[str, object]] = {}

    for start in range(0, len(hosted_pkgs), OSV_BATCH_SIZE):
        batch = hosted_pkgs[start : start + OSV_BATCH_SIZE]
        payload = {
            "queries": [
                {"package": {"name": pkg.name, "ecosystem": "Pub"}, "version": pkg.version}
                for pkg in batch
            ]
        }
        resp = client.post_json(OSV_BATCH_URL, payload)
        if not isinstance(resp, dict) or not isinstance(resp.get("results"), list):
            errors.append("unexpected OSV querybatch response format")
            break
        batch_results = resp["results"]
        if len(batch_results) != len(batch):
            errors.append(
                f"OSV querybatch result count mismatch: sent {len(batch)}, received {len(batch_results)}"
            )
            break

        for pkg, result in zip(batch, batch_results):
            vulns = result.get("vulns") if isinstance(result, dict) else None
            if not isinstance(vulns, list):
                continue
            for vuln in vulns:
                if not isinstance(vuln, dict) or not vuln.get("id"):
                    continue
                vuln_id = str(vuln["id"]).strip()
                aliases: list[str] = list(vuln.get("aliases", [])) if isinstance(vuln.get("aliases"), list) else []
                summary = str(vuln.get("summary", "")).strip()

                if not aliases and not summary:
                    if vuln_id not in vuln_detail_cache:
                        detail_url = f"{OSV_VULN_URL}/{urllib.parse.quote(vuln_id, safe='')}"
                        try:
                            detail = client.get_json(detail_url)
                            vuln_detail_cache[vuln_id] = detail if isinstance(detail, dict) else {}
                        except HttpStatusError:
                            vuln_detail_cache[vuln_id] = {}
                    detail_data = vuln_detail_cache[vuln_id]
                    raw_aliases = detail_data.get("aliases")
                    if isinstance(raw_aliases, list):
                        aliases = [str(a).strip() for a in raw_aliases if str(a).strip()]
                    if isinstance(detail_data.get("summary"), str):
                        summary = detail_data["summary"].strip()

                candidate_ids = {vuln_id, *aliases}
                matched_exc = next(
                    (
                        exc
                        for exc in valid_exceptions
                        if exc["package"] == pkg.name and exc["id"] in candidate_ids
                    ),
                    None,
                )
                is_excepted = matched_exc is not None
                findings.append(
                    {
                        "package": pkg.name,
                        "version": pkg.version,
                        "id": vuln_id,
                        "aliases": aliases,
                        "summary": summary,
                        "excepted": is_excepted,
                        "exception": matched_exc,
                    }
                )
                if not is_excepted:
                    errors.append(
                        f"unexcepted OSV vulnerability {vuln_id} in {pkg.name}@{pkg.version}"
                        + (f": {summary}" if summary else "")
                    )

    unexcepted_count = sum(1 for f in findings if not f["excepted"])
    excepted_count = sum(1 for f in findings if f["excepted"])
    osv_summary: dict[str, object] = {
        "queriedPackageCount": len(hosted_pkgs),
        "vulnerabilityCount": len(findings),
        "unexceptedCount": unexcepted_count,
        "exceptedCount": excepted_count,
        "exceptionsFileValid": len(exc_errors) == 0,
        "exceptionErrors": exc_errors,
        "findings": findings,
    }
    return osv_summary, errors


def _resolve_github_tag_commit(client: object, repo: str, tag: str) -> str:
    url = f"{GITHUB_API_BASE}/repos/{repo}/git/ref/tags/{urllib.parse.quote(tag, safe='')}"
    data = client.get_json(url)
    if not isinstance(data, dict) or not isinstance(data.get("object"), dict):
        raise HttpStatusError(422, url, "missing object in git ref response")
    obj = data["object"]
    depth = 0
    while obj.get("type") == "tag" and depth < 5:
        depth += 1
        tag_url = str(obj.get("url", "")).strip()
        if not tag_url:
            break
        tag_data = client.get_json(tag_url)
        if not isinstance(tag_data, dict) or not isinstance(tag_data.get("object"), dict):
            break
        obj = tag_data["object"]
    if obj.get("type") != "commit" or not isinstance(obj.get("sha"), str):
        raise HttpStatusError(422, url, f"tag {tag} did not resolve to a commit")
    return obj["sha"].strip().lower()


def audit_github_actions(
    root: Path,
    client: object,
    now_utc: datetime,
    cooldown_days: int,
) -> tuple[list[dict[str, object]], list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    results: list[dict[str, object]] = []

    ci_path = root / ".github" / "workflows" / "ci.yml"
    if not ci_path.is_file():
        return results, ["missing .github/workflows/ci.yml"], warnings

    allowed_patterns, sha_required = load_actions_policy(root / ".github" / "actions-policy.json")
    action_refs = parse_workflow_actions(ci_path, ".github/workflows/ci.yml")
    if not action_refs:
        errors.append(".github/workflows/ci.yml: no GitHub Actions references found")
        return results, errors, warnings

    latest_release_cache: dict[str, dict[str, object] | None] = {}

    for ref in action_refs:
        is_sha40 = bool(SHA40_RE.fullmatch(ref.pinned_ref))
        policy_allowed = True
        if allowed_patterns is not None:
            full_ref = f"{ref.action}@{ref.pinned_ref}"
            policy_allowed = any(fnmatch.fnmatch(full_ref, pat) for pat in allowed_patterns)

        if sha_required and not is_sha40:
            errors.append(
                f"{ref.workflow}:{ref.line}: action {ref.action}@{ref.pinned_ref} must be pinned to a 40-char SHA"
            )
        if not policy_allowed:
            errors.append(
                f"{ref.workflow}:{ref.line}: action {ref.action} is not permitted by .github/actions-policy.json"
            )

        resolved_sha: str | None = None
        sha_match = False
        if not ref.comment_tag:
            errors.append(
                f"{ref.workflow}:{ref.line}: pinned action {ref.action}@{ref.pinned_ref} missing version tag comment"
            )
        else:
            try:
                resolved_sha = _resolve_github_tag_commit(client, ref.repo, ref.comment_tag)
                sha_match = is_sha40 and (resolved_sha == ref.pinned_ref.lower())
                if not sha_match:
                    errors.append(
                        f"{ref.workflow}:{ref.line}: {ref.action} pinned SHA {ref.pinned_ref} "
                        f"!= tag {ref.comment_tag} commit {resolved_sha}"
                    )
            except HttpStatusError as exc:
                errors.append(
                    f"{ref.workflow}:{ref.line}: cannot resolve tag {ref.comment_tag} for {ref.repo}: {exc}"
                )

        latest_tag: str | None = None
        latest_pub_str: str | None = None
        action_cooldown = "unknown"
        if ref.repo not in latest_release_cache:
            rel_url = f"{GITHUB_API_BASE}/repos/{ref.repo}/releases/latest"
            try:
                rel_data = client.get_json(rel_url)
                latest_release_cache[ref.repo] = rel_data if isinstance(rel_data, dict) else None
            except HttpStatusError:
                latest_release_cache[ref.repo] = None

        rel_info = latest_release_cache[ref.repo]
        if rel_info and isinstance(rel_info.get("tag_name"), str):
            latest_tag = rel_info["tag_name"].strip()
            pub_raw = str(rel_info.get("published_at") or rel_info.get("created_at") or "").strip()
            if pub_raw:
                latest_dt = parse_iso_utc(pub_raw)
                latest_pub_str = format_iso_utc(latest_dt)
                if ref.comment_tag and compare_stable_versions(ref.comment_tag, latest_tag) >= 0:
                    action_cooldown = "up-to-date"
                elif now_utc - latest_dt >= timedelta(days=cooldown_days):
                    action_cooldown = "upgrade-eligible"
                    age_days = (now_utc - latest_dt).total_seconds() / 86400.0
                    warnings.append(
                        f"GitHub Action {ref.repo}: pinned {ref.comment_tag}, eligible release "
                        f"{latest_tag} ({age_days:.1f}d >= {cooldown_days}d cooldown)"
                    )
                else:
                    action_cooldown = "cooling-down"

        results.append(
            {
                "workflow": ref.workflow,
                "line": ref.line,
                "action": ref.action,
                "pinnedSha": ref.pinned_ref,
                "commentTag": ref.comment_tag,
                "resolvedSha": resolved_sha,
                "shaMatch": sha_match,
                "policyAllowed": policy_allowed,
                "latestRelease": latest_tag,
                "latestReleasePublishedUtc": latest_pub_str,
                "cooldownStatus": action_cooldown,
            }
        )

    return results, errors, warnings


def run_audit(
    root: Path,
    *,
    audit_mode: bool = True,
    output_path: Path | None = None,
    client: object | None = None,
    now_utc: datetime | None = None,
    cooldown_days: int = DEFAULT_COOLDOWN_DAYS,
) -> tuple[int, dict[str, object]]:
    root = root.resolve()
    now = (now_utc or datetime.now(timezone.utc)).astimezone(timezone.utc)
    http_client = client if client is not None else UrllibHttpClient()
    artifact_path = output_path if output_path is not None else (root / "artifacts" / "audit" / "deps.json")

    errors: list[str] = []
    warnings: list[str] = []
    network_errors: list[str] = []

    flutter_info: dict[str, object] = {}
    direct_deps_info: list[dict[str, object]] = []
    osv_info: dict[str, object] = {
        "queriedPackageCount": 0,
        "vulnerabilityCount": 0,
        "unexceptedCount": 0,
        "exceptedCount": 0,
        "exceptionsFileValid": True,
        "exceptionErrors": [],
        "findings": [],
    }
    actions_info: list[dict[str, object]] = []

    lock_path = root / "pubspec.lock"
    locked: dict[str, LockedPackage] = {}
    if not lock_path.is_file():
        errors.append("missing pubspec.lock")
    else:
        locked = parse_pubspec_lock(lock_path)

    try:
        flutter_info, fl_errors, fl_warnings = audit_flutter(root, http_client, now, cooldown_days)
        errors.extend(fl_errors)
        warnings.extend(fl_warnings)
    except NetworkError as exc:
        network_errors.append(f"flutter: {exc}")

    if not network_errors and lock_path.is_file():
        try:
            direct_deps_info, dep_errors, dep_warnings = audit_direct_dependencies(
                root, locked, http_client, now, cooldown_days
            )
            errors.extend(dep_errors)
            warnings.extend(dep_warnings)
        except NetworkError as exc:
            network_errors.append(f"pub.dev: {exc}")

    if not network_errors and lock_path.is_file():
        try:
            osv_info, osv_errors = audit_osv(root, locked, http_client, now.date())
            errors.extend(osv_errors)
        except NetworkError as exc:
            network_errors.append(f"osv: {exc}")

    if not network_errors:
        try:
            actions_info, act_errors, act_warnings = audit_github_actions(
                root, http_client, now, cooldown_days
            )
            errors.extend(act_errors)
            warnings.extend(act_warnings)
        except NetworkError as exc:
            network_errors.append(f"github-actions: {exc}")

    if network_errors:
        status = "not-run"
        exit_code = 2
    elif errors:
        status = "failed"
        exit_code = 1
    else:
        status = "passed"
        exit_code = 0

    report: dict[str, object] = {
        "schemaVersion": 1,
        "status": status,
        "mode": "audit" if audit_mode else "inventory",
        "checkedAtUtc": format_iso_utc(now),
        "cooldownDays": cooldown_days,
        "flutter": flutter_info,
        "directDependencies": direct_deps_info,
        "osv": osv_info,
        "githubActions": actions_info,
        "errors": errors,
        "warnings": warnings,
        "networkErrors": network_errors,
    }
    atomic_write_json(artifact_path, report)
    return exit_code, report


def print_summary(report: dict[str, object], artifact_path: Path, root: Path | None = None) -> None:
    status = str(report.get("status", "unknown")).upper()
    fl = report.get("flutter", {})
    if isinstance(fl, dict) and fl.get("pinnedVersion"):
        print(
            f"Flutter: pinned={fl.get('pinnedVersion')} "
            f"latest={fl.get('latestStable')} "
            f"cooldown={fl.get('cooldownStatus')}"
        )

    direct = report.get("directDependencies", [])
    if isinstance(direct, list) and direct:
        print(f"Direct pub dependencies ({len(direct)}):")
        for item in direct:
            if not isinstance(item, dict):
                continue
            print(
                f"  - {item['name']}: locked={item['lockedVersion']} "
                f"latest={item['latestStable']} ({item['cooldownStatus']})"
            )

    osv = report.get("osv", {})
    if isinstance(osv, dict):
        print(
            f"OSV Pub audit: queried={osv.get('queriedPackageCount', 0)} "
            f"vulns={osv.get('vulnerabilityCount', 0)} "
            f"unexcepted={osv.get('unexceptedCount', 0)} "
            f"excepted={osv.get('exceptedCount', 0)}"
        )

    actions = report.get("githubActions", [])
    if isinstance(actions, list) and actions:
        print(f"GitHub Actions ({len(actions)}):")
        for item in actions:
            if not isinstance(item, dict):
                continue
            print(
                f"  - {item['action']} ({item['commentTag']}): "
                f"shaMatch={item['shaMatch']} policyAllowed={item['policyAllowed']} "
                f"cooldown={item['cooldownStatus']}"
            )

    for warning in report.get("warnings", []):
        print(f"NOTICE: {warning}")
    for net_err in report.get("networkErrors", []):
        print(f"NOT-RUN: {net_err}", file=sys.stderr)
    for err in report.get("errors", []):
        print(f"FAIL: {err}", file=sys.stderr)

    display_path = artifact_path.as_posix()
    if root is not None:
        try:
            display_path = artifact_path.resolve().relative_to(root.resolve()).as_posix()
        except ValueError:
            pass
    print(f"{status}: dependency report written to {display_path}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--audit",
        action="store_true",
        help="Run full dependency, cooldown, OSV, Flutter checksum, and GitHub Action SHA audit.",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Repository root directory.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output JSON path (defaults to <root>/artifacts/audit/deps.json).",
    )
    parser.add_argument(
        "--cooldown-days",
        type=int,
        default=DEFAULT_COOLDOWN_DAYS,
        help="Minimum release age in days before flagging upgrades (default: 7).",
    )
    args = parser.parse_args(argv)

    root = args.root.resolve()
    artifact_path = args.output if args.output is not None else (root / "artifacts" / "audit" / "deps.json")
    exit_code, report = run_audit(
        root,
        audit_mode=bool(args.audit),
        output_path=artifact_path,
        cooldown_days=args.cooldown_days,
    )
    print_summary(report, artifact_path, root=root)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
