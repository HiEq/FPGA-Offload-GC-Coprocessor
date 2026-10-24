"""Static contracts for the parts CI can check without hardware.

Nothing here compiles RTL, runs xsim or touches a board. These checks prove the
sources, the register map, the documentation and the workflow files agree with
each other; they do not prove the design works (README 测量口径, AGENTS.md 4.2).
"""
import json
import re
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

# Files that are allowed to be binary in the index (card payloads, mkimage output).
BINARY_ALLOWED = {
    "artifacts/boot.scr",
    "artifacts/userdata/bin/test_main",
    "artifacts/userdata/py/libfogccc.so",
}
MAX_TRACKED_BYTES = 1 << 20

STATUS_SIGNAL = {
    "OVF": "err_ovf",
    "RDERR": "err_rd",
    "REFDESYNC": "err_ref",
    "HDR": "err_hdr",
    "IDLE": "reg_idle",
    "FREEBUSY": "reg_free_busy",
}


# ---------------------------------------------------------------- helpers

def read(rel):
    return (REPO / rel).read_text(encoding="utf-8")


def tracked():
    out = subprocess.run(["git", "-C", str(REPO), "ls-files"], check=True,
                         capture_output=True, text=True).stdout
    return [line for line in out.splitlines() if line]


def parse_header_regs(text):
    return {
        int(offset, 16): name
        for name, offset in re.findall(
            r"(?m)^#define\s+REG_([A-Z0-9_]+)\s+(0x[0-9A-Fa-f]+)", text
        )
    }


def parse_readme_regs(text):
    return {
        int(offset, 16): name
        for offset, name in re.findall(
            r"(?m)^\|\s*0x([0-9A-Fa-f]{2,3})\+?\s*\|\s*([A-Z][A-Z0-9_]*)\s*\|", text
        )
    }


def parse_rtl_decodes(text):
    """Return (write_offsets, read_offsets) as decoded by gc_regs.v."""
    write = text[text.index("if (WVALID && WREADY)"):text.index("if (aw_pending && w_pending")]
    reads = text[text.index("if (ARREADY && !RVALID)"):text.index("if (RVALID && RREADY)")]

    def labels(region):
        return {int(value, 16) for value in re.findall(r"12'h([0-9A-Fa-f]{3})\s*:", region)}

    return labels(write), labels(reads)


def parse_status_header(text):
    return {
        int(bit): name
        for name, bit in re.findall(
            r"(?m)^#define\s+STATUS_([A-Z]+)\s+\(1U\s*<<\s*(\d+)\)", text
        )
    }


def parse_status_rtl(text):
    match = re.search(r"12'h020:\s*RDATA\s*<=\s*\{([^}]*)\}", text)
    fields = [field.strip() for field in match.group(1).split(",")]
    # Drop zero padding such as 27'h0; keep only named signals.
    return [field for field in fields if not re.fullmatch(r"\d+'h[0-9A-Fa-f_]+", field)]


def parse_status_readme(text):
    row = next(
        line for line in text.splitlines()
        if re.match(r"^\|\s*0x20\s*\|\s*STATUS\s*\|", line)
    )
    return {int(bit) for bit in re.findall(r"\[(\d)\]", row)}


def parse_hex(value):
    return int(value.replace("_", ""), 16)


# ---------------------------------------------------------------- register map

