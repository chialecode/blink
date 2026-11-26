"""Regression fixtures for scripts/check_docs.py (zero third-party dependencies).

Run from any directory:
    python -B scripts/test_check_docs.py

Every fixture lives in its own temporary directory; the working tree is never written.
Fixture names are synthetic and must never be real sibling or reference project names.
"""

from __future__ import annotations

import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.dont_write_bytecode = True

import check_docs  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[1]
GOOD_README = "# Fixture\n\nSee [guide](docs/guide.md#usage).\n"
GOOD_GUIDE = "# Guide\n\n## Usage\n\nText.\n"


class FixtureCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="blink-check-docs-")
        self.workspace = Path(self._tmp.name)
        self.root = self.workspace / "fixture-repo"
        self.root.mkdir()
        self.write("README.md", GOOD_README)
        self.write("docs/guide.md", GOOD_GUIDE)
        env = {k: v for k, v in os.environ.items() if k != "BLINK_REFERENCE_DIR"}
        self._env = mock.patch.dict(os.environ, env, clear=True)
        self._env.start()

    def tearDown(self) -> None:
        self._env.stop()
        self._tmp.cleanup()

    def write(self, rel: str, text: str, *, raw: bytes | None = None) -> None:
        target = self.root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        if raw is not None:
            target.write_bytes(raw)
        else:
            target.write_text(text, encoding="utf-8", newline="\n")

    def run_check(self, ref_dir: str | None = None) -> list[str]:
        errors, _, _ = check_docs.check(self.root, ref_dir_override=ref_dir, check_layout=False)
        return errors

    def assertFlags(self, fragment: str, errors: list[str]) -> None:
        self.assertTrue(
            any(fragment in err for err in errors),
            f"expected an error containing {fragment!r}, got {errors!r}",
        )


class PositiveTests(FixtureCase):
    def test_clean_fixture_passes(self) -> None:
        self.assertEqual(self.run_check(), [])

    def test_code_spans_are_not_checked_as_links(self) -> None:
        self.write("docs/guide.md", GOOD_GUIDE + "\n`[x](missing.md)`\n\n```text\n[y](gone.md)\n```\n")
        self.assertEqual(self.run_check(), [])

    def test_html_anchor_is_accepted(self) -> None:
        self.write("README.md", "# Fixture\n\n[a](docs/guide.md#custom)\n")
        self.write("docs/guide.md", '# Guide\n\n<a id="custom"></a>\n## Other\n')
        self.assertEqual(self.run_check(), [])

    def test_repository_working_tree_passes(self) -> None:
        errors, count, _ = check_docs.check(REPO_ROOT)
        self.assertEqual(errors, [])
        self.assertGreater(count, 0)


class LinkTests(FixtureCase):
    def test_broken_link(self) -> None:
        self.write("README.md", "# Fixture\n\n[x](docs/missing.md)\n")
        self.assertFlags("broken relative link target", self.run_check())

    def test_missing_anchor(self) -> None:
        self.write("README.md", "# Fixture\n\n[x](docs/guide.md#nowhere)\n")
        self.assertFlags("missing anchor #nowhere", self.run_check())

    def test_reference_style_link(self) -> None:
        self.write("README.md", "# Fixture\n\n[x][id]\n\n[id]: docs/guide.md\n")
        self.assertFlags("reference-style Markdown links are forbidden", self.run_check())

    def test_backslash_link(self) -> None:
        self.write("README.md", "# Fixture\n\n[x](docs\\guide.md)\n")
        self.assertFlags("forward-slash relative link", self.run_check())

    def test_link_escaping_root(self) -> None:
        self.write("README.md", "# Fixture\n\n[x](../outside.md)\n")
        self.assertFlags("link escapes repository root", self.run_check())


class FormatTests(FixtureCase):
    def test_yaml_frontmatter(self) -> None:
        self.write("docs/guide.md", "---\ntitle: x\n---\n" + GOOD_GUIDE)
        self.assertFlags("YAML frontmatter", self.run_check())

    def test_bom(self) -> None:
        self.write("docs/guide.md", "", raw=b"\xef\xbb\xbf" + GOOD_GUIDE.encode())
        self.assertFlags("UTF-8 BOM is not allowed", self.run_check())

    def test_crlf(self) -> None:
        self.write("docs/guide.md", "", raw=GOOD_GUIDE.replace("\n", "\r\n").encode())
        self.assertFlags("CRLF line endings are not allowed", self.run_check())

    def test_crlf_allowed_for_batch_files(self) -> None:
        self.write("scripts/run.cmd", "", raw=b"@echo off\r\nexit /b 0\r\n")
        self.assertEqual(self.run_check(), [])

    def test_docs_filename_must_be_kebab_case(self) -> None:
        self.write("docs/Bad_Name.md", "# Bad\n")
        self.assertFlags("lowercase kebab-case", self.run_check())

    def test_claude_md_contract(self) -> None:
        self.write("CLAUDE.md", "@AGENTS.md\nextra\n")
        self.assertFlags("CLAUDE.md: must contain strictly", self.run_check())


