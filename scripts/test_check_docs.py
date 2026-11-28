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
import time
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

    def test_android_gradle_and_cxx_caches_are_excluded(self) -> None:
        win_leak = "sdk.dir=" + "Q:" + "\\android\\sdk\n"
        unix_leak = '{"directory": "/' + 'home/builder/project"}\n'
        self.write("apps/blink_client/android/.gradle/8.14/fileHashes/cache.txt", win_leak)
        self.write("apps/blink_client/android/app/.cxx/Debug/arm64/compile_commands.json", unix_leak)
        self.assertEqual(self.run_check(), [])

    def test_tracked_android_files_still_fail_hygiene(self) -> None:
        self.write("apps/blink_client/android/app/notes.txt", "root=" + "Q:" + "\\android\\sdk\n")
        self.assertFlags("Windows absolute path", self.run_check())


class ReferenceNameTests(FixtureCase):
    def test_sibling_repository_name(self) -> None:
        sibling = self.workspace / "zeta-quill"
        (sibling / ".git").mkdir(parents=True)
        self.write("docs/guide.md", GOOD_GUIDE + "\nBorrowed from zeta-quill.\n")
        self.assertFlags("forbidden reference or sibling repository name (zeta-quill)", self.run_check())

    def test_sibling_name_inside_external_url_is_ignored(self) -> None:
        for name in ("zeta-quill", "offset"):
            ((self.workspace / name) / ".git").mkdir(parents=True)
        self.write(
            "docs/guide.md",
            GOOD_GUIDE
            + "\n[a](https://example.org/zeta-quill/docs)\n"
            + "[b](https://example.org/other/offset)\n",
        )
        self.assertEqual(self.run_check(), [])

    def test_owner_github_url_is_not_stripped(self) -> None:
        for name in ("zeta-quill", "offset"):
            ((self.workspace / name) / ".git").mkdir(parents=True)
        self.write("docs/guide.md", GOOD_GUIDE + "\n[a](https://github.com/chialecode/offset)\n")
        self.assertFlags("forbidden reference or sibling repository name (offset)", self.run_check())
        self.write("docs/guide.md", GOOD_GUIDE + "\n[b](https://github.com/chialecode/zeta-quill)\n")
        self.assertFlags("forbidden reference or sibling repository name (zeta-quill)", self.run_check())

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

    def test_reference_index_single_word_stays_strict_even_if_sibling_git_exists(self) -> None:
        ref_dir = self.workspace / "reference" / self.root.name
        ref_dir.mkdir(parents=True)
        (ref_dir / "README.md").write_text(
            "# Index\n\n### someorg/offset\n### someorg/cipher\n",
            encoding="utf-8",
            newline="\n",
        )
        (self.workspace / "offset" / ".git").mkdir(parents=True)
        self.write("lib/sample.dart", "void main() { final offset = 1; }\n")
        self.assertFlags("(offset)", self.run_check())
        (self.root / "lib" / "sample.dart").unlink()

        self.write("docs/guide.md", GOOD_GUIDE + "\nHandles invalid cipher header safely.\n")
        self.assertFlags("(cipher)", self.run_check())

    def test_reference_subdir_inside_repo_ref_stays_strict_over_sibling_git_repo(self) -> None:
        (self.workspace / "reference" / self.root.name / "offset").mkdir(parents=True)
        (self.workspace / "offset" / ".git").mkdir(parents=True)
        self.write("lib/sample.dart", "void f() { final offset = 2; }\n")
        self.assertFlags("(offset)", self.run_check())

    def test_reference_root_dir_single_word_stays_strict_in_md_and_dart(self) -> None:
        (self.workspace / "reference" / "offset").mkdir(parents=True)
        (self.workspace / "reference" / "cipher").mkdir(parents=True)

        self.write("lib/sample.dart", "const html = '<blink-metric offset=\"+18%\"></blink-metric>';\n")
        self.assertFlags("(offset)", self.run_check())
        (self.root / "lib" / "sample.dart").unlink()

        self.write("docs/guide.md", GOOD_GUIDE + "\nChecks cipher header bytes.\n")
        self.assertFlags("(cipher)", self.run_check())

    def test_reference_root_git_repo_overrides_same_named_sibling_git_repo(self) -> None:
        (self.workspace / "reference" / self.root.name).mkdir(parents=True)
        (self.workspace / "reference" / "offset" / ".git").mkdir(parents=True)
        (self.workspace / "offset" / ".git").mkdir(parents=True)
        self.write("lib/sample.dart", "void f() { final offset = 2; }\n")
        self.assertFlags("(offset)", self.run_check())

    def test_sibling_reference_buckets_in_per_project_ref_root_use_context_match(self) -> None:
        # Mirrors the real workspace layout: `reference/<this_repo>/` alongside
        # sibling project buckets (sibling dir under `root.parent`, empty placeholder,
        # or bucket with `PROPOSALS.md`).
        (self.workspace / "reference" / self.root.name).mkdir(parents=True)
        ((self.workspace / "offset") / ".git").mkdir(parents=True)
        (self.workspace / "reference" / "offset").mkdir(parents=True)
        (self.workspace / "reference" / "offset" / "README.md").write_text(
            "# Sibling Index\n", encoding="utf-8", newline="\n"
        )
        # Empty placeholder bucket (not checked out under root.parent)
        (self.workspace / "reference" / "cipher").mkdir(parents=True)
        # Sibling bucket identified by PROPOSALS.md
        (self.workspace / "reference" / "quartz").mkdir(parents=True)
        (self.workspace / "reference" / "quartz" / "PROPOSALS.md").write_text(
            "# Proposals\n", encoding="utf-8", newline="\n"
        )
        # Distinctive name stays strict even in a sibling bucket
        (self.workspace / "reference" / "sibling-app").mkdir(parents=True)

        self.write(
            "lib/sample.dart",
            "void f() { final offset = 1; const msg = 'invalid cipher quartz header'; }\n",
        )
        self.assertEqual(self.run_check(), [])

        self.write("docs/guide.md", GOOD_GUIDE + "\n参考 offset 项目。\n")
        self.assertFlags("(offset)", self.run_check())

        self.write("docs/guide.md", GOOD_GUIDE + "\nSee cipher repo for details.\n")
        self.assertFlags("(cipher)", self.run_check())

        self.write("docs/guide.md", GOOD_GUIDE + "\n参考项目：quartz。\n")
        self.assertFlags("(quartz)", self.run_check())

        self.write("docs/guide.md", GOOD_GUIDE + "\nMentioning sibling-app directly.\n")
        self.assertFlags("(sibling-app)", self.run_check())

    def test_unpacked_third_party_reference_dir_stays_strict_even_with_repo_ref_dir(self) -> None:
        # Non-.git unpacked third-party reference directory containing files/subdirs,
        # not present under root.parent and without PROPOSALS.md, must stay strict!
        (self.workspace / "reference" / self.root.name).mkdir(parents=True)
        unpacked = self.workspace / "reference" / "cipher"
        (unpacked / "src").mkdir(parents=True)
        (unpacked / "README.md").write_text("# Unpacked Reference Source\n", encoding="utf-8", newline="\n")

        self.write("lib/sample.dart", "const msg = 'invalid cipher header';\n")
        self.assertFlags("(cipher)", self.run_check())
        (self.root / "lib" / "sample.dart").unlink()

        self.write("docs/guide.md", GOOD_GUIDE + "\nUses cipher framing.\n")
        self.assertFlags("(cipher)", self.run_check())

    def test_explicit_ref_dir_subdir_without_index_stays_strict(self) -> None:
        ref_dir = self.workspace / "custom-ref"
        (ref_dir / "offset").mkdir(parents=True)
        self.write("lib/sample.dart", "void f() { final offset = 1; }\n")
        self.assertFlags("(offset)", self.run_check(ref_dir=str(ref_dir)))

    def test_distinctive_sibling_repo_names_stay_strict(self) -> None:
        for name in ("sibling-app", "tool_2", "kit2"):
            ((self.workspace / name) / ".git").mkdir(parents=True)

        cases = (
            ("docs/guide.md", GOOD_GUIDE + "\nMentioning sibling-app directly.\n", "sibling-app"),
            ("lib/sample.dart", "// uses tool_2 helper\n", "tool_2"),
            ("docs/guide.md", GOOD_GUIDE + "\nSee kit2 notes.\n", "kit2"),
        )
        for rel, content, expected in cases:
            with self.subTest(name=expected, rel=rel):
                self.write("docs/guide.md", GOOD_GUIDE)
                sample_dart = self.root / "lib" / "sample.dart"
                if sample_dart.exists():
                    sample_dart.unlink()
                self.write(rel, content)
                self.assertFlags(f"({expected})", self.run_check())

    def test_single_word_sibling_repo_allows_ordinary_code_and_prose(self) -> None:
        for name in ("offset", "cipher"):
            ((self.workspace / name) / ".git").mkdir(parents=True)

        self.write(
            "lib/sample.dart",
            "\n".join(
                [
                    "export 'src/offset/exporter.dart';",
                    "/// Flushes incremental offset immediately.",
                    "/// Throws on cipher/version mismatch.",
                    "int apply(int pos, int step) {",
                    "  final offset = step;",
                    "  const endpoint = 'POST /api/v1/offset';",
                    "  const mode = 'full/offset sync and replication/offset';",
                    "  const channelPath = 'blink-dev/offset';",
                    "  const msg = 'Encrypted relay object has invalid cipher header';",
                    '  const metric = \'<blink-metric label="Reading" offset="+18%"></blink-metric>\';',
                    "  // Non-matching identifier/extension/call variants:",
                    "  // foo/offset.dart ../offset_utils my_offset repo offset(client)",
                    "  return pos + offset + endpoint.length + mode.length + channelPath.length + msg.length + metric.length;",
                    "}",
                    "",
                ]
            ),
        )
        self.write(
            "docs/guide.md",
            GOOD_GUIDE
            + "\n### 相关参考\n\noffset 增量说明。\n\n项目概况\n\n"
            + "incremental offset\n\nproject overview\n\n"
            + "支持 full/offset 增量与 `src/offset/exporter.dart`、`POST /api/v1/offset`、`blink-dev/offset`。\n"
            + "应用 offset 更新，将 offset 应用到本地库。\n"
            + "参考 offset_v2 与 offset.dart 说明。\n"
            + "Handles invalid cipher header and `<blink-metric offset=\"+18%\">`.\n",
        )
        self.assertEqual(self.run_check(), [])

    def test_single_word_sibling_repo_flags_software_repo_and_path_mentions(self) -> None:
        for name in ("offset", "cipher"):
            ((self.workspace / name) / ".git").mkdir(parents=True)

        cases = (
            ("docs/guide.md", "See chialecode/offset for code.", "offset"),
            ("docs/guide.md", "See chialecode/offset.", "offset"),
            ("docs/guide.md", "See https://github.com/chialecode/offset", "offset"),
            ("docs/guide.md", "Clone https://github.com/chialecode/offset.git", "offset"),
            ("docs/guide.md", "Remote git@github.com:chialecode/cipher.git", "cipher"),
            ("docs/guide.md", "Remote git@gitlab.com:someorg/cipher", "cipher"),
            ("docs/guide.md", "Mirror gitee.com/someorg/offset", "offset"),
            ("docs/guide.md", "Clone someorg/offset.git directly.", "offset"),
            ("docs/guide.md", "Repository offset.git is local.", "offset"),
            ("docs/guide.md", "Located at ../offset directory.", "offset"),
            ("docs/guide.md", r"Located at ..\offset directory.", "offset"),
            ("docs/guide.md", "Located at ./cipher directory.", "cipher"),
            ("docs/guide.md", "Path project/offset here.", "offset"),
            ("docs/guide.md", r"Path project\offset here.", "offset"),
            ("docs/guide.md", "Path projects/cipher here.", "cipher"),
            ("docs/guide.md", "Path repos/offset here.", "offset"),
            ("docs/guide.md", "Path workspace/cipher here.", "cipher"),
            ("docs/guide.md", "这里参考 offset 实现。", "offset"),
            ("docs/guide.md", "参考：offset。", "offset"),
            ("docs/guide.md", "参考项目 offset 的结构。", "offset"),
            ("docs/guide.md", "参考项目：offset。", "offset"),
            ("docs/guide.md", "参考项目: offset。", "offset"),
            ("docs/guide.md", "参考 **offset** 的结构。", "offset"),
            ("docs/guide.md", "参考仓库《cipher》的设计。", "cipher"),
            ("docs/guide.md", "同级仓库 cipher。", "cipher"),
            ("docs/guide.md", "同级仓库：offset。", "offset"),
            ("docs/guide.md", "本机项目 offset。", "offset"),
            ("docs/guide.md", "隔壁仓库 cipher。", "cipher"),
            ("docs/guide.md", "借鉴 offset 的思路。", "offset"),
            ("docs/guide.md", "仿照 cipher 布局。", "cipher"),
            ("docs/guide.md", "抄自 offset。", "offset"),
            ("docs/guide.md", "来自 offset。", "offset"),
            ("docs/guide.md", "类似 offset。", "offset"),
            ("docs/guide.md", "对标 cipher。", "cipher"),
            ("docs/guide.md", "桌面应用 cipher。", "cipher"),
            ("docs/guide.md", "offset 项目已归档。", "offset"),
            ("docs/guide.md", "**offset** 项目已归档。", "offset"),
            ("docs/guide.md", "offset（同级仓库）架构。", "offset"),
            ("docs/guide.md", "offset（参考项目）实现。", "offset"),
            ("docs/guide.md", "offset 的源码。", "offset"),
            ("docs/guide.md", "offset 软件功能。", "offset"),
            ("docs/guide.md", "cipher 应用界面。", "cipher"),
            ("docs/guide.md", "offset 客户端。", "offset"),
            ("docs/guide.md", "offset 桌面端。", "offset"),
            ("docs/guide.md", "offset 服务端。", "offset"),
            ("docs/guide.md", "offset 代码库。", "offset"),
            ("docs/guide.md", "offset 工程。", "offset"),
            ("docs/guide.md", "offset 同级目录。", "offset"),
            ("docs/guide.md", "offset 参考。", "offset"),
            ("docs/guide.md", "参见《cipher》。", "cipher"),
            ("docs/guide.md", "参见「offset」。", "offset"),
            ("docs/guide.md", "参见『cipher』。", "cipher"),
            ("docs/guide.md", "From cipher repo history.", "cipher"),
            ("docs/guide.md", "In **offset** repo history.", "offset"),
            ("docs/guide.md", "Notes on offset (sibling repo).", "offset"),
            ("docs/guide.md", "In the offset repository.", "offset"),
            ("docs/guide.md", "In the offset project.", "offset"),
            ("docs/guide.md", "In the offset codebase.", "offset"),
            ("docs/guide.md", "Built like cipher app.", "cipher"),
            ("docs/guide.md", "Built like cipher software.", "cipher"),
            ("docs/guide.md", "Like offset client.", "offset"),
            ("docs/guide.md", "See sibling repo offset.", "offset"),
            ("docs/guide.md", "See sibling repo **offset**.", "offset"),
            ("docs/guide.md", "See sibling project cipher.", "cipher"),
            ("docs/guide.md", "See reference repo offset.", "offset"),
            ("docs/guide.md", "See reference project cipher.", "cipher"),
            ("docs/guide.md", "See reference app cipher.", "cipher"),
            ("docs/guide.md", "A repo named offset.", "offset"),
            ("docs/guide.md", "A project named cipher.", "cipher"),
            ("docs/guide.md", "A software named cipher.", "cipher"),
            ("docs/guide.md", "Taken from repo offset.", "offset"),
            ("docs/guide.md", "Taken from project cipher.", "cipher"),
            ("docs/guide.md", "Case-insensitive CHIALECODE/OFFSET and Cipher Repo.", "offset"),
            ("lib/sample.dart", "// 参考 offset 项目\n", "offset"),
            ("lib/sample.dart", "// See ../cipher for notes\n", "cipher"),
        )
        for rel, line, expected in cases:
            with self.subTest(rel=rel, line=line, expected=expected):
                self.write("docs/guide.md", GOOD_GUIDE)
                sample_dart = self.root / "lib" / "sample.dart"
                if sample_dart.exists():
                    sample_dart.unlink()
                body = (GOOD_GUIDE + "\n" + line + "\n") if rel.endswith(".md") else line
                self.write(rel, body)
                self.assertFlags(
                    f"forbidden reference or sibling repository name ({expected})",
                    self.run_check(),
                )

    def test_sibling_context_pattern_is_linear_on_long_whitespace_inputs(self) -> None:
        pat = check_docs._build_sibling_context_pattern("offset")
        spaces = " " * 50_000
        payloads = (
            f"参考{spaces}nomatch",
            f"参考项目：{spaces}nomatch",
            f"offset{spaces}nomatch",
            f"offset（{spaces}nomatch",
            f"offset ({spaces}nomatch",
            f"sibling repo{spaces}nomatch",
            f"《{spaces}nomatch",
            f"github.com/{'a' * 50_000}nomatch",
        )
        t0 = time.perf_counter()
        for payload in payloads:
            self.assertIsNone(pat.search(payload))
        elapsed = time.perf_counter() - t0
        self.assertLess(elapsed, 1.0, f"expected linear-time regex scan, took {elapsed:.3f}s")


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
