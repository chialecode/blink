"""Unit tests for scripts/deps.py (zero third-party dependencies, mocked HTTP only).

Run from any directory:
    python -B scripts/test_deps.py
"""

from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.dont_write_bytecode = True

import deps  # noqa: E402

NOW_UTC = datetime(2026, 11, 23, 12, 0, 0, tzinfo=timezone.utc)
WIN_SHA = "a" * 64
LIN_SHA = "b" * 64
CHECKOUT_SHA = "3" * 40
PYTHON_SHA = "6" * 40
ANNOTATED_TAG_SHA = "9" * 40


class FakeHttpClient:
    """Deterministic fake HTTP client for offline unit testing."""

    def __init__(
        self,
        get_map: dict[str, object] | None = None,
        post_map: dict[str, object] | None = None,
        fail_prefix: str | None = None,
    ) -> None:
        self.get_map: dict[str, object] = dict(get_map or {})
        self.post_map: dict[str, object] = dict(post_map or {})
        self.fail_prefix = fail_prefix
        self.get_calls: list[str] = []
        self.post_calls: list[tuple[str, dict[str, object]]] = []

    def get_json(self, url: str, headers: dict[str, str] | None = None) -> object:
        self.get_calls.append(url)
        if self.fail_prefix and url.startswith(self.fail_prefix):
            raise deps.NetworkError(f"simulated offline for {url}")
        if url not in self.get_map:
            raise deps.HttpStatusError(404, url, "not mocked")
        val = self.get_map[url]
        if isinstance(val, Exception):
            raise val
        return val

    def post_json(
        self,
        url: str,
        payload: dict[str, object],
        headers: dict[str, str] | None = None,
    ) -> object:
        self.post_calls.append((url, payload))
        if self.fail_prefix and url.startswith(self.fail_prefix):
            raise deps.NetworkError(f"simulated offline for {url}")
        if url not in self.post_map:
            raise deps.HttpStatusError(404, url, "not mocked")
        val = self.post_map[url]
        if callable(val):
            return val(payload)
        if isinstance(val, Exception):
            raise val
        return val


class DepsFixtureCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="blink-test-deps-")
        self.root = Path(self._tmp.name) / "repo"
        self.root.mkdir()
        self._write_baseline_fixture()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write(self, rel: str, text: str) -> None:
        target = self.root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8", newline="\n")

    def _write_baseline_fixture(self) -> None:
        self.write(".flutter-version", "3.50.0\n")
        self.write(
            "pubspec.yaml",
            "name: sample_ws\npublish_to: none\nenvironment:\n  sdk: ^3.14.0\nworkspace:\n  - apps/blink_client\n",
        )
        self.write(
            "apps/blink_client/pubspec.yaml",
            (
                "name: blink_client\n"
                "resolution: workspace\n"
                "dependencies:\n"
                "  flutter:\n"
                "    sdk: flutter\n"
                "  alpha_pkg: 0.7.0\n"
                "  beta_pkg: 1.0.0\n"
                "dev_dependencies:\n"
                "  flutter_test:\n"
                "    sdk: flutter\n"
            ),
        )
        self.write(
            "pubspec.lock",
            (
                "packages:\n"
                "  alpha_pkg:\n"
                "    dependency: transitive\n"
                "    description:\n"
                "      name: alpha_pkg\n"
                "      url: \"https://pub.dev\"\n"
                "    source: hosted\n"
                "    version: \"0.7.0\"\n"
                "  beta_pkg:\n"
                "    dependency: transitive\n"
                "    description:\n"
                "      name: beta_pkg\n"
                "      url: \"https://pub.dev\"\n"
                "    source: hosted\n"
                "    version: \"1.0.0\"\n"
                "  gamma_trans:\n"
                "    dependency: transitive\n"
                "    description:\n"
                "      name: gamma_trans\n"
                "      url: \"https://pub.dev\"\n"
                "    source: hosted\n"
                "    version: \"2.0.0\"\n"
                "  flutter:\n"
                "    dependency: \"direct main\"\n"
                "    description: flutter\n"
                "    source: sdk\n"
                "    version: \"0.0.0\"\n"
            ),
        )
        self.write(
            "scripts/flutter-checksums.json",
            json.dumps(
                {
                    "schemaVersion": 1,
                    "baseUrl": deps.FLUTTER_RELEASES_BASE,
                    "channel": "stable",
                    "version": "3.50.0",
                    "archives": {
                        "windows": {
                            "arch": "x64",
                            "archive": "stable/windows/flutter_windows_3.50.0-stable.zip",
                            "sha256": WIN_SHA,
                        },
                        "linux": {
                            "arch": "x64",
                            "archive": "stable/linux/flutter_linux_3.50.0-stable.tar.xz",
                            "sha256": LIN_SHA,
                        },
                    },
                },
                indent=2,
            )
            + "\n",
        )
        self.write(
            "scripts/deps-exceptions.json",
            json.dumps({"schemaVersion": 1, "exceptions": []}, indent=2) + "\n",
        )
        self.write(
            ".github/actions-policy.json",
            json.dumps(
                {
                    "permissions": {"sha_pinning_required": True},
                    "selectedActions": {
                        "patterns_allowed": ["actions/checkout@*", "actions/setup-python@*"]
                    },
                },
                indent=2,
            )
            + "\n",
        )
        self.write(
            ".github/workflows/ci.yml",
            (
                "name: CI\n"
                "jobs:\n"
                "  repository-quality:\n"
                "    steps:\n"
                f"      - uses: actions/checkout@{CHECKOUT_SHA} # v7.0.1\n"
                f"      - uses: actions/setup-python@{PYTHON_SHA} # v7.1.0\n"
            ),
        )

    def make_client(
        self,
        *,
        flutter_latest_date: str = "2026-11-20T00:00:00Z",
        alpha_versions: list[dict[str, object]] | None = None,
        osv_results_by_pkg: dict[str, list[dict[str, object]]] | None = None,
        osv_vuln_details: dict[str, dict[str, object]] | None = None,
        linux_manifest_sha: str = LIN_SHA,
        checkout_tag_sha: str = CHECKOUT_SHA,
        fail_prefix: str | None = None,
    ) -> FakeHttpClient:
        if alpha_versions is None:
            alpha_versions = [
                {"version": "0.7.0", "published": "2026-11-12T00:00:00Z"},
                {"version": "0.7.1", "published": "2026-11-22T15:00:00Z"},
            ]

        get_map: dict[str, object] = {
            f"{deps.FLUTTER_RELEASES_BASE}/releases_windows.json": {
                "current_release": {"stable": "hash3501"},
                "releases": [
                    {
                        "hash": "hash3501",
                        "channel": "stable",
                        "version": "3.50.1",
                        "release_date": flutter_latest_date,
                        "archive": "stable/windows/flutter_windows_3.50.1-stable.zip",
                        "sha256": "c" * 64,
                        "dart_sdk_arch": "x64",
                    },
                    {
                        "hash": "hash3500",
                        "channel": "stable",
                        "version": "3.50.0",
                        "release_date": "2026-11-11T18:54:25Z",
                        "archive": "stable/windows/flutter_windows_3.50.0-stable.zip",
                        "sha256": WIN_SHA,
                        "dart_sdk_arch": "x64",
                    },
                ],
            },
            f"{deps.FLUTTER_RELEASES_BASE}/releases_linux.json": {
                "current_release": {"stable": "hash3501"},
                "releases": [
                    {
                        "hash": "hash3501",
                        "channel": "stable",
                        "version": "3.50.1",
                        "release_date": flutter_latest_date,
                        "archive": "stable/linux/flutter_linux_3.50.1-stable.tar.xz",
                        "sha256": "d" * 64,
                        "dart_sdk_arch": "x64",
                    },
                    {
                        "hash": "hash3500",
                        "channel": "stable",
                        "version": "3.50.0",
                        "release_date": "2026-11-11T19:05:47Z",
                        "archive": "stable/linux/flutter_linux_3.50.0-stable.tar.xz",
                        "sha256": linux_manifest_sha,
                        "dart_sdk_arch": "x64",
                    },
                ],
            },
            f"{deps.PUB_API_BASE}/alpha_pkg": {"versions": alpha_versions},
            f"{deps.PUB_API_BASE}/beta_pkg": {
                "versions": [{"version": "1.0.0", "published": "2026-10-01T00:00:00Z"}]
            },
            f"{deps.GITHUB_API_BASE}/repos/actions/checkout/git/ref/tags/v7.0.1": {
                "object": {"type": "commit", "sha": checkout_tag_sha}
            },
            f"{deps.GITHUB_API_BASE}/repos/actions/setup-python/git/ref/tags/v7.1.0": {
                "object": {
                    "type": "tag",
                    "sha": ANNOTATED_TAG_SHA,
                    "url": f"{deps.GITHUB_API_BASE}/repos/actions/setup-python/git/tags/{ANNOTATED_TAG_SHA}",
                }
            },
            f"{deps.GITHUB_API_BASE}/repos/actions/setup-python/git/tags/{ANNOTATED_TAG_SHA}": {
                "object": {"type": "commit", "sha": PYTHON_SHA}
            },
            f"{deps.GITHUB_API_BASE}/repos/actions/checkout/releases/latest": {
                "tag_name": "v7.0.1",
                "published_at": "2026-11-01T00:00:00Z",
            },
            f"{deps.GITHUB_API_BASE}/repos/actions/setup-python/releases/latest": {
                "tag_name": "v7.1.0",
                "published_at": "2026-11-01T00:00:00Z",
            },
        }
        for vuln_id, detail in (osv_vuln_details or {}).items():
            get_map[f"{deps.OSV_VULN_URL}/{vuln_id}"] = detail

        def osv_handler(payload: dict[str, object]) -> dict[str, object]:
            queries = payload.get("queries", [])
            out = []
            for item in queries:
                name = item["package"]["name"]
                vulns = (osv_results_by_pkg or {}).get(name, [])
                out.append({"vulns": vulns} if vulns else {})
            return {"results": out}

        return FakeHttpClient(
            get_map=get_map,
            post_map={deps.OSV_BATCH_URL: osv_handler},
            fail_prefix=fail_prefix,
        )