class RegisterMapTest(unittest.TestCase):
    def setUp(self):
        self.header = parse_header_regs(read("csrc/fpga_gc.h"))
        self.readme = parse_readme_regs(read("README.md"))
        self.writes, self.reads = parse_rtl_decodes(read("rtl/gc_regs.v"))

    def test_header_offsets_are_implemented_in_rtl(self):
        self.assertEqual(
            set(self.header) - self.reads,
            {self.header_index("ROOT_LIST")},
            "an offset exists in fpga_gc.h but gc_regs.v does not decode it",
        )
        self.assertEqual(
            self.reads - set(self.header),
            set(),
            "gc_regs.v decodes an offset that fpga_gc.h does not define",
        )

    def test_write_offsets_match_the_header(self):
        expected = {
            self.header_index("CTRL"),
            self.header_index("OBJ_BASE"),
            self.header_index("OBJ_COUNT"),
            self.header_index("ROOT_COUNT"),
            self.header_index("BM_ADDR"),
            self.header_index("DIRTY_PUSH"),
        }
        self.assertEqual(self.writes, expected)

    def test_readme_table_matches_the_header(self):
        self.assertEqual(self.readme, self.header)

    def test_root_list_window_matches_root_mem(self):
        regs = read("rtl/gc_regs.v")
        match = re.search(
            r"awaddr_r\s*>=\s*12'h([0-9A-Fa-f]{3})\)\s*&&\s*\(awaddr_r\s*<\s*12'h([0-9A-Fa-f]{3})",
            regs,
        )
        low, high = (parse_hex(match.group(1)), parse_hex(match.group(2)))
        depth = int(re.search(r"root_mem\s*\[0:(\d+)\]", read("rtl/gc_top.v")).group(1)) + 1
        self.assertEqual(low, self.header_index("ROOT_LIST"))
        self.assertEqual((high - low) // 4, depth, "root window and root_mem disagree")

    def test_negative_control_moved_offset_is_detected(self):
        mutated = read("rtl/gc_regs.v").replace("12'h020: RDATA", "12'h02C: RDATA")
        _, reads = parse_rtl_decodes(mutated)
        self.assertNotEqual(set(self.header) - reads, {self.header_index("ROOT_LIST")})

    def header_index(self, name):
        for offset, candidate in self.header.items():
            if candidate == name:
                return offset
        self.fail(f"REG_{name} is not defined in csrc/fpga_gc.h")


# ---------------------------------------------------------------- status bits

class StatusBitsTest(unittest.TestCase):
    def test_header_rtl_readme_agree(self):
        masks = parse_status_header(read("csrc/fpga_gc.h"))
        self.assertEqual(sorted(masks), list(range(len(masks))),
                         "STATUS bits must be contiguous from bit 0")
        expected_rtl = [STATUS_SIGNAL[name] for _, name in sorted(masks.items())][::-1]
        self.assertEqual(parse_status_rtl(read("rtl/gc_regs.v")), expected_rtl)
        self.assertEqual(parse_status_readme(read("README.md")), set(masks))

    def test_negative_control_reordered_concat_is_detected(self):
        regs = read("rtl/gc_regs.v")
        mutated = re.sub(r"\{26'h0, reg_free_busy, reg_idle, err_hdr, err_ref, err_rd, err_ovf\}",
                         "{26'h0, reg_free_busy, err_hdr, reg_idle, err_ref, err_rd, err_ovf}", regs)
        masks = parse_status_header(read("csrc/fpga_gc.h"))
        expected = [STATUS_SIGNAL[name] for _, name in sorted(masks.items())][::-1]
        self.assertNotEqual(parse_status_rtl(mutated), expected)


# ---------------------------------------------------------------- magic/version

class MagicVersionTest(unittest.TestCase):
    def test_constants_agree(self):
        header = read("csrc/fpga_gc.h")
        magic = parse_hex(re.search(r"#define\s+FOGCCC_MAGIC\s+(0x[0-9A-Fa-f]+)", header).group(1))
        version = parse_hex(re.search(r"#define\s+FOGCCC_VERSION\s+(0x[0-9A-Fa-f]+)", header).group(1))

        regs = read("rtl/gc_regs.v")
        rtl_magic = parse_hex(re.search(r"12'h030:\s*RDATA\s*<=\s*32'h([0-9A-Fa-f_]+)", regs).group(1))
        rtl_version = parse_hex(re.search(r"12'h034:\s*RDATA\s*<=\s*32'h([0-9A-Fa-f_]+)", regs).group(1))
        self.assertEqual((rtl_magic, rtl_version), (magic, version))

        readme = read("README.md")
        doc_magic = parse_hex(re.search(r"(?m)^\|\s*0x30\s*\|.*?`(0x[0-9A-Fa-f_]+)`", readme).group(1))
        doc_version = parse_hex(re.search(r"(?m)^\|\s*0x34\s*\|.*?`(0x[0-9A-Fa-f_]+)`", readme).group(1))
        self.assertEqual((doc_magic, doc_version), (magic, version))

    def test_negative_control_version_bump_is_detected(self):
        regs = read("rtl/gc_regs.v")
        header = read("csrc/fpga_gc.h")
        expected = parse_hex(re.search(r"#define\s+FOGCCC_VERSION\s+(0x[0-9A-Fa-f]+)", header).group(1))
        literal = "32'h%04x_%04x" % (expected >> 16, expected & 0xffff)
        mutated = regs.replace(literal, "32'h0005_0000")
        self.assertNotEqual(
            parse_hex(re.search(r"12'h034:\s*RDATA\s*<=\s*32'h([0-9A-Fa-f_]+)", mutated).group(1)),
            expected,
        )


# ---------------------------------------------------------------- design parameters

class DesignParametersTest(unittest.TestCase):
    def test_readme_parameters_match_rtl(self):
        params = {
            "QD": int(re.search(r"parameter integer QD\s*=\s*(\d+)", read("rtl/gc_axi_read.v")).group(1)),
            "MAXO": int(re.search(r"MAXO\s*=\s*(\d+)", read("rtl/gc_axi_read.v")).group(1)),
            "PD": int(re.search(r"localparam integer PD\s*=\s*(\d+)", read("rtl/gc_mark_engine.v")).group(1)),
            "DQD": int(re.search(r"\bDQD\s*=\s*(\d+)", read("rtl/gc_mark_engine.v")).group(1)),
        }
        documented = {
            name: int(value)
            for name, value in re.findall(
                r"(?m)^\|\s*`([A-Z]+)`\s*\|\s*\*\*(\d+)\*\*", read("README.md")
            )
        }
        for name, value in params.items():
            with self.subTest(parameter=name):
                self.assertEqual(documented.get(name), value,
                                 f"README 关键设计参数 disagrees with the RTL for {name}")

    def test_outstanding_cap_matches_the_hp_interface(self):
        maxo = int(re.search(r"MAXO\s*=\s*(\d+)", read("rtl/gc_axi_read.v")).group(1))
        declared = int(re.search(r"NUM_READ_OUTSTANDING (\d+)", read("rtl/gc_top.v")).group(1))
        self.assertEqual(maxo, declared,
                         "MAXO must equal the HP port's NUM_READ_OUTSTANDING")

    def test_object_limit_matches_the_readme(self):
        depth = int(re.search(r"localparam integer DEPTH\s*=\s*(\d+)", read("rtl/gc_queue.v")).group(1))
        documented = int(re.search(r"(?m)^\|\s*对象上限\s*\|\s*\*\*(\d+)\*\*", read("README.md")).group(1))
        self.assertEqual(depth, documented)


# ---------------------------------------------------------------- software API

class DriverApiTest(unittest.TestCase):
    def test_header_and_implementation_declare_the_same_functions(self):
        pattern = r"(?m)^(?:int|void|uint32_t)\s+(fpga_gc_\w+)\s*\("
        declared = set(re.findall(pattern, read("csrc/fpga_gc.h")))
        defined = set(re.findall(pattern, read("csrc/fpga_gc.c")))
        self.assertEqual(declared - defined, set(), "declared in fpga_gc.h, not defined in fpga_gc.c")
        self.assertEqual(defined - declared, set(), "defined in fpga_gc.c, not declared in fpga_gc.h")

    def test_python_binding_only_calls_exported_symbols(self):
        binding = read("python/fogccc.py")
        declared = set(re.findall(r"(?m)^(?:int|void|uint32_t)\s+(fpga_gc_\w+)\s*\(", read("csrc/fpga_gc.h")))
        called = set(re.findall(r"_lib\.(fpga_gc_\w+)\(", binding))
        self.assertLessEqual(called, declared, "fogccc.py calls a symbol fpga_gc.h does not export")

    def test_every_ctypes_call_is_typed(self):
        binding = read("python/fogccc.py")
        called = set(re.findall(r"_lib\.(fpga_gc_\w+)\(", binding))
        typed = set(re.findall(r"_lib\.(fpga_gc_\w+)\.argtypes", binding))
        self.assertEqual(called, typed,
                         "every ctypes call needs an explicit argtypes (untyped calls truncate pointers)")


# ---------------------------------------------------------------- duplicated files

class CardCopyTest(unittest.TestCase):
    def test_make_card_copies_are_identical(self):
        makefile = read("Makefile")
        card = makefile[makefile.index("\ncard:"):]
        pairs = re.findall(r"(?m)^\s*@?cp -f\s+(\S+)\s+(\S+)\s*$", card)
        self.assertTrue(pairs, "no `cp -f` lines found in the card target")
        files = set(tracked())
        checked = 0
        for source, target in pairs:
            if source not in files:
                continue  # build output, produced by `make`, not tracked
            with self.subTest(pair=f"{source} -> {target}"):
                self.assertIn(target, files, "card copy is not tracked")
                self.assertEqual(
                    (REPO / source).read_bytes(), (REPO / target).read_bytes(),
                    "card copy differs from its source; run `make card`",
                )
                checked += 1
        self.assertGreater(checked, 0, "no tracked card copies were compared")


# ---------------------------------------------------------------- evidence

class EvidenceTest(unittest.TestCase):
    def test_logs_cited_by_the_readme_exist_and_are_tracked(self):
        readme = read("README.md")
        cited = sorted(set(re.findall(r"tools/logs/[A-Za-z0-9_.\-]+", readme)))
        self.assertTrue(cited, "README cites no measurement log")
        files = set(tracked())
        for path in cited:
            with self.subTest(log=path):
                self.assertTrue((REPO / path).is_file(), "cited log is missing")
                self.assertIn(path, files, "cited log is not tracked (gitignored?)")

    def unquoted(self, readme_text):
        entries = re.findall(r"(?m)^([0-9a-f]{64})\s+(\S+)$", read("artifacts/SHA256SUMS.release"))
        self.assertEqual(len(entries), 4, "release manifest must list the four release assets")
        lowered = readme_text.lower()
        return [name for digest, name in entries if digest not in lowered]

    def test_release_manifest_hashes_appear_in_the_readme(self):
        readme = read("README.md")
        self.assertEqual(self.unquoted(readme), [],
                         "README does not quote a release-asset hash; the table drifted")
        self.assertIn("sha256sum -c SHA256SUMS.release", readme,
                      "README must document how to verify the release assets")

    def test_negative_control_stale_hash_is_detected(self):
        digest, name = re.search(r"(?m)^([0-9a-f]{64})\s+(\S+)$",
                                 read("artifacts/SHA256SUMS.release")).groups()
        stale = read("README.md").replace(digest, "0" * 64)
        self.assertEqual(self.unquoted(stale), [name])


# ---------------------------------------------------------------- hygiene

class RepositoryHygieneTest(unittest.TestCase):
    def test_no_unexpected_binary_or_large_tracked_file(self):
        for rel in tracked():
            path = REPO / rel
            with self.subTest(file=rel):
                self.assertLessEqual(path.stat().st_size, MAX_TRACKED_BYTES,
                                     "tracked file exceeds 1 MiB; ship it as a release asset")
                if rel in BINARY_ALLOWED:
                    continue
                head = path.read_bytes()[:8192]
                self.assertNotIn(b"\x00", head, f"{rel} looks binary but is not in BINARY_ALLOWED")

    def test_text_files_are_valid_utf8_without_replacement_characters(self):
        for rel in tracked():
            if rel in BINARY_ALLOWED:
                continue
            path = REPO / rel
            with self.subTest(file=rel):
                text = path.read_bytes().decode("utf-8")
                self.assertNotIn("\ufffd", text, "file contains U+FFFD (an encoding accident)")

    def test_index_stores_lf_line_endings(self):
        out = subprocess.run(["git", "-C", str(REPO), "ls-files", "--eol"], check=True,
                             capture_output=True, text=True).stdout
        for line in out.splitlines():
            index_field, rest = line.split("\t", 1)
            with self.subTest(file=rest):
                self.assertNotIn("i/crlf", index_field,
                                 "CRLF in the index; BusyBox sh and python3 will choke")
                self.assertNotIn("i/mixed", index_field, "mixed line endings in the index")


# ---------------------------------------------------------------- test inventory

class TestInventoryTest(unittest.TestCase):
    def test_every_testbench_is_compiled_by_some_runner(self):
        runners = [p.read_text(encoding="utf-8", errors="replace")
                   for p in (REPO / "sim").iterdir() if p.suffix in (".sh", ".bat")]
        runners += [p.read_text(encoding="utf-8") for p in (REPO / ".github/workflows").glob("*.yml")]
        haystack = "\n".join(runners)
        benches = sorted(p.name for p in (REPO / "sim").glob("tb_*.v"))
        self.assertTrue(benches, "no testbenches found")
        for name in benches:
            with self.subTest(testbench=name):
                self.assertIn(name, haystack, f"{name} is never compiled; dead testbench")

    def test_sim_runners_have_a_shell_and_a_platform_twin(self):
        sims = REPO / "sim"
        shells = {p.stem for p in sims.glob("run_*.sh")}
        bats = {p.stem for p in sims.glob("run_*.bat")}
        self.assertEqual(shells, bats, "every sim runner needs both run_*.sh and run_*.bat")


# ---------------------------------------------------------------- workflow policy

class WorkflowPolicyTest(unittest.TestCase):
    def workflows(self):
        return sorted((REPO / ".github/workflows").glob("*.yml"))

    def test_workflows_are_pinned_and_least_privilege(self):
        for path in self.workflows():
            text = path.read_text(encoding="utf-8")
            with self.subTest(workflow=path.name):
                self.assertRegex(text, r"(?m)^name:\s*\S", "workflow needs a top-level name")
                # dev-hieq.yml is deliberately push-only feedback for the draft
                # branch; the same checks still run on every PR via gate.yml.
                if path.name != "dev-hieq.yml":
                    self.assertIn("pull_request", text, "workflow must run on pull_request")
                self.assertRegex(text, r"(?m)^permissions:\s*$",
                                 "workflow needs an explicit top-level permissions block")
                self.assertRegex(text, r"(?m)^\s+contents:\s*read\s*$",
                                 "permissions must default to contents: read")
                self.assertNotIn("pull_request_target", text,
                                 "pull_request_target exposes secrets to fork PRs")
                for reference in re.findall(r"(?m)^\s*(?:-\s*)?uses:\s*(\S+)", text):
                    with self.subTest(uses=reference):
                        if reference.startswith("./"):
                            continue
                        self.assertRegex(reference, r"@[0-9a-f]{40}$",
                                         "third-party action must be pinned to a commit SHA")

    def test_required_checks_are_produced_by_workflows(self):
        ruleset = json.loads(read(".github/rulesets/main.json"))
        contexts = [
            check["context"]
            for rule in ruleset["rules"] if rule["type"] == "required_status_checks"
            for check in rule["parameters"]["required_status_checks"]
        ]
        self.assertTrue(contexts, "ruleset requires no status checks")
        jobs = set()
        for path in self.workflows():
            text = path.read_text(encoding="utf-8")
            jobs |= set(re.findall(r"(?m)^  ([a-z0-9][a-z0-9-]*):\s*$", text))
        for context in contexts:
            with self.subTest(required=context):
                self.assertIn(context, jobs,
                              "required check never runs; main could never merge")

    def test_readme_badge_points_at_an_existing_workflow(self):
        match = re.search(r"actions/workflows/([\w.\-]+)/badge", read("README.md"))
        self.assertIsNotNone(match, "README carries no CI badge")
        self.assertTrue((REPO / ".github/workflows" / match.group(1)).is_file())


# ---------------------------------------------------------------- rtl style

class RtlStyleTest(unittest.TestCase):
    SEQ_ASSIGN = re.compile(r"^\s*[A-Za-z_]\w*(\[[^\]]*\])?\s*=(?!=)")
    ALWAYS = re.compile(r"always\s*@\s*\(")

    def blocking_assignments(self, text):
        """Blocking `=` assignments inside clocked always blocks.

        A block runs from its `always @(...)` line to the next `always` (or
        `endmodule`), which covers nested if/case bodies. Lines whose first
        token is a keyword (`for`, `if`, ...) are skipped, and a trailing
        `// ci-allow-blocking` waives a deliberate exception.
        """
        starts = [m.start() for m in self.ALWAYS.finditer(text)]
        boundaries = starts + [text.find("endmodule")]
        found = []
        for start, stop in zip(starts, boundaries[1:]):
            block = text[start:stop]
            if not re.match(r"always\s*@\s*\(\s*(posedge|negedge)", block):
                continue
            for offset, line in enumerate(block.splitlines()):
                if "ci-allow-blocking" in line:
                    continue
                code = line.split("//")[0]
                if re.match(r"^\s*(localparam|for|if|else|case|endcase|begin|end|\$|always)", code):
                    continue
                if self.SEQ_ASSIGN.match(code):
                    number = text.count("\n", 0, start) + offset + 1
                    found.append((number, code.strip()))
        return found

    def test_sequential_blocks_use_nonblocking_assignments(self):
        for path in sorted((REPO / "rtl").glob("*.v")):
            with self.subTest(file=path.name):
                self.assertEqual(self.blocking_assignments(path.read_text(encoding="utf-8")), [],
                                 "blocking assignment inside a clocked always block")

    def test_negative_control_blocking_assignment_is_detected(self):
        text = (
            "always @(posedge clk) begin\n"
            "    if (a) begin\n"
            "        r = 1'b1;\n"
            "    end\n"
            "end\n"
        )
        self.assertEqual(len(self.blocking_assignments(text)), 1)
        waived = text.replace("r = 1'b1;", "r = 1'b1; // ci-allow-blocking")
        self.assertEqual(self.blocking_assignments(waived), [])


if __name__ == "__main__":
    unittest.main()