class HygieneTests(FixtureCase):
    def test_windows_absolute_path(self) -> None:
        self.write("docs/guide.md", GOOD_GUIDE + "\nSee " + "Q:" + "\\work\\notes.\n")
        self.assertFlags("Windows absolute path", self.run_check())

    def test_unix_home_path(self) -> None:
        self.write("docs/guide.md", GOOD_GUIDE + "\nSee /" + "home/someone/notes.\n")
        self.assertFlags("Unix home path", self.run_check())

    def test_api_secret(self) -> None:
        fake = "sk-" + "A1b2C3d4E5f6G7h8I9j0K1l2"
        self.write("docs/guide.md", GOOD_GUIDE + f"\nkey {fake}\n")
        self.assertFlags("API secret key", self.run_check())

    def test_github_token(self) -> None:
        fake = "ghp_" + "Z" * 36
        self.write("notes.txt", f"token {fake}\n")
        self.assertFlags("GitHub token", self.run_check())

    def test_secret_in_extensionless_hook(self) -> None:
        fake = "AKIA" + "ABCDEFGHIJKLMNOP"
        self.write(".githooks/pre-push", f"#!/bin/sh\necho {fake}\n")
        self.assertFlags("AWS access key", self.run_check())

    def test_private_key_block(self) -> None:
        header = "-----BEGIN " + "PRIVATE KEY-----"
        self.write("docs/guide.md", GOOD_GUIDE + f"\n{header}\n")
        self.assertFlags("private key block", self.run_check())

    def test_credential_embedded_url(self) -> None:
        sample = "https://" + "alice" + ":" + "notreal" + "@example.invalid/repo"
        self.write("docs/guide.md", GOOD_GUIDE + f"\n{sample}\n")
        self.assertFlags("credential-embedded URL", self.run_check())

    def test_session_cookie_token(self) -> None:
        sample = "sessionid" + "=" + "SyntheticVal99"
        self.write("docs/guide.md", GOOD_GUIDE + f"\n{sample}\n")
        self.assertFlags("session or cookie token", self.run_check())

    def test_signed_url_parameter(self) -> None:
        sample = "https://example.invalid/feed?" + "a_bogus" + "=ABCD1234"
        self.write("docs/guide.md", GOOD_GUIDE + f"\n{sample}\n")
        self.assertFlags("signed URL parameter", self.run_check())

    def test_hardcoded_credential_assignment(self) -> None:
        sample = "api_" + 'key = "' + "Z" * 24 + '"'
        self.write("notes.txt", f"{sample}\n")
        self.assertFlags("hardcoded credential assignment", self.run_check())

    def test_disallowed_content_rules_have_matching_labels(self) -> None:
        pattern_ids = [rule_id for rule_id, _ in check_docs.DISALLOWED_CONTENT_PATTERNS]
        self.assertEqual(len(pattern_ids), len(set(pattern_ids)))
        self.assertEqual(set(pattern_ids), set(check_docs.DISALLOWED_CONTENT_LABELS))

    def test_forbidden_database_file(self) -> None:
        self.write("data/blink.db", "", raw=b"SQLite format 3\x00")
        self.assertFlags("forbidden sensitive or database file", self.run_check())

    def test_env_file_forbidden_but_example_allowed(self) -> None:
        self.write(".env.example", "", raw=b"KEY=\n")
        self.assertEqual(self.run_check(), [])
        self.write(".env.local", "", raw=b"KEY=\n")
        self.assertFlags("forbidden sensitive or database file", self.run_check())

    def test_flutter_ephemeral_outputs_are_excluded(self) -> None:
        leak = "export FLUTTER_ROOT=" + "Q:" + "\\sdk\\flutter\n"
        self.write("apps/blink_client/ios/Flutter/flutter_export_environment.sh", leak)
        self.write("apps/blink_client/macos/Flutter/ephemeral/flutter_export_environment.sh", leak)
        self.write("apps/blink_client/windows/flutter/ephemeral/generated.dart", "// " + "Q:" + "\\sdk\n")
        self.write("apps/blink_client/ios/.symlinks/plugins/pkg/leak.dart", "// /" + "home/user/sdk\n")
        self.assertEqual(self.run_check(), [])

    def test_non_ephemeral_sh_and_dart_absolute_paths_still_fail(self) -> None:
        self.write("scripts/sample.sh", "#!/bin/sh\nROOT=" + "Q:" + "\\sdk\\flutter\n")
        self.assertFlags("Windows absolute path", self.run_check())
        (self.root / "scripts" / "sample.sh").unlink()

        self.write("apps/blink_client/lib/sample.dart", "const p = '/" + "home/someone/sdk';\n")
        self.assertFlags("Unix home path", self.run_check())

    def test_flutter_generated_names_outside_platform_dirs_are_still_checked(self) -> None:
        leak = "// " + "Q:" + "\\sdk\n"
        self.write("docs/flutter/ephemeral/notes.dart", leak)
        self.assertFlags("Windows absolute path", self.run_check())
        (self.root / "docs" / "flutter" / "ephemeral" / "notes.dart").unlink()

        self.write("scripts/.symlinks/leak.dart", leak)
        self.assertFlags("Windows absolute path", self.run_check())