class CooldownAndCleanTests(DepsFixtureCase):
    def test_clean_audit_with_cooling_releases_passes(self) -> None:
        client = self.make_client()
        rc, report = deps.run_audit(self.root, audit_mode=True, client=client, now_utc=NOW_UTC)
        self.assertEqual(rc, 0)
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["flutter"]["cooldownStatus"], "cooling-down")
        direct = {d["name"]: d for d in report["directDependencies"]}
        self.assertEqual(direct["alpha_pkg"]["cooldownStatus"], "cooling-down")
        self.assertEqual(direct["beta_pkg"]["cooldownStatus"], "up-to-date")
        self.assertEqual(report["osv"]["queriedPackageCount"], 3)
        self.assertEqual(report["osv"]["unexceptedCount"], 0)
        self.assertTrue(all(a["shaMatch"] for a in report["githubActions"]))

        artifact = self.root / "artifacts" / "audit" / "deps.json"
        self.assertTrue(artifact.is_file())
        self.assertFalse(artifact.with_name("deps.json.blink-tmp").exists())
        saved = json.loads(artifact.read_text(encoding="utf-8"))
        self.assertEqual(saved["status"], "passed")

    def test_cooldown_flags_eligible_upgrade_and_ignores_retracted_and_prerelease(self) -> None:
        client = self.make_client(
            flutter_latest_date="2026-11-10T00:00:00Z",
            alpha_versions=[
                {"version": "0.7.0", "published": "2026-11-01T00:00:00Z"},
                {"version": "0.8.0", "published": "2026-11-12T00:00:00Z"},
                {"version": "0.9.0", "published": "2026-11-22T00:00:00Z"},
                {"version": "1.0.0", "published": "2026-11-05T00:00:00Z", "retracted": True},
                {"version": "2.0.0-beta.1", "published": "2026-11-05T00:00:00Z"},
            ],
        )
        rc, report = deps.run_audit(self.root, audit_mode=True, client=client, now_utc=NOW_UTC)
        self.assertEqual(rc, 0)
        self.assertEqual(report["flutter"]["cooldownStatus"], "upgrade-eligible")
        direct = {d["name"]: d for d in report["directDependencies"]}
        self.assertEqual(direct["alpha_pkg"]["latestStable"], "0.9.0")
        self.assertEqual(direct["alpha_pkg"]["latestEligible"], "0.8.0")
        self.assertEqual(direct["alpha_pkg"]["cooldownStatus"], "upgrade-eligible")
        self.assertTrue(any("alpha_pkg" in w for w in report["warnings"]))


