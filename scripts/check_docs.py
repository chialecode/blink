"""Zero-dependency documentation, link, layout, and publication hygiene checks for BLINK.

Run from any directory:
    python scripts/check_docs.py
Supports --root and --ref-dir for isolated fixture verification.
"""

from __future__ import annotations

import argparse
from collections import Counter
import os
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit


EXCLUDED = {
    ".git",
    ".local",
    ".tools",
    ".venv",
    "node_modules",
    "target",
    "dist",
    "build",
    ".dart_tool",
    "vendor",
    "third-party",
    "__pycache__",
    ".pytest_cache",
    ".ruff_cache",
    ".mypy_cache",
    ".worktrees",
    "artifacts",
    "tmp",
    "coverage",
    "reference",
    ".idea",
    ".vscode",
    ".claude",
    ".codex",
}

# Flutter-generated, Git-ignored platform outputs. Exempt only at their real
# locations (`<platform>/flutter/ephemeral`, `<platform>/.symlinks`,
# `.../ephemeral/.plugin_symlinks`) so a tracked directory that merely shares
# one of these names elsewhere is still fully checked.
FLUTTER_PLATFORM_DIRS = frozenset({"windows", "linux", "macos", "ios"})
FLUTTER_SYMLINK_DIRS = frozenset({".symlinks", ".plugin_symlinks"})


def is_flutter_generated_dir(parent: Path, name: str) -> bool:
    parent_name = parent.name.lower()
    if name == "ephemeral":
        return parent_name == "flutter" and parent.parent.name.lower() in FLUTTER_PLATFORM_DIRS
    if name in FLUTTER_SYMLINK_DIRS:
        return parent_name in FLUTTER_PLATFORM_DIRS or parent_name == "ephemeral"
    return False


FLUTTER_EPHEMERAL_FILE_RE = re.compile(
    r"(?:^|/)(?:ios/Flutter|macos/Flutter/ephemeral)/flutter_export_environment\.sh$"
)

REQUIRED_ROOT_FILES = (
    "LICENSE",
    "README.md",
    "AGENTS.md",
    "CLAUDE.md",
    "LESSONS.md",
    "CONTRIBUTING.md",
    "REVIEW.md",
    "SECURITY.md",
)

REQUIRED_DOCS_FILES = (
    "docs/README.md",
    "docs/requirements.md",
    "docs/decisions.md",
    "docs/delivery/roadmap.md",
    "docs/design/architecture.md",
    "docs/dev-rules/workflow.md",
    "docs/dev-rules/engineering.md",
    "docs/dev-rules/sources-and-safety.md",
)

ALLOWED_DOCS_SUBDIRS = {
    "delivery",
    "design",
    "research",
    "dev-rules",
    "templates",
    "evidence",
}

DATED_RESEARCH_RE = re.compile(r"^\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*\.md$")
KEBAB_MD_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*\.md$")
FRONTMATTER_START_RE = re.compile(r"^---[ \t]*(?:\r?\n|$)")
FENCE_OPEN_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
INLINE_CODE_RE = re.compile(r"(`+)([^`\n]*?)\1")
REF_LINK_DEF_RE = re.compile(r"^[ \t]{0,3}\[[^\]\n^][^\n\]]*\]:[ \t]+\S+", re.M)
REF_LINK_USE_RE = re.compile(r"!?\[[^\]\n]+\]\[[^\]\n]*\]")
INLINE_LINK_RE = re.compile(r"!?\[[^\]\n]*\]\((<[^>]+>|[^\s)]+)(?:\s+(?:\"[^\"]*\"|'[^']*'))?\)")
HEADING_RE = re.compile(r"^ {0,3}#{1,6}[ \t]+(.+?)[ \t]*#*[ \t]*$", re.M)
HTML_ANCHOR_RE = re.compile(r'<(?:a|h[1-6]|span|div)\b[^>]*\b(?:id|name)=["\']([^"\']+)["\']', re.I)
REF_HEADING_RE = re.compile(r"^#{2,4}[ \t]+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)[ \t]*$", re.M)