class ReferenceNameTests(FixtureCase):
    def test_sibling_repository_name(self) -> None:
        sibling = self.workspace / "zetaquill"
        (sibling / ".git").mkdir(parents=True)
        self.write("docs/guide.md", GOOD_GUIDE + "\nBorrowed from zetaquill.\n")
        self.assertFlags("forbidden reference or sibling repository name (zetaquill)", self.run_check())

    def test_sibling_name_inside_external_url_is_ignored(self) -> None:
        sibling = self.workspace / "zetaquill"
        (sibling / ".git").mkdir(parents=True)
        self.write("docs/guide.md", GOOD_GUIDE + "\n[x](https://example.org/zetaquill/docs)\n")
        self.assertEqual(self.run_check(), [])

    def test_reference_index_names(self) -> None:
        ref_dir = self.workspace / "ref-index"
        ref_dir.mkdir()
        (ref_dir / "README.md").write_text(
            "# Index\n\n### someorg/alphalib\n", encoding="utf-8", newline="\n"
        )
        self.write("docs/guide.md", GOOD_GUIDE + "\nInspired by alphalib.\n")
        self.assertFlags("(alphalib)", self.run_check(ref_dir=str(ref_dir)))

    def test_reference_index_via_ancestor_scan(self) -> None:
        ref_dir = self.workspace / "reference" / self.root.name
        ref_dir.mkdir(parents=True)
        (ref_dir / "INDEX.md").write_text("# Index\n\n## someorg/betakit\n", encoding="utf-8", newline="\n")
        self.write("docs/guide.md", GOOD_GUIDE + "\nUses someorg/betakit ideas.\n")
        self.assertFlags("(someorg/betakit)", self.run_check())


class CliTests(FixtureCase):
    def test_exit_codes(self) -> None:
        args = ["--root", str(self.root), "--no-layout-check"]
        with mock.patch("sys.stdout"), mock.patch("sys.stderr"):
            self.assertEqual(check_docs.main(args), 0)
            self.write("README.md", "# Fixture\n\n[x](docs/missing.md)\n")
            self.assertEqual(check_docs.main(args), 1)

    def test_layout_check_reports_missing_files(self) -> None:
        errors, _, _ = check_docs.check(self.root, check_layout=True)
        self.assertFlags("missing required file: AGENTS.md", errors)

    def test_cli_reports_label_without_echoing_matched_value(self) -> None:
        sample = "sk-" + "A1b2C3d4E5f6G7h8I9j0K1l2"
        self.write("docs/guide.md", GOOD_GUIDE + f"\nvalue {sample}\n")
        out_buf = io.StringIO()
        err_buf = io.StringIO()
        args = ["--root", str(self.root), "--no-layout-check"]
        with contextlib.redirect_stdout(out_buf), contextlib.redirect_stderr(err_buf):
            code = check_docs.main(args)
        self.assertEqual(code, 1)
        self.assertIn("docs/guide.md:", err_buf.getvalue())
        self.assertIn("API secret key", err_buf.getvalue())
        self.assertNotIn(sample, err_buf.getvalue())
        self.assertNotIn(sample, out_buf.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=1)
