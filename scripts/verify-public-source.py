#!/usr/bin/env python3
"""Check the actual public candidate tree without printing secret values."""
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
EXCLUDED = {".git", ".build", ".swiftpm", "dist", "promo", "local-assets.noindex"}
TOKEN_PATTERNS = {
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "GitHub token": re.compile(r"\b(?:ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"),
    "AWS access key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "OpenAI-style token": re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}\b"),
}


def candidate_files():
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT, capture_output=True,
    )
    if result.returncode == 0:
        return sorted(set(filter(None, result.stdout.decode().split("\0"))))
    # A source ZIP or isolated public-source copy has no Git metadata.
    files = []
    for directory, children, names in os.walk(ROOT):
        children[:] = [name for name in children if name not in EXCLUDED]
        files.extend((Path(directory) / name).relative_to(ROOT).as_posix() for name in names)
    return sorted(files)


def main():
    errors = []
    files = candidate_files()
    for name in files:
        path = ROOT / name
        if path.is_symlink():
            errors.append(f"{name}: public source must not contain a filesystem symlink")
            continue
        if Path(name).parts[0] in EXCLUDED:
            errors.append(f"{name}: local/private output is included in Git")
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        except OSError:
            errors.append(f"{name}: candidate is missing or unreadable")
            continue
        if name.endswith(".json"):
            try:
                json.loads(content)
            except ValueError:
                errors.append(f"{name}: invalid JSON")
        for number, line in enumerate(content.splitlines(), 1):
            for label, pattern in TOKEN_PATTERNS.items():
                if pattern.search(line):
                    errors.append(f"{name}:{number}: possible {label} (value withheld)")
            if name.startswith(("docs/", "assets/")) and re.search(r"/Users/[^/\s`\"<>]+/", line):
                errors.append(f"{name}:{number}: unredacted user home in public documentation")
        if name.endswith(".md"):
            for link in re.findall(r"\]\(([^)]+)\)", content):
                link = unquote(link.split("#", 1)[0].split(' "', 1)[0]).strip("<>")
                if link and not re.match(r"[a-zA-Z][a-zA-Z0-9+.-]*:", link):
                    if not (path.parent / link).exists():
                        errors.append(f"{name}: missing relative Markdown target")
        if name.endswith(".sh"):
            first_line = content.splitlines()[0] if content else ""
            if not first_line.startswith("#!"):
                errors.append(f"{name}: shell script has no interpreter")
                continue
            syntax = subprocess.run(shlex.split(first_line[2:]) + ["-n", str(path)],
                                    capture_output=True)
            if syntax.returncode:
                errors.append(f"{name}: shell syntax error")
            if name.startswith("scripts/") and not path.stat().st_mode & 0o111:
                errors.append(f"{name}: verification/build entry point is not executable")
    for required in ["LICENSE", "THIRD_PARTY_NOTICES.md", "PRIVACY.md", "SECURITY.md", "CONTRIBUTING.md"]:
        if required not in files:
            errors.append(f"{required}: missing public project documentation")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"PASS public source: {len(files)} candidates; JSON, shell, links, modes and heuristic credential scan")
    return 0


if __name__ == "__main__":
    sys.exit(main())
