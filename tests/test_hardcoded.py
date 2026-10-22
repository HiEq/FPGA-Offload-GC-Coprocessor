"""Ratchet tests for tests/hardcoded.py.

One real-tree check plus a negative control per rule: a rule that stops matching
is caught here, not in a merged branch.
"""
import unittest

import hardcoded


class RuleTest(unittest.TestCase):
    def findings(self, rel, text, categories=("magic", "seed", "path")):
        return list(hardcoded.scan_text(rel, text, set(categories)))

    def test_magic_numbers_are_flagged(self):
        cases = {
            "rtl/x.v": "assign a = 12'h440;",
            "rtl/y.v": "assign b = 32'h47434343;",
            "csrc/x.c": "uint32_t base = 0x1E000000UL;",
            "python/x.py": "n = min(n, 4096)",
            "tools/x.ps1": "$baud = 115200",
        }
        for rel, line in cases.items():
            with self.subTest(line=line):
                self.assertEqual(len(self.findings(rel, line)), 1)

    def test_small_literals_and_comments_are_not_flagged(self):
        for rel, line in {
            "rtl/x.v": "assign a = 12'h0; reg [31:0] b;",
            "csrc/x.c": "for (int i = 0; i < 8; i++) { a |= (1U << 3); }",
            "python/x.py": "x = 42  # 4096 objects would be too many",
            "rtl/y.v": "// the 4096-object limit is documented in README",
            "tools/y.ps1": "# baud 115200 is the board default",
        }.items():
            with self.subTest(line=line):
                self.assertEqual(self.findings(rel, line), [])

    def test_named_constants_are_exempt(self):
        for rel, line in {
            "rtl/x.v": "    localparam integer DEPTH = 4096;",
            "csrc/x.h": "#define FPGA_BASE_ADDR   0x43C00000UL",
            "csrc/x.c": "static const uint32_t CAP = 4096;",
            "python/x.py": "CAP = 4096",
        }.items():
            with self.subTest(line=line):
                if line.startswith("CAP"):
                    # a plain assignment is still hardcoding; only declarations are exempt
                    self.assertEqual(len(self.findings(rel, line)), 1)
                else:
                    self.assertEqual(self.findings(rel, line), [])

    def test_seeds_must_come_from_a_variable(self):
        self.assertEqual(len(self.findings("python/x.py", "random.seed(42)", ("seed",))), 1)
        self.assertEqual(len(self.findings("python/x.py", "random.Random(20261019)", ("seed",))), 1)
        self.assertEqual(self.findings("python/x.py", "random.seed(args.seed)", ("seed",)), [])

    def test_host_paths_and_ports_are_flagged_but_device_paths_are_not(self):
        for line in ('$p = "C:\\Users\\bob\\f.log"', 'p = "/home/bob/f.log"',
                     "-Port COM5 -Baud 921600", "host = 192.168.1.10"):
            with self.subTest(line=line):
                self.assertEqual(len(self.findings("tools/x.ps1", line, ("path",))), 1)
        self.assertEqual(self.findings("csrc/x.c", 'p = "/mnt/userdata/tests";', ("path",)), [])

    def test_tests_are_exempt_except_for_secrets(self):
        self.assertTrue(hardcoded.is_test_file("sim/tb_gc_top.v"))
        self.assertTrue(hardcoded.is_test_file("tools/tests/gc_test.py"))
        self.assertFalse(hardcoded.is_test_file("rtl/gc_regs.v"))
        self.assertEqual(self.findings("sim/tb_x.v", "wdata = 32'hDEADBEEF;"), [])
        self.assertEqual(
            len(self.findings("sim/tb_x.v", "# key ghp_" + "a" * 36, ("secret",))), 1)

    def test_allow_marker_is_honoured(self):
        line = "uint32_t cap = 4096;  // allow-hardcoded: FIFO depth is a hardware contract"
        self.assertEqual(self.findings("csrc/x.c", line), [])


class BaselineTest(unittest.TestCase):
    def test_regressions_only_fire_above_the_baseline(self):
        findings = [("csrc/x.c", 1, "magic", "a"), ("csrc/x.c", 2, "magic", "b")]
        self.assertEqual(len(hardcoded.regressions(findings, {})), 1)
        self.assertEqual(hardcoded.regressions(findings, {("csrc/x.c", "magic"): 2}), [])
        self.assertEqual(hardcoded.regressions(findings, {("csrc/x.c", "magic"): 3}), [])

    def test_secrets_cannot_be_baselined(self):
        findings = [("csrc/x.c", 1, "secret", "ghp_x")]
        self.assertEqual(len(hardcoded.regressions(findings, {("csrc/x.c", "secret"): 1})), 1)


class RepositoryTest(unittest.TestCase):
    def test_no_new_hardcoded_literals_beyond_the_baseline(self):
        findings = hardcoded.scan()
        problems = hardcoded.regressions(findings, hardcoded.load_baseline())
        self.assertEqual(problems, [], "\n".join(problems))
        self.assertEqual([f for f in findings if f[2] == "secret"], [],
                         "a secret-shaped literal is in the tree")

    def test_baseline_file_is_not_empty(self):
        self.assertTrue(hardcoded.load_baseline(),
                        "tests/hardcoded_baseline.txt is missing; run --write-baseline")


if __name__ == "__main__":
    unittest.main()