FORBIDDEN_FILE_PATTERNS = (
    re.compile(r"(?:^|/)\.env(?:\.(?!example$)[^/]+)?$", re.I),
    re.compile(r"\.(?:sqlite|sqlite3|db|wal|shm|pem|key|p12|pfx)$", re.I),
    re.compile(r"\.(?:sqlite|db)-[^/]+$", re.I),
    re.compile(r"(?:^|/)id_(?:rsa|ed25519|ecdsa|dsa)(?:\.pub)?$", re.I),
)

WIN_ABS_PATH_RE = re.compile(r"(?<![A-Za-z0-9_])[A-Za-z]:[\\/][A-Za-z0-9_.\u4e00-\u9fff-]")
UNIX_HOME_PATH_RE = re.compile(r"(?<![A-Za-z0-9._/-])/(?:Users|home)/[A-Za-z0-9._-]+")

SECRET_PATTERNS = (
    ("private key block", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----")),
    ("API secret key", re.compile(r"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}\b")),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b")),
    ("AWS access key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("credential-embedded URL", re.compile(r"https?://[^/\s:@\"'`]+:[^/\s@\"'`]+@[^/\s\"'`]+")),
    (
        "session or cookie token",
        re.compile(
            r"(?i)\b(?:SESSDATA|bili_jct|DedeUserID__ckMd5|ac_time_value|"
            r"sessionid|sessionid_ss|sid_guard|msToken)=[A-Za-z0-9%][A-Za-z0-9%|._-]{5,}"
        ),
    ),
    (
        "signed URL parameter",
        re.compile(
            r"(?i)https?://[^\s\"'<>`]*(?:a_bogus=[A-Za-z0-9%+/=._-]{4,}|"
            r"x-(?:secsdk-web-)?signature(?:=[A-Za-z0-9%+/=._-]{4,}|/[A-Za-z0-9%+/=._-]{4,}))"
        ),
    ),
    (
        "hardcoded credential assignment",
        re.compile(
            r"(?i)[\"']?(?:api[_-]?key|access[_-]?token|client[_-]?secret|secret[_-]?key)"
            r"[\"']?\s*[:=]\s*[\"'][A-Za-z0-9_+/\-=]{20,}[\"']"
        ),
    ),
)

TEXT_EXTENSIONS = {
    ".md",
    ".json",
    ".toml",
    ".yml",
    ".yaml",
    ".py",
    ".dart",
    ".arb",
    ".ps1",
    ".sh",
    ".bat",
    ".cmd",
    ".txt",
}

# Extensionless or dot-named text files that still need hygiene scanning.
TEXT_FILENAMES = {".editorconfig", ".gitattributes", ".gitignore", "CODEOWNERS"}
TEXT_DIRS = {".githooks"}
CRLF_ALLOWED_EXTENSIONS = {".bat", ".cmd"}

EXTERNAL_URL_STRIP_RE = re.compile(r"https?://(?!github\.com/chialecode/)[^\s\"'<>`)]+", re.I)


def strip_fenced_code(text: str) -> str:
    """Replace fenced code blocks (backtick or tilde) with blank lines to preserve line numbers."""
    out: list[str] = []
    fence: str | None = None
    for line in text.splitlines():
        if fence is None:
            match = FENCE_OPEN_RE.match(line)
            if match:
                fence = match.group(1)
                out.append("")
                continue
            out.append(line)
        else:
            stripped = line.strip()
            if len(stripped) >= len(fence) and set(stripped) == {fence[0]}:
                fence = None
            out.append("")
    return "\n".join(out)


def strip_code_blocks_and_spans(text: str) -> str:
    """Strip both fenced code blocks and inline code spans."""
    non_fenced = strip_fenced_code(text)
    return "\n".join(INLINE_CODE_RE.sub(" ", line) for line in non_fenced.splitlines())


def collect_anchors(text: str) -> set[str]:
    """Collect explicit HTML id/name anchors and GitHub-flavored heading slugs."""
    non_fenced = strip_fenced_code(text)
    found: set[str] = set()
    counts: Counter[str] = Counter()

    for anchor in HTML_ANCHOR_RE.findall(non_fenced):
        cleaned = anchor.strip().lower()
        if cleaned:
            found.add(cleaned)

    for raw_heading in HEADING_RE.findall(non_fenced):
        heading = re.sub(r"<[^>]+>", "", raw_heading)
        heading = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", heading)
        heading = heading.replace("`", "").strip().lower()
        kept = "".join(ch for ch in heading if ch.isalnum() or ch in "_-" or ch.isspace())
        slug = re.sub(r"\s", "-", kept)
        if slug:
            suffix = f"-{counts[slug]}" if counts[slug] else ""
            found.add(f"{slug}{suffix}")
            counts[slug] += 1
        collapsed = re.sub(r"-+", "-", slug).strip("-")
        if collapsed:
            found.add(collapsed)

    return found


def find_reference_index_file(root: Path, ref_dir_override: str | None) -> Path | None:
    """Locate external reference index file via --ref-dir, BLINK_REFERENCE_DIR, or ancestor scan."""
    candidates = ("README.md", "INDEX.md", "REFERENCE.md")

    def probe_dir(directory: Path) -> Path | None:
        if not directory.is_dir():
            return None
        for name in candidates:
            candidate = directory / name
            if candidate.is_file():
                return candidate
        return None

    if ref_dir_override is not None and ref_dir_override.strip():
        return probe_dir(Path(ref_dir_override.strip()))

    env_dir = os.environ.get("BLINK_REFERENCE_DIR", "").strip()
    if env_dir:
        return probe_dir(Path(env_dir))

    repo_name = root.name
    cur = root.parent
    for _ in range(6):
        found = probe_dir(cur / "reference" / repo_name)
        if found is not None:
            return found
        if cur.parent == cur:
            break
        cur = cur.parent
    return None


def load_forbidden_repo_terms(
    root: Path,
    ref_dir_override: str | None,
) -> tuple[list[tuple[str, re.Pattern[str], bool]], str]:
    """Load reference-index and sibling project names dynamically without hardcoding any names.

    Returns ([(term, compiled_regex, strip_non_owner_urls)], status_message).
    """
    repo_lower = root.name.lower()
    seen: set[str] = set()
    entries: list[tuple[str, re.Pattern[str], bool]] = []

    def add_term(term: str, *, strip_urls: bool) -> None:
        cleaned = term.strip()
        key = cleaned.lower()
        if not cleaned or key == repo_lower or key == f"chialecode/{repo_lower}" or key in seen:
            return
        seen.add(key)
        # A trailing dot only continues the token when another identifier character follows
        # (file extension or domain); a sentence-ending period must not hide the name.
        if "/" in cleaned:
            pat = re.compile(
                rf"(?<![A-Za-z0-9_.-]){re.escape(cleaned)}(?![A-Za-z0-9_-]|\.[A-Za-z0-9])", re.I
            )
        else:
            pat = re.compile(
                rf"(?<![A-Za-z0-9_.-]){re.escape(cleaned)}(?![A-Za-z0-9_(-]|\.[A-Za-z0-9])", re.I
            )
        entries.append((cleaned, pat, strip_urls))

    explicit_override = bool(
        (ref_dir_override is not None and ref_dir_override.strip())
        or os.environ.get("BLINK_REFERENCE_DIR", "").strip()
    )

    ref_index = find_reference_index_file(root, ref_dir_override)
    ref_count = 0
    if ref_index is not None:
        try:
            raw = ref_index.read_text(encoding="utf-8-sig")
            for full in REF_HEADING_RE.findall(raw):
                before = len(entries)
                add_term(full, strip_urls=False)
                _, _, repo_part = full.partition("/")
                if len(repo_part) >= 5:
                    add_term(repo_part, strip_urls=False)
                ref_count += len(entries) - before
        except OSError:
            pass

    sibling_count = 0
    if not explicit_override:
        cur = root.parent
        for _ in range(4):
            ref_root = cur / "reference"
            if ref_root.is_dir():
                try:
                    for child in sorted(ref_root.iterdir()):
                        if child.is_dir() and not child.name.startswith("."):
                            before = len(entries)
                            add_term(child.name, strip_urls=True)
                            sibling_count += len(entries) - before
                except OSError:
                    pass
                break
            if cur.parent == cur:
                break
            cur = cur.parent

        if root.parent.is_dir():
            try:
                for child in sorted(root.parent.iterdir()):
                    if child.is_dir() and not child.name.startswith(".") and (child / ".git").exists():
                        before = len(entries)
                        add_term(child.name, strip_urls=True)
                        sibling_count += len(entries) - before
            except OSError:
                pass

    if not entries:
        return [], "check_docs: no local reference index or sibling repos found; skipping reference-name check"
    return (
        entries,
        f"check_docs: loaded {ref_count} reference-index term(s) and {sibling_count} sibling-repo term(s)",
    )


def check(
    root: Path,
    *,
    ref_dir_override: str | None = None,
    check_layout: bool = True,
) -> tuple[list[str], int, str]:
    root = root.resolve()
    errors: list[str] = []

    if check_layout:
        for rel in (*REQUIRED_ROOT_FILES, *REQUIRED_DOCS_FILES):
            target = root / rel
            if not target.is_file():
                errors.append(f"missing required file: {rel}")

        readme_path = root / "README.md"
        if readme_path.is_file():
            try:
                if not readme_path.read_text(encoding="utf-8-sig").strip():
                    errors.append("README.md: must not be empty on M1+ baseline")
            except (OSError, UnicodeDecodeError) as exc:
                errors.append(f"README.md: unreadable UTF-8 text: {exc}")

        research_dir = root / "docs" / "research"
        if not research_dir.is_dir():
            errors.append("missing required directory: docs/research")
        else:
            dated_docs = [
                p.name
                for p in research_dir.iterdir()
                if p.is_file() and DATED_RESEARCH_RE.match(p.name)
            ]
            if not dated_docs:
                errors.append(
                    "docs/research: expected at least one dated research file matching YYYY-MM-DD-<topic>.md"
                )

        docs_dir = root / "docs"
        if docs_dir.is_dir():
            for child in sorted(docs_dir.iterdir()):
                if child.is_dir() and child.name not in ALLOWED_DOCS_SUBDIRS:
                    errors.append(
                        f"docs/{child.name}: unexpected docs subdirectory "
                        f"(allowed: {', '.join(sorted(ALLOWED_DOCS_SUBDIRS))})"
                    )

    documents: dict[str, str] = {}
    anchor_cache: dict[str, set[str]] = {}
    forbidden_terms, info_msg = load_forbidden_repo_terms(root, ref_dir_override)

    for directory, children, files in os.walk(root, followlinks=False):
        current = Path(directory)
        children[:] = sorted(
            name
            for name in children
            if name not in EXCLUDED and not is_flutter_generated_dir(current, name)
        )
        for filename in sorted(files):
            path = Path(directory) / filename
            rel = path.relative_to(root).as_posix()
            if FLUTTER_EPHEMERAL_FILE_RE.search(rel):
                continue

            try:
                resolved = path.resolve()
            except OSError as exc:
                errors.append(f"{rel}: cannot resolve path: {exc}")
                continue
            if not resolved.is_relative_to(root):
                errors.append(f"{rel}: symlink escapes repository root")
                continue

            for pattern in FORBIDDEN_FILE_PATTERNS:
                if pattern.search(rel):
                    errors.append(f"{rel}: forbidden sensitive or database file in repository")

            suffix = path.suffix.lower()
            is_text = (
                suffix in TEXT_EXTENSIONS
                or filename in TEXT_FILENAMES
                or rel.split("/", 1)[0] in TEXT_DIRS
            )
            if not is_text:
                continue

            try:
                raw_bytes = path.read_bytes()
            except OSError as exc:
                errors.append(f"{rel}: cannot read file: {exc}")
                continue

            if raw_bytes.startswith(b"\xef\xbb\xbf"):
                errors.append(f"{rel}: UTF-8 BOM is not allowed")
            if b"\r\n" in raw_bytes and suffix not in CRLF_ALLOWED_EXTENSIONS:
                errors.append(f"{rel}: CRLF line endings are not allowed (use LF)")

            try:
                text = raw_bytes.decode("utf-8")
            except UnicodeDecodeError as exc:
                errors.append(f"{rel}: invalid UTF-8 encoding: {exc}")
                continue

            if suffix == ".md":
                documents[rel] = text
                if FRONTMATTER_START_RE.match(text):
                    errors.append(f"{rel}: YAML frontmatter ('---' at start of file) is forbidden")
                if rel.startswith("docs/") and rel != "docs/README.md":
                    if not KEBAB_MD_RE.match(path.name):
                        errors.append(f"{rel}: docs Markdown filename must use lowercase kebab-case.md")

            if rel != "scripts/check_docs.py":
                for line_no, line in enumerate(text.splitlines(), start=1):
                    if WIN_ABS_PATH_RE.search(line):
                        errors.append(f"{rel}:{line_no}: contains machine-specific Windows absolute path")
                    if UNIX_HOME_PATH_RE.search(line):
                        errors.append(f"{rel}:{line_no}: contains machine-specific Unix home path")
                    for category, secret_re in SECRET_PATTERNS:
                        if secret_re.search(line):
                            errors.append(f"{rel}:{line_no}: contains forbidden {category}")

                if forbidden_terms:
                    stripped_urls_text = EXTERNAL_URL_STRIP_RE.sub(" ", text)
                    for term, term_re, strip_urls in forbidden_terms:
                        haystack = stripped_urls_text if strip_urls else text
                        if term_re.search(haystack):
                            errors.append(
                                f"{rel}: contains forbidden reference or sibling repository name ({term})"
                            )

    if "CLAUDE.md" in documents or check_layout:
        claude_text = documents.get("CLAUDE.md")
        if claude_text is not None and claude_text.rstrip("\r\n") != "@AGENTS.md":
            errors.append("CLAUDE.md: must contain strictly '@AGENTS.md' (single line)")

    for rel, text in sorted(documents.items()):
        prose_no_code = strip_code_blocks_and_spans(text)

        if REF_LINK_DEF_RE.search(prose_no_code) or REF_LINK_USE_RE.search(prose_no_code):
            errors.append(f"{rel}: reference-style Markdown links are forbidden; use inline relative links")

        for match in INLINE_LINK_RE.finditer(prose_no_code):
            target = match.group(1).strip().strip("<>")
            if not target:
                errors.append(f"{rel}: empty Markdown link target")
                continue

            parsed = urlsplit(target)
            scheme = parsed.scheme.lower()
            if scheme == "file":
                errors.append(f"{rel}: file:// links are forbidden: {target}")
                continue
            if scheme in {"http", "https", "mailto"}:
                continue
            if scheme:
                errors.append(f"{rel}: unsupported link scheme in {target!r}")
                continue
            if parsed.netloc:
                errors.append(f"{rel}: network-path relative link is forbidden: {target}")
                continue
            if "\\" in target or parsed.path.startswith("/"):
                errors.append(f"{rel}: use portable forward-slash relative link: {target}")
                continue

            dest = (
                ((root / rel).parent / unquote(parsed.path)).resolve()
                if parsed.path
                else (root / rel).resolve()
            )
            if not dest.is_relative_to(root):
                errors.append(f"{rel}: link escapes repository root: {target}")
                continue
            if not dest.exists():
                errors.append(f"{rel}: broken relative link target: {target}")
                continue

            if parsed.fragment:
                anchor_target: Path | None = None
                if dest.is_file() and dest.suffix.lower() == ".md":
                    anchor_target = dest
                elif dest.is_dir() and (dest / "README.md").is_file():
                    anchor_target = dest / "README.md"

                if anchor_target is not None:
                    target_rel = anchor_target.relative_to(root).as_posix()
                    if target_rel not in anchor_cache:
                        anchor_cache[target_rel] = collect_anchors(documents.get(target_rel, ""))
                    wanted = unquote(parsed.fragment).strip().lower()
                    if wanted not in anchor_cache[target_rel]:
                        errors.append(f"{rel}: missing anchor #{parsed.fragment} in {target}")

    return errors, len(documents), info_msg


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Repository root directory (defaults to parent of scripts/).",
    )
    parser.add_argument(
        "--ref-dir",
        type=str,
        default=None,
        help="Optional external reference index directory override.",
    )
    parser.add_argument(
        "--no-layout-check",
        action="store_true",
        help="Skip required M1 file tree check (for isolated fixture tests).",
    )
    args = parser.parse_args(argv)

    try:
        errors, md_count, info_msg = check(
            args.root,
            ref_dir_override=args.ref_dir,
            check_layout=not args.no_layout_check,
        )
    except (OSError, ValueError, TypeError) as exc:
        print(f"FAIL: check_docs internal error: {exc}", file=sys.stderr)
        return 1

    if info_msg:
        print(info_msg)
    if errors:
        for err in errors:
            print(f"FAIL: {err}", file=sys.stderr)
        return 1

    print(f"PASS: {md_count} Markdown document(s) passed layout, link, anchor, and hygiene checks.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
