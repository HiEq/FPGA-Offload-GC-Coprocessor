#!/usr/bin/env python3
"""Commit / pull-request policy gates.

The same rules run in three places:

  * .githooks/commit-msg   - one commit, before it exists
  * CI job `commit-policy` - every non-merge commit in the PR range
  * CI job `pr-policy`     - PR title, head branch, evidence block

They are pure functions over text so tests/test_gate.py can prove each rule
rejects a bad input. A gate that cannot fail is not a gate.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

TYPES = ("feat", "fix", "docs", "test", "refactor", "perf", "build", "ci", "chore", "revert")

SUBJECT_RE = re.compile(
    r"^(?P<type>" + "|".join(TYPES) + r")"
    r"(\((?:[a-z0-9][a-z0-9._/-]*)\))?!?: (?P<subject>\S.*)$"
)
BRANCH_RE = re.compile(r"^(feat|fix|docs|test|refactor|perf|build|ci|chore)/[a-z0-9][a-z0-9._-]*$")

MAX_SUBJECT = 72
MAX_BODY_LINE = 100
MIN_SUBJECT = 10


def check_subject(line: str) -> list[str]:
    """Rules for the first line of a commit message or the PR title."""
    match = SUBJECT_RE.match(line)
    if not match:
        return [
            "subject must be `<type>(<scope>): <description>` with one of: "
            + ", ".join(TYPES)
        ]
    problems = []
    if len(line) > MAX_SUBJECT:
        problems.append(f"subject is {len(line)} chars (max {MAX_SUBJECT})")
    if line.endswith("."):
        problems.append("subject must not end with a period")
    subject = match.group("subject")
    if subject[0].isupper():
        problems.append("subject must start in lower case")
    if len(subject) < MIN_SUBJECT:
        problems.append(f"subject is too short to describe the change (min {MIN_SUBJECT} chars)")
    return problems


def check_message(text: str) -> list[str]:
    """Rules for a whole commit message."""
    lines = text.replace("\r\n", "\n").split("\n")
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines:
        return ["empty commit message"]
    problems = check_subject(lines[0])
    if len(lines) > 1:
        if lines[1].strip():
            problems.append("line 2 must be blank before the body")
        for number, line in enumerate(lines[2:], start=3):
            if len(line) > MAX_BODY_LINE:
                problems.append(f"line {number} is {len(line)} chars (max {MAX_BODY_LINE})")
    return problems


def check_branch(name: str) -> list[str]:
    if BRANCH_RE.match(name):
        return []
    return ["branch must be `<type>/<slug>` (type as in the commit types, slug [a-z0-9._-])"]


def check_pr(fields: dict) -> list[str]:
    """Rules for a pull request: title, head branch, target branch, evidence block."""
    problems = [f"PR title: {p}" for p in check_subject(fields.get("title", ""))]
    problems += check_branch(fields.get("head_ref", ""))
    default = fields.get("default_branch", "main")
    base = fields.get("base_ref", "")
    if base != default:
        problems.append(f"PR must target {default}, not {base}")
    body = (fields.get("body") or "").lower()
    for marker in ("verified:", "unverified:"):
        if marker not in body:
            problems.append(f"PR body must contain a `{marker}` line (AGENTS.md 4.8)")
    return problems


def _git(*args: str) -> str:
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def check_range(base: str, head: str) -> list[str]:
    """Every non-merge commit in base..head must pass check_message."""
    shas = _git("rev-list", "--no-merges", f"{base}..{head}").split()
    if not shas:
        return [f"no non-merge commits in {base}..{head}"]
    problems = []
    for sha in shas:
        message = _git("log", "-1", "--format=%B", sha)
        print(f"{sha[:12]} {message.splitlines()[0]}")
        problems += [f"{sha[:12]}: {p}" for p in check_message(message)]
    return problems


def main(argv: list[str]) -> int:
    usage = (
        "usage: gate.py commit-msg <file>\n"
        "       gate.py range <base> <head>\n"
        "       gate.py pr <event.json>"
    )
    if len(argv) < 2:
        print(usage, file=sys.stderr)
        return 2

    command = argv[1]
    if command == "commit-msg" and len(argv) == 3:
        problems = check_message(Path(argv[2]).read_text(encoding="utf-8"))
    elif command == "range" and len(argv) == 4:
        problems = check_range(argv[2], argv[3])
    elif command == "pr" and len(argv) == 3:
        event = json.loads(Path(argv[2]).read_text(encoding="utf-8"))
        pull = event["pull_request"]
        problems = check_pr(
            {
                "title": pull.get("title", ""),
                "body": pull.get("body"),
                "head_ref": pull["head"]["ref"],
                "base_ref": pull["base"]["ref"],
                "default_branch": event["repository"]["default_branch"],
            }
        )
    else:
        print(usage, file=sys.stderr)
        return 2

    for problem in problems:
        print(f"POLICY: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
