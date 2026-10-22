"""Negative controls for tests/gate.py.

Each rule gets a passing case and a failing case, so a rule that silently stops
checking anything is caught here instead of in a merged branch.
"""
import unittest

import gate


class CommitSubjectTest(unittest.TestCase):
    def test_accepts_conventional_subjects(self):
        for line in (
            "fix(axi): drop the same-cycle R beat on run_start",
            "docs(readme): regroup sections and trim duplicated evidence",
            "ci: require code owner review on the default branch",
            "test(rtl): add T-STAR coverage for the 4096-object wrap",
            "revert: restore the previous queue depth",
        ):
            with self.subTest(line=line):
                self.assertEqual(gate.check_subject(line), [])

    def test_rejects_non_conventional_subjects(self):
        for line in (
            "Update README with XSA source and board details",
            "fixed stuff",
            "feat add ci gates",
            "feature: add ci gates",
            "fix(axi): drop the same-cycle R beat on run_start.",
            "fix(axi):Drop the beat",
            "fix(axi): ok",
            "fix(axi): " + "x" * 70,
        ):
            with self.subTest(line=line):
                self.assertNotEqual(gate.check_subject(line), [], "rule accepted a bad subject")


class CommitMessageTest(unittest.TestCase):
    def test_accepts_message_with_body_and_evidence(self):
        message = (
            "ci(gate): block merges without a verified line\n"
            "\n"
            "verified: python3 -m unittest discover -s tests\n"
            "coverage: not measured\n"
        )
        self.assertEqual(gate.check_message(message), [])

    def test_rejects_body_without_blank_second_line(self):
        problems = gate.check_message("ci: add the gate workflow\nbecause reasons\n")
        self.assertTrue(any("line 2" in p for p in problems), problems)

    def test_rejects_overlong_body_line(self):
        problems = gate.check_message("ci: add the gate workflow\n\n" + "y" * 120 + "\n")
        self.assertTrue(any("max 100" in p for p in problems), problems)

    def test_rejects_empty_message(self):
        self.assertEqual(gate.check_message("\n\n"), ["empty commit message"])


class BranchTest(unittest.TestCase):
    def test_accepts_typed_branches(self):
        for name in ("ci/strict-gates", "fix/axi-flush", "docs/rules"):
            with self.subTest(name=name):
                self.assertEqual(gate.check_branch(name), [])

    def test_rejects_untyped_branches(self):
        for name in ("main", "dev-hieq", "patch", "Feature/Gates", "ci/", "ci/Upper"):
            with self.subTest(name=name):
                self.assertNotEqual(gate.check_branch(name), [], "rule accepted a bad branch")


class PullRequestTest(unittest.TestCase):
    def fields(self, **overrides):
        base = {
            "title": "ci(gate): enforce contract and review gates",
            "body": "verified: unit tests\nunverified: no board run\n",
            "head_ref": "ci/strict-gates",
            "base_ref": "main",
            "default_branch": "main",
        }
        base.update(overrides)
        return base

    def test_accepts_a_compliant_pr(self):
        self.assertEqual(gate.check_pr(self.fields()), [])

    def test_rejects_bad_title(self):
        problems = gate.check_pr(self.fields(title="Add CI"))
        self.assertTrue(any("PR title" in p for p in problems), problems)

    def test_rejects_wrong_base(self):
        problems = gate.check_pr(self.fields(base_ref="dev-hieq"))
        self.assertTrue(any("must target main" in p for p in problems), problems)

    def test_rejects_missing_evidence_markers(self):
        problems = gate.check_pr(self.fields(body="it works"))
        self.assertEqual(len([p for p in problems if "must contain" in p]), 2, problems)

    def test_rejects_main_as_head(self):
        problems = gate.check_pr(self.fields(head_ref="main"))
        self.assertTrue(any("branch must be" in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main()