class OsvAndExceptionsTests(DepsFixtureCase):
    def test_unexcepted_vulnerability_fails(self) -> None:
        client = self.make_client(
            osv_results_by_pkg={"gamma_trans": [{"id": "OSV-2026-0001"}]},
            osv_vuln_details={
                "OSV-2026-0001": {"id": "OSV-2026-0001", "aliases": ["CVE-2026-1234"], "summary": "Test vuln"}
            },
        )
        rc, report = deps.run_audit(self.root, audit_mode=True, client=client, now_utc=NOW_UTC)
        self.assertEqual(rc, 1)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["osv"]["unexceptedCount"], 1)
        self.assertTrue(any("OSV-2026-0001" in e for e in report["errors"]))

    def test_valid_exception_matching_alias_passes(self) -> None:
        self.write(
            "scripts/deps-exceptions.json",
            json.dumps(
                {
                    "schemaVersion": 1,
                    "exceptions": [
                        {
                            "id": "CVE-2026-1234",
                            "package": "gamma_trans",
                            "reason": "Unreachable code path; waiting for upstream patch",
                            "reviewBy": "2026-12-31",
                        }
                    ],
                },
                indent=2,
            )
            + "\n",
        )
        client = self.make_client(
            osv_results_by_pkg={"gamma_trans": [{"id": "OSV-2026-0001"}]},
            osv_vuln_details={
                "OSV-2026-0001": {"id": "OSV-2026-0001", "aliases": ["CVE-2026-1234"], "summary": "Test vuln"}
            },
        )
        rc, report = deps.run_audit(self.root, audit_mode=True, client=client, now_utc=NOW_UTC)
        self.assertEqual(rc, 0)
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["osv"]["exceptedCount"], 1)
        self.assertEqual(report["osv"]["unexceptedCount"], 0)

    def test_expired_exception_fails(self) -> None:
        self.write(
            "scripts/deps-exceptions.json",
            json.dumps(
                {
                    "schemaVersion": 1,
                    "exceptions": [
                        {
                            "id": "OSV-2026-0001",
                            "package": "gamma_trans",
                            "reason": "Stale exception",
                            "reviewBy": "2026-11-01",
                        }
                    ],
                },
                indent=2,
            )
            + "\n",
        )
        client = self.make_client()
        rc, report = deps.run_audit(self.root, audit_mode=True, client=client, now_utc=NOW_UTC)
        self.assertEqual(rc, 1)
        self.assertEqual(report["status"], "failed")
        self.assertFalse(report["osv"]["exceptionsFileValid"])
        self.assertTrue(any("expired" in e for e in report["errors"]))

    def test_malformed_exception_fails(self) -> None:
        self.write(
            "scripts/deps-exceptions.json",
            json.dumps(
                {
                    "schemaVersion": 1,
                    "exceptions": [{"id": "OSV-2026-0001", "package": "gamma_trans", "reviewBy": "not-a-date"}],
                },
                indent=2,
            )
            + "\n",
        )
        client = self.make_client()
        rc, report = deps.run_audit(self.root, audit_mode=True, client=client, now_utc=NOW_UTC)
        self.assertEqual(rc, 1)
        self.assertFalse(report["osv"]["exceptionsFileValid"])


class IntegrityAndOfflineTests(DepsFixtureCase):
    def test_flutter_checksum_mismatch_fails(self) -> None:
        client = self.make_client(linux_manifest_sha="f" * 64)
        rc, report = deps.run_audit(self.root, audit_mode=True, client=client, now_utc=NOW_UTC)
        self.assertEqual(rc, 1)
        self.assertEqual(report["status"], "failed")
        self.assertFalse(report["flutter"]["checksums"]["linux"]["ok"])
        self.assertTrue(any("SHA-256 mismatch" in e for e in report["errors"]))

    def test_flutter_version_mismatch_with_checksums_file_fails(self) -> None:
        self.write(".flutter-version", "3.50.1\n")
        client = self.make_client()
        rc, report = deps.run_audit(self.root, audit_mode=True, client=client, now_utc=NOW_UTC)
        self.assertEqual(rc, 1)
        self.assertTrue(any("flutter-checksums.json version" in e for e in report["errors"]))

    def test_action_sha_mismatch_fails(self) -> None:
        client = self.make_client(checkout_tag_sha="e" * 40)
        rc, report = deps.run_audit(self.root, audit_mode=True, client=client, now_utc=NOW_UTC)
        self.assertEqual(rc, 1)
        self.assertEqual(report["status"], "failed")
        self.assertFalse(report["githubActions"][0]["shaMatch"])
        self.assertTrue(any("pinned SHA" in e for e in report["errors"]))

    def test_disallowed_or_unpinned_action_fails(self) -> None:
        self.write(
            ".github/workflows/ci.yml",
            (
                "name: CI\n"
                "jobs:\n"
                "  repository-quality:\n"
                "    steps:\n"
                "      - uses: actions/checkout@v7\n"
                f"      - uses: thirdparty/untrusted@{PYTHON_SHA} # v1.0.0\n"
            ),
        )
        client = self.make_client()
        rc, report = deps.run_audit(self.root, audit_mode=True, client=client, now_utc=NOW_UTC)
        self.assertEqual(rc, 1)
        self.assertTrue(any("40-char SHA" in e for e in report["errors"]))
        self.assertTrue(any("not permitted" in e for e in report["errors"]))

    def test_offline_network_failure_records_not_run_and_exits_nonzero(self) -> None:
        for label, prefix in (
            ("flutter", deps.FLUTTER_RELEASES_BASE),
            ("pub.dev", deps.PUB_API_BASE),
            ("osv", deps.OSV_BATCH_URL),
            ("github", deps.GITHUB_API_BASE),
        ):
            with self.subTest(endpoint=label):
                client = self.make_client(fail_prefix=prefix)
                rc, report = deps.run_audit(self.root, audit_mode=True, client=client, now_utc=NOW_UTC)
                self.assertNotEqual(rc, 0)
                self.assertEqual(report["status"], "not-run")
                self.assertTrue(report["networkErrors"])
                saved = json.loads((self.root / "artifacts" / "audit" / "deps.json").read_text(encoding="utf-8"))
                self.assertEqual(saved["status"], "not-run")


if __name__ == "__main__":
    unittest.main(verbosity=1)
