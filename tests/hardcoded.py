#!/usr/bin/env python3
"""Hardcoded-literal ratchet.

A gate that fails on every literal would be red on the existing tree and teach
people to bypass it. This one fails only when a file gains literals beyond its
baseline (`tests/hardcoded_baseline.txt`), so cleanup is never punished and new
hardcoding still needs a decision.

Five categories:

  magic   numeric literals >= 1000, hex >= 3 digits, Verilog sized literals.
          A `#define` / `parameter` / `localparam` / `const` line is exempt: that
          is the literal being named, which is the point.
  seed    `random.seed(<literal>)` / `random.Random(<literal>)`; seeds are replay
          evidence and must come from `--seed` or a named constant.
  path    host paths (`C:\\...`, `/home/<user>/...`), `COM<n>`, IPv4 literals.
          Device paths such as `/mnt/userdata` are a board contract, not a host path.
          Scanned in code files only (including `.bat`/`.cmd`).
  hostpath  the same absolute host paths in docs/config (`C:\\`, `/home/<user>/`,
          `/Users/<user>/`).  COM/IPv4 are not flagged in prose.
  secret  private-key blocks, cloud/token prefixes. Never baseline-able.

Escape hatch: a line containing `allow-hardcoded: <reason>` is skipped.

    python3 tests/hardcoded.py --check          # same rule as the unittest
    python3 tests/hardcoded.py --write-baseline # after an intentional addition

shortcut: the baseline counts per (file, category), so removing one literal and
adding another in the same file passes. Upgrade to per-literal keys if that ever
matters.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BASELINE = REPO / "tests/hardcoded_baseline.txt"
ALLOW = "allow-hardcoded"

# Scanned for every rule. Card copies, evidence logs and the gate itself are out.
SKIP_PREFIXES = ("artifacts/", "tools/logs/", "tests/")
SKIP_FILES = {"tests/hardcoded_baseline.txt", "AGENTS.md"}

CODE_EXTENSIONS = {".v", ".c", ".h", ".py", ".sh", ".ps1", ".tcl", ".bat", ".cmd"}
TEXT_EXTENSIONS = CODE_EXTENSIONS | {".md", ".txt", ".yml", ".yaml", ".json", ".cfg", ".conf", ".bb", ".mk"}


def is_test_file(rel):
    """Tests are the oracle: their stimulus and expectations must stay literal.

    AGENTS.md 4.3 requires an expected value that is not produced by the code
    under test, so a testbench full of constants is correct, not a smell. Only
    production and tooling sources are ratcheted.
    """
    name = Path(rel).name
    return (rel.startswith(("sim/", "tools/tests/"))
            or name in {"test_main.c"}
            or name.startswith(("tb_", "test_"))
            or name.endswith("_test.py"))

NAMED_CONSTANT = re.compile(
    r"^\s*(#\s*define|parameter|localparam|const|static\s+const|`define|typedef)\b"
)
COMMENT = re.compile(r"(?<!:)//.*$")

MAGIC = [
    re.compile(r"\b\d+'[hH][0-9a-fA-F_]{3,}"),      # Verilog 12'h440 / 32'h47434343
    re.compile(r"\b\d+'[dD]\d{4,}"),                 # Verilog 16'd4096
    re.compile(r"(?<![\w.])0[xX][0-9a-fA-F_]{3,}"),  # C/Python 0x1E000000
    re.compile(r"(?<![\w.])\d{4,}(?![\w.])"),        # bare 4096
]
SEED = [
    re.compile(r"random\.(?:seed|Random)\(\s*\d+\s*\)"),
]
PATH = [
    re.compile(r"\b[A-Za-z]:\\"),
    re.compile(r"/home/[A-Za-z0-9._-]+/"),
    re.compile(r"\bCOM\d{1,2}\b"),
    re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"),
]
# Docs/config: only absolute host paths.  A COM port or an IP in prose is
# often an example, so those stay in the code-only `path` rule.
HOST_PATH = [
    re.compile(r"\b[A-Za-z]:\\"),
    re.compile(r"/home/[A-Za-z0-9._-]+/"),
    re.compile(r"/Users/[A-Za-z0-9._-]+/"),
]
SECRET = [
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9]{20,}\b"),
]

RULES = (("secret", SECRET), ("seed", SEED), ("path", PATH),
         ("hostpath", HOST_PATH), ("magic", MAGIC))
BASELINE_ABLE = {"magic", "seed", "path", "hostpath"}


def tracked_text_files():
    out = subprocess.run(["git", "-C", str(REPO), "ls-files"], check=True,
                         capture_output=True, text=True).stdout
    for rel in out.splitlines():
        if not rel or rel in SKIP_FILES or rel.startswith(SKIP_PREFIXES):
            continue
        if Path(rel).suffix.lower() not in TEXT_EXTENSIONS:
            continue
        yield rel


def scan_text(rel, text, categories):
    """Yield (line_number, category, snippet) for one file's text.

    `categories` lets the tests exercise one rule at a time.
    """
    suffix = Path(rel).suffix.lower()
    code_file = suffix in CODE_EXTENSIONS
    for number, raw in enumerate(text.replace("\r\n", "\n").split("\n"), start=1):
        if ALLOW in raw:
            continue
        line = raw
        if code_file:
            line = COMMENT.sub("", line)
            if suffix in {".py", ".ps1", ".sh", ".tcl"}:
                line = re.sub(r"#.*$", "", line)
            if suffix in {".bat", ".cmd"}:
                line = re.sub(r"(?i)^\s*(rem\b|::).*$", "", line)
        for category, patterns in RULES:
            if category not in categories:
                continue
            if category not in ("secret", "hostpath") and (not code_file or is_test_file(rel)):
                continue
            if category == "hostpath" and is_test_file(rel):
                continue
            if category == "magic" and NAMED_CONSTANT.match(raw):
                continue
            if any(pattern.search(line) for pattern in patterns):
                yield number, category, raw.strip()[:120]
                break


def scan():
    findings = []
    for rel in tracked_text_files():
        text = (REPO / rel).read_text(encoding="utf-8")
        findings.extend((rel, number, category, snippet)
                        for number, category, snippet in scan_text(rel, text, set(BASELINE_ABLE) | {"secret"}))
    return findings


def load_baseline():
    baseline = {}
    if not BASELINE.is_file():
        return baseline
    for line in BASELINE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        count, category, rel = line.split(maxsplit=2)
        baseline[(rel, category)] = int(count)
    return baseline


def regressions(findings, baseline):
    counts = {}
    for rel, _, category, _ in findings:
        counts[(rel, category)] = counts.get((rel, category), 0) + 1
    problems = []
    for (rel, category), actual in sorted(counts.items()):
        allowed = baseline.get((rel, category), 0) if category in BASELINE_ABLE else 0
        if actual > allowed:
            delta = actual - allowed
            same = [f for f in findings if f[0] == rel and f[2] == category]
            # The baseline is per file, not per literal, so "new" is a guess: the
            # last ones are the most likely additions.
            likely = "; ".join(f"line {n}: {snippet}" for _, n, _, snippet in same[-delta:][:3])
            problems.append(
                f"{rel}: +{delta} new {category} literal(s) (baseline {allowed}); "
                f"likely {likely}"
            )
    return problems


def write_baseline(findings):
    counts = {}
    for rel, _, category, _ in findings:
        if category in BASELINE_ABLE:
            counts[(rel, category)] = counts.get((rel, category), 0) + 1
    lines = [
        "# Hardcoded-literal baseline: <count> <category> <path>.",
        "# Regenerate with `python3 tests/hardcoded.py --write-baseline` after an",
        "# intentional addition; removing entries is always allowed.",
    ]
    lines += [f"{count} {category} {rel}" for (rel, category), count in sorted(counts.items())]
    BASELINE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(counts)


def main(argv):
    if len(argv) != 2 or argv[1] not in ("--check", "--write-baseline"):
        print("usage: hardcoded.py --check | --write-baseline", file=sys.stderr)
        return 2
    findings = scan()
    if argv[1] == "--write-baseline":
        print(f"baseline entries: {write_baseline(findings)}")
        return 0
    problems = regressions(findings, load_baseline())
    secrets = [f for f in findings if f[2] == "secret"]
    for rel, number, category, snippet in secrets:
        problems.append(f"{rel}:{number}: secret-shaped literal: {snippet}")
    for problem in problems:
        print(f"HARDCODED: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
