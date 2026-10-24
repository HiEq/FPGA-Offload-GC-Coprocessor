# AGENTS.md — Engineering Operating Protocol

**Status:** normative. Applies to every agent session in this repository.
**Purpose:** preserve development momentum while making verification a natural part of the loop.
**Scope:** this document is an operating contract for the agent. It is not an assessment of the developer, and it does not add process to the developer's workflow. It constrains how the agent behaves inside the existing workflow.
**Language policy:** this document is intentionally written in English as the normative reference. All human-facing output — plans, explanations, questions, warnings, review notes, summaries — MUST be in Simplified Chinese. Code, identifiers, file paths, commands, logs, and Conventional Commit subjects keep their original form.

Contents: [0 Summary](#0-operating-summary) · [1 Profile](#1-interaction-profile) · [2 Modes](#2-interaction-modes) · [3 Ambiguity](#3-ambiguity-triage) · [4 Verification](#4-verification-requirements) · [5 Calibration](#5-calibration-mechanics) · [6 Pacing](#6-session-pacing-and-landing) · [7 Commitments](#7-agent-commitments) · [8 Overrides](#8-developer-override-phrases) · [9 Summary](#9-one-line-summary)

21. **CLOSED 2026-10-24 (sim + board).** Three hand-over defects the `dev-hieq` line
    guarded with directed testbenches and this line did not. All three are fixed in the RTL, and the
    three testbenches are back in the tree as the guards.
    *Defects and fixes.* (a) `gc_top.v` passed a bare `w_start` to `gc_axi_read.run_start`. A START
    the mark FSM ignores because it is busy (`S_IDLE` is the only accepting state) still flushed the
    read path under the running epoch, so its outstanding beats were discarded and the run hung;
    now `.run_start(w_start & w_engine_idle)`. (b) `gc_axi_read.v` popped the data FIFO on
    `data0_valid && data0_ready` even in the cycle where `run_start`/`abort` reloaded the pointers
    (`d0r <= d0w` then `d0r <= d0r + 1`), leaving one stale beat for the next run; the pops are now
    gated with `!run_start && !abort`. (c) `flushing` cleared on `h0empty && h1empty` alone, so an
    AR that was issued but not yet handshaken was still outstanding when the flush ended and its
    response was stored; the exit condition now also requires `!ARVALID`, so that AR is waited out
    and its response discarded.
    *Guards.* `sim/tb_flush_data.v`, `sim/tb_stale_ar_flush.v`, `sim/tb_start_while_busy.v` are back
    under `sim/`; `sim/run_port_tb.{bat,sh}` runs them, `tools/reproduce_all.ps1` has them as a step,
    and `lint.yml` runs them under Icarus. Negative control: the same three testbenches fail on the
    pre-fix RTL (`stale data survived abort: d0=0x22222222`; `stale beat visible: 0xccccdddd`;
    `timeout after duplicate START; state=14 q=26`), i.e. the guards can fail.
    *Evidence.* `sim\run_port_tb.bat` -> all three PASS; `tools/reproduce_all.ps1` -> `RESULT: PASS`
    (six sim steps); `tests/test_repo_contract.py` -> 55 tests OK. Bitstream `3d3a9f1d…`
    (WNS +0.123 / WHS +0.060, LUT 26,930 / FF 71,497) repacked into `BOOT.BIN` `63e52587…`;
    `verify_bootbin.py` PASS (only the bitstream partition changed).
    *Not shipped from that line:* `csrc/test_fpga_gc_host.c` compiles against this driver but
    segfaults on the first run, so it stays out of the tree until it has a working oracle.
    *Board evidence (2026-10-24, cold boot from `BOOT.BIN` `63e52587…`, bitstream `3D3A9F1D…`).*
    `tools/logs/board_coldboot_verify_20261024.log`: `D1..D6=0`, the card's `BOOT.BIN` sha256 matches
    the release asset, `test_main` 4/4.  Full chain green: phase 2 `PHASE2_PASS`, `CONTRACT_RESULT OK`,
    `DIRTY_SET` / `DIRTY_CONCURRENT` / `DIRTY_OVERFLOW` / `CTRL_SPILL` / `DIRTY_API` / `FREELIST4096`,
    end-of-chain `DIRTY_STATE occ=0`, `run_gc` 8/8, `abort` T1-T5, `abort_sweep` 11/11, `done_race`
    P3 0/20, `repeat`, `cmark` 72/72.  `irq` reports `IRQ_DRIVEN_DONE_OK` only as the first command
    after a boot (DONE is latched otherwise: ordering, not a regression).
    A/B on the same image, each run being the first `DIRTY_PUSH` burst after a reboot:
    `--acked` gives `loss=[] retries=2`, `--plain` gives `loss=[8]`
    (`tools/logs/board_regs_aww_acked.log`, `tools/logs/board_regs_aww.log`).

---

## 0. Operating summary

- Default mode is collaborative implementation. Keep momentum.
- Enter a short **verification checkpoint** after a build succeeds, before a high-risk change, and before commit. Duration: 30 seconds to 2 minutes.
- Enter a short **calibration checkpoint** when the request is materially ambiguous, when the session is moving faster than it is verifying, or when a high-risk decision is being made.
- The test is the adversary. The agent is the ally.
- Compilation is a starting gun, not a finish line.
- Constraints in this document bind the agent. They do not bind the developer.
- Priority when rules conflict: **honesty > verification > momentum > coverage > style.**

---

## 1. Interaction profile

### 1.1 Communication style

- Prompts may be terse: "然后呢", "继续", "下一个", "搞快点", "还有呢", or a single high-level goal with no acceptance criteria.
- Treat a terse prompt as a request for the agent to propose the next step, not as a complete specification.
- Do not respond with "please clarify" as the only move. Do not silently take over either.

### 1.2 Working knowledge map

Assume working proficiency in:

- C syntax and basic pointer use.
- Common Linux commands and shell navigation.
- Vivado project creation, synthesis, implementation, and bitstream download.
- The general meaning of timing closure and resource utilization.

Do not assume working proficiency in:

- AXI handshake details, `ARSIZE`/`ARLEN`/`ARBURST` semantics, outstanding-transaction limits.
- Clock-domain crossing, XDC timing constraints, asynchronous clock groups.
- `/dev/mem`, cache coherency, memory-mapped I/O hazards.
- Verilog nonblocking-assignment semantics, FSM coding hazards, testbench methodology.
- C undefined behavior, alignment, strict aliasing.
- Git branching, rebasing, and push semantics.

**Question policy:** do not quiz on definitions or syntax. Ask about consequences, tradeoffs, and counterexamples.

- Bad: "Do you know what a pointer is?"
- Good: "If `ARSIZE=0`, how many bytes does the slave return? What is our basis for reading `RDATA[63:32]`?"
- Bad: "Do you understand nonblocking assignment?"
- Good: "If this assignment were blocking, would the FSM advance one cycle earlier? What would break?"

### 1.3 Momentum pattern

This repository's owner works in a fast, momentum-oriented style. That is a productive state. Do not slow it down; insert one checkpoint at a natural boundary.

Signals:

- Terse continuation prompts.
- Three or more edits since the last verification.
- Terse approvals ("行", "好", "看起来没问题") — these are acknowledgments, not verification evidence.
- "Can it run?" without "Is it correct?"
- A new feature started before the previous one is verified.

Response: one short checkpoint. Not a lecture. Not a diagnosis. Do not use labels such as "overconfident", "beginner", or "Dunning-Kruger" in conversation.

```
我们现在节奏有点快：连续改了 3 处还没验证。
不是拦你，是怕一会儿回头找不到问题。
挑一个，30 秒跑掉；你猜结果会是什么？
```

If the developer says "先跑", "别问了", or "继续": comply. Do not repeat the checkpoint. After the result, ask once: "和你想的一样吗？"

### 1.4 Using this profile

- Treat this section as a default hypothesis, not a permanent label.
- If the developer predicts correctly or supplies a counterexample, reduce question density and promote autonomy.
- If the developer asks for speed, preserve speed; move the checkpoint after the result instead of before it.
- Assume generated RTL has not been line-reviewed unless the developer says otherwise. Surface the review points; do not assume they were inspected.
- Never quote or paraphrase this section back as a judgment.

---

## 2. Interaction modes

```
Mode C — Collaborative (default)
  ├─ build succeeded / high-risk change / pre-commit / test changed
  │    → Mode V (verification checkpoint, 30 s – 2 min) → Mode C
  ├─ material ambiguity / momentum pattern / high-risk decision
  │    → Mode K (calibration checkpoint, 1 question + menu) → Mode C
  └─ developer says "先跑 / 继续 / 别问了"
       → comply → ask one comparison question after the result → Mode C
```

### Mode C — Collaborative

Write code, explain briefly, keep the developer moving. No checkpoint unless a trigger below fires.

### Mode V — Verification checkpoint

Triggers: build/synthesis success; change touches RTL, XDC, block design, or memory map; before commit; new or modified test.

Actions:

1. State the 3-line plan if it was not already stated.
2. Ask for a prediction (one question).
3. Run the smallest decisive check.
4. Compare result to prediction; explain the difference before changing code.
5. Report verified / unverified / not measured.
6. Return to Mode C.

Do not request a prediction on every turn. Mode V triggers only.

### Mode K — Calibration checkpoint

Triggers: material ambiguity; momentum pattern; high-risk decision; repeated wrong predictions.

Actions:

1. Infer the likely intent and say it out loud.
2. Offer 2–3 options with a recommendation.
3. Ask one consequence, tradeoff, or counterexample question.
4. Teach one concept only if the answer reveals a gap.
5. Return to Mode C.

---

## 3. Ambiguity triage

| Class     | Examples                                                                       | Action                                           |
| --------- | ------------------------------------------------------------------------------ | ------------------------------------------------ |
| Material  | "然后呢", "优化一下", "把 AXI 改到 200MHz", a goal with no acceptance criteria | Stop. State 2–3 interpretations or options. Ask. |
| Cosmetic  | variable naming, comments, formatting                                          | State the assumption, proceed, note it briefly.  |
| High-risk | RTL, XDC, BD, memory map, commit/push                                          | Confirm even if the instruction is clear.        |
| Low-risk  | docs, comments, local scripts                                                  | Proceed; one-line note is enough.                |

### 3.1 Terse-prompt protocol

For "然后呢" and similar prompts, use: **infer + menu + recommendation + one 30-second question.**

```
我猜你想继续 X。但“然后呢”有三种可能：

A. 验证刚才的改动（2 分钟，推荐）
B. 继续做 Y（会多一个未验证点）
C. 先处理 Z（风险最高）

你选哪个？如果选 A，先猜：marked 会是多少？
```

Do not answer a terse prompt with only "请给出清晰指令". Do not silently choose a path and start editing.

### 3.2 Question discipline

- One question per turn.
- Multiple choice when possible, with a recommended option.
- Allow "不知道"; treat it as a teaching moment, not a failure.
- Do not ask questions the code or tests can answer. Investigate first; ask about intent, tradeoffs, and risk.
- If the developer ignores a question, do not nag. State the assumption, proceed, and flag it as unverified.

---

## 4. Verification requirements

### 4.1 Verification contract

Before a non-trivial change, state three lines:

```
Change: <files:lines>
Why: <the observed problem or requested behavior>
Verify: <exact command + expected result>
```

For RTL/XDC/BD/memory map, add:

- clock, reset, width, and handshake assumptions of every modified `always` block;
- FSM state/transition changes;
- worst-case latency/throughput impact;
- which simulation or assertion covers it; if none, write the test first.

### 4.2 Evidence ladder

Strongest to weakest:

1. A human can explain the behavior and the failure mode.
2. Boundary and negative tests pass, including an injected fault.
3. On-board known-answer test passes.
4. Self-checking simulation passes with assertions.
5. Synthesis/implementation completes.
6. Compilation succeeds.

Levels 5–6 prove buildability only. They are not correctness evidence.

### 4.3 Test quality rubric

A test is acceptable only if all apply:

1. **Replayable:** deterministic, or prints its seed and supports replay.
2. **Independent oracle:** the expected result is not produced by the same code path under test.
3. **Can fail:** a negative control proves the test fails when the implementation is broken.
4. **Boundary-aware:** covers empty, one, max-1, max, overflow, and error paths.
5. **State-aware:** checks side effects and invariants, not only return values.
6. **Diagnostic:** failure output names expected vs actual and the relevant object/address.
7. **Documented:** one command reproduces it; no undocumented manual steps.

#### 4.3.1 Anti-patterns

- `assert(true)`, or a test that only checks "did not crash".
- Expected value computed by the function under test.
- A mock that returns the expected value instead of modeling the contract.
- Sleep-based synchronization without a timeout or condition.
- A test that passes for every input size.
- Coverage inflation with trivial accessors.

### 4.4 Negative control (mandatory)

For every new or modified test:

1. Break the implementation deliberately (revert the fix, flip a condition, truncate a width).
2. Confirm the test fails.
3. Restore the implementation.
4. If the test still passes, the test is invalid. Rewrite it before proceeding.

For RTL assertions: inject the condition the assertion is supposed to catch and confirm it fires.

### 4.5 Coverage requirements

Coverage is a diagnostic, not a target. Never add trivial tests to inflate a number.

Report coverage only from an actual tool run, with the exact command. Otherwise write `coverage: not measured`.

| Tier | Scope                                   | Minimum                                                                                                                                                                                           |
| ---- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| T0   | docs, comments                          | No coverage requirement; link or command as evidence.                                                                                                                                             |
| T1   | Python tools, host scripts              | Happy path + one failure path + negative control. Changed-line coverage ≥ 70% if a tool is available.                                                                                             |
| T2   | C driver, Python bindings, test harness | Happy + boundary + error path + negative control. Changed-line ≥ 80%, branch ≥ 70% if measured.                                                                                                   |
| T3   | RTL, XDC, BD, memory map                | Directed simulation + assertions + boundary matrix + protocol/error injection + negative control. Functional coverage points listed explicitly. No line-coverage claim unless a tool provides it. |

#### 4.5.1 Coverage accounting

- **Changed-line coverage:** covered executable changed lines / executable changed lines.
- **Branch coverage:** taken branch outcomes / total branch outcomes.
- **Mutation score:** killed mutants / total mutants. Minimum 70% for T2–T3 when a mutation tool is available.
- **Functional coverage:** hit coverpoints / defined coverpoints (T3 only).

Coverage is reported per change, not per repository, unless a full run is explicitly requested.

#### 4.5.2 Waivers

If a tier minimum cannot be met, record:

- reason;
- residual risk;
- alternative evidence;
- expiry or review date.

A waiver is not a pass; it is a tracked gap.

### 4.6 RTL verification matrix

For any RTL change, enumerate and test:

- **Reset:** all FSMs return to IDLE; outputs are safe; done/error semantics are defined.
- **FSM:** every state reachable; every transition exercised; no deadlock (timeout test).
- **Boundaries:** object count 0, 1, 2, max-1, max; `ref_count` 0, 1, max; queue empty, full-1, full; bitmap word boundaries 31/32/33; IDs 4095/4096; `root_count` 0, 1, max; duplicate roots; unreachable islands.
- **Memory:** bitmap read-after-write hazard; queue pointer wrap; 12-bit truncation; address alignment 4/8.
- **AXI:** handshake backpressure on `ARREADY`/`RREADY`; outstanding limit; response ordering; `RRESP` error injection; `ARSIZE`/`ARLEN`/`ARBURST` correctness; no silent data loss when a FIFO is full.
- **Clocking:** single-clock assumption; if clocks differ, a CDC review is mandatory. `set_clock_groups -asynchronous` is not a CDC implementation.
- **Protocol:** a behavioral memory model is not a protocol checker. Use an AXI VIP or protocol assertions when the interface changes.

### 4.7 What does not count as evidence

- "Vivado passed" or "synthesis completed".
- "The board printed OK" without a known-answer oracle.
- A happy-path test only.
- A test whose expected value is computed by the same implementation.
- A mock that ignores the protocol fields under test.
- A test that passes identically for every input size.
- Coverage numbers without a command and a report.
- A code comment claiming correctness.

### 4.8 Reporting format

Every completion report must contain:

```
Verified: <what, with command/result>
Unverified: <what was not tested, and why>
Not measured: <coverage or metrics without a tool run>
Risks: <silent-failure candidates>
```

#### 4.8.1 Claim provenance

Every performance or correctness number in README or release notes must cite:

- command;
- commit;
- dataset or seed;
- artifact hash;
- date.

Otherwise mark it `historical/unverified`.

### 4.9 Open verification gaps

These are known by code reading. Do not assume they are safe. Do not fix them opportunistically; raise them, get approval, and add a failing test first.

1. ~~AXI HP read interface omits `ARLEN`/`ARSIZE`/`ARBURST`~~ **CLOSED 2026-10-17.** The RTL has always driven `ARSIZE=3`/`ARLEN=0`/`ARBURST=INCR` as constants (`rtl/gc_axi_read.v` reset block); the gap was the absence of any checker. `sim/axi_proto_check.v` now fails the run on a wrong geometry, a misaligned address, `ARID>1`, a withdrawn `ARVALID`, or a response with no outstanding request. Negative control: `ARSIZE=3'b010` produces 1588 `[AXI][FAIL]` lines while every functional test still passes.
2. ~~Queue saturation silently drops objects~~ **CLOSED 2026-10-17.** `err_ovf` is latched on both enqueue paths and exposed in `STATUS[0]`; sim test T7 forces `q_full`, then checks `STATUS[0]=1` and `marked=0` (no silent loss). Negative control: setting `err_ovf <= 1'b0` makes T7 fail.
3. ~~Root marking does not consult the bitmap~~ **CLOSED 2026-10-17.** `S_ROOT_CHK`/`S_ROOT_MARK` test the bitmap before pushing a root, so a duplicate root is skipped and not counted. Sim T2 (same root written twice) plus board `Test 4` (`roots={0,0,0}` vs `{0}` -> same count, `STATUS=0`) cover it.
4. ~~`fpga_gc_build_graph` gives object 0 (the root) out-degree 0 (`csrc/fpga_gc.c:117`)~~ **CLOSED 2026-10-19 (code read; board test not re-run).** The graph builder now forces the root to have at least one out-edge (`if (i == 0 && rc == 0) rc = avg_refs;`, `csrc/fpga_gc.c:117` in the current file is the error-return path, so the old line reference was stale).
5. ~~`test_main.c` writes header fields at byte offsets +1/+2 instead of +4/+8 (`csrc/test_main.c:108-134`)~~ **CLOSED 2026-10-19 (code read).** `test_main.c` now writes `base + k*16 + 4` (ref_count) and `+8` (first reference); no +1/+2 offsets remain.
6. ~~The C API permits 30000 objects ... `read_mark`/`dump_marks` as stubs~~ **CLOSED 2026-10-17 (C driver).** Limits enforced (4096 objects, 256 roots); `fpga_gc_read_mark` / `fpga_gc_dump_marks` now read the bitmap through the new `0x24 BM_ADDR` / `0x28 BM_DATA` probe, verified in sim (T6) and on board (Test 1 reads back every object and must match `MARKED`). The Python bindings now expose `read_mark` / `read_all_marks` against the same probe.
7. ~~AXI read errors are converted to `0xFFFFFFFF` and `err` is not exposed~~ **CLOSED 2026-10-17.** `gc_axi_read.err` is exported to `STATUS[1]`, and an errored beat is replaced by `0xFFFFFFFF` so the reference list terminates instead of hanging. Sim T8 injects `RRESP=SLVERR` and requires `STATUS[1]=1` plus DONE (no hang); negative control (err forced to 0) fails T8.
8. ~~`reg_clear_bm` is not connected (`rtl/gc_top.v`); `CTRL_CLEAR_BM` is dead.~~ **CLOSED 2026-10-19 (documentation).** The signal no longer exists in the RTL (`grep -r reg_clear_bm rtl/` is empty); the bitmap is cleared by the engine at the start of every run. `CTRL[1]` is therefore kept only as a reserved bit and is labelled as such in the README register map and in `csrc/fpga_gc.h`.
9. **PARTIAL 2026-10-19 — measured, not reproducible on this board.** DONE polling could return a stale result because `START` is a posted AXI-Lite write. Mitigated in `csrc/fpga_gc.c:183-200` (read-back of `CTRL` + `usleep(1)` before the first poll; the 10M-poll timeout writes `CTRL_ABORT`). Measurement: `tools/tests/done_race_test.py` on the board — P1 (naive first read after START) saw DONE=1 in **0/300** iterations and P2 (poll early return) in **0/300**, with the previous run's DONE still latched. So the reorder does not occur on this PS7/interconnect; the mitigation stays because it is cheap, not because a failure was observed. What the same test did find was a different, real bug — the previous run's unissued/unconsumed AXI reads leaking into the next run; fixed by the `run_start` flush in `rtl/gc_axi_read.v` and covered by T-ABORT2 (sim) plus P3 (board).
10. ~~The performance comparison used a whole-interpreter collector run against a mark-only hardware pass~~ **REMOVED 2026-10-22.** The comparison now uses same-stage implementations only: the C BFS on the same graph with DDR-resident (uncached) and cache-resident data, plus a Python-script BFS as context. `run_cmark_sweep.ps1` / `tools/logs/cmark_sweep.log` is the primary evidence.
11. ~~The simulation memory model is not an AXI protocol checker~~ **CLOSED 2026-10-17.** `sim/axi_proto_check.v` checks ARSIZE/ARLEN/ARBURST/alignment/ARVALID stability and fails the run (negative control: ARSIZE=2 produces `[AXI][FAIL]`).
12. ~~`tools/gc_test.py` is unseeded~~ **CLOSED 2026-10-17 (seed).** It now takes `--seed N`, prints the seed, and replays exactly (verified: two runs with `--seed 424242` produced identical N/exp per trial; HW cycles still jitter ~0.5% from DDR). Still open: evidence logs remain gitignored — archive them per release.
13. ~~`CTRL_ABORT` could leave `STATUS[1]`/`STATUS[3]` latched~~ **CLOSED 2026-10-19 (board).** Aborting mid-run let the abandoned run's in-flight reads land after the FSM left `S_REFS_LOOP`: a header word was taken as a fresh header (`STATUS[3]`), a response error was counted (`STATUS[1]`), and a mid-sequence prefetch could leave the next run without DONE. Three fixes: the engine resets `sc_state`/`hdr_cmd_valid`/`hdr_second`/`dq_head`/`iss_idx`/`rd_cmd_valid`/`q_pop` on abort; `gc_axi_read` flushes on abort as well as on `run_start`; and the consume paths ignore a beat on the abort cycle itself (`hdr_hs`, the refs loop), which closed the last 1-cycle race. Evidence: before, 3 us aborts gave `STATUS=0x2` (and one recovery without DONE in 5 tries); after the first two fixes 1 in 5 still saw `0x8`; with the gate, 30/30 repeats at 3 us and all 11 sweep phases report `0x0`, `abort_test.py` T1-T5 pass, `done_race_test.py` P3 is 0/20, `run_gc.sh` exits 0 -- on bitstream md5 `EC59DFAAA2A0FC57E169D2A880A7A0DA`, booted from the repacked `BOOT.BIN` (md5 `442B4400...`).
14. ~~Published image lagged the config~~ **CLOSED 2026-10-20.** `image.ub` was rebuilt with the 2026-10-19 `inetd.conf`/`no-map` changes and flashed together with the new `BOOT.BIN`. The card was written from the release assets and cold-booted: `074CF12D…` / `400F47FA…` md5s match, `/etc/inetd.conf` has only the "disabled" comments, `/proc/device-tree/reserved-memory/pl_graph@1e000000/no-map` exists, and `run_gc.sh 512 2 1` is 2/2. The old card image differed from the release asset (`443837e3…` vs `2B446CFB…`); the current card is byte-identical to the published pair.
15. **CLOSED 2026-10-20.** `fpga_gc_mark()` aborted on timeout but did not wait for the engine to return to idle. `STATUS[4]` now exports `state == S_IDLE`; the driver polls it for up to 10 ms after `CTRL_ABORT`, and the TB checks bit 4 after abort (T-ABORT/T-ABORT2/T-STAR).
16. **CLOSED 2026-10-20.** A response arriving in the same cycle as `run_start`/`abort` bypassed the flush: `flushing` was still 0, so the beat was stored (`d0w++`) while `d0r <= d0w` kept it as the FIFO head — the new run consumed it as its first reference. Fixed by including `run_start`/`abort` in both `RREADY` and the discard branch (`rtl/gc_axi_read.v`). Directed test `sim/tb_runstart_race.v` / `sim/run_race_tb.bat`: unfixed RTL reports `stale beat survived` for both run_start and abort; fixed RTL passes. `run_sim.bat` and `run_axi_tb.bat` stay green. Board (bit md5 `81640C7C8E5918893E0A9C2D442D2BF3`, 2026-10-20): `test_main` 4/4, `abort_test` T1–T5, `abort_sweep` 11/11, `done_race_test` P3 20/20 (P1/P2 0/300), `run_gc.sh 4096 8 2` 8/8; those images' board logs are retired (recoverable via `git log -- tools/logs/`). Cold boot from the repacked BOOT.BIN (md5 `3FAE9CF1…`): the same five suites pass again.
17. **CLOSED 2026-10-21 (board).** The command FIFO could issue the next queued AR in the same cycle as `run_start`/`abort`: `issue_any` was still true while `flushing` was asserted, so the stale `ARADDR` reached the bus. Fixed by gating `issue_any` with `!run_start && !abort` (`rtl/gc_axi_read.v`). Directed test `sim/tb_cmdfifo_flush.v` / `sim/run_cmdfifo_tb.bat`: unfixed RTL reports `c0r=1->2` and a stale `ARADDR=0x30000008`; fixed RTL reports `c0r=1->4` and no stale beat. `run_sim.bat`, `run_axi_tb.bat`, `run_race_tb.bat` stay green. New `BOOT.BIN` SHA256 `7487463a…` (bit md5 `3590FBB5…`, WNS +1.435 / WHS +0.046). Board (2026-10-21, cold boot from this `BOOT.BIN`; `/boot/BOOT.BIN` SHA256 matches `7487463a…`): `test_main` 4/4, `run_gc.sh 4096 8 2` 8/8, `abort_test` T1–T5, `abort_sweep` 11/11, `done_race_test` P3 20/20 (P1/P2 0/300); that image's logs are retired (recoverable via `git log -- tools/logs/`) — they were command outputs/hash headers, not a complete serial transcript.

18. **2026-10-22 — Phase 3A/3B landed (dirty set + concurrent incremental marking), one platform sub-gap waived.** Interface (`VERSION=0x0004_0200`): `0x440 DIRTY_PUSH` = `(tag<<12)|id` command-with-tag, `0x444 DIRTY_STAT` ([19:16] last accepted tag, [10] pending, [9] sticky overflow, [8:0] occupancy), `0x448/0x44C/0x450` drained/pushed/popped, `CTRL[4]=BM_KEEP` (must ride the same write as `START`), `CTRL[5]=DIRTY_FLUSH`. The engine treats the dirty FIFO as a second work source (unmarked -> set + count; marked -> forced re-scan, no recount), `S_DONE` also requires `dirty_empty`, a push while full is dropped + latched, and a record is committed from the FIFO's live head in the same cycle (no latch skew). Evidence: sim `T-DIRTY` (A0/A/B/C + three negative controls), `T-DIRTY-TAG`, `T-DIRTY-RACE(+RACE2)`; board on bit md5 `529594D7B365317D07339B5EDB202A3F` (WNS 0.061 / WHS 0.054; **JTAG load — the boot image still carries the Phase-2 bitstream**): `test_main` 4/4, Phase-2 regression `RESULT: PHASE2_PASS`, `CONTRACT_RESULT OK`, `dirty_set_test.py DIRTY_SET_RESULT OK`, `dirty_concurrent_test.py DIRTY_CONCURRENT_RESULT OK` (epoch 2 kept live ~5.4 ms by a hot-container seed; `live_pushes` 36-38/100 counted by the mutator itself while `CTRL[DONE]==0`; `drained(epoch2) ≈ seed + live_pushes`; `pushed == popped == drained`; no-barrier control `missed=142`). Logs `tools/logs/board_phase3_*.log`.
    **Sub-gap (waiver, review 2026-11-05): the push count is not exact.** *Reason:* the AXI-Lite write path delivers every store twice and the copies are **not always adjacent**, so a redelivery arriving after the next push's tag is accepted as an extra record; `tools/out/tag_leak_probe*.log` shows a *single* store sometimes yielding `occ=2`, with or without a read-back / 10 ms gap. The 4-bit tag cannot separate "stale redelivery" from "new push". *Residual risk:* counters and FIFO occupancy are inflated (~1-2 per burst; 250 logical pushes -> 251-252), so a near-full FIFO can trip one spurious overflow -> a full-mark fallback. *Alternative evidence:* the failure mode is safe — the extra record is always a duplicate of an id already in the set (A segment: `occ=4` while `marked` stayed exactly 6 = `closure{0,40,41}`; every `marked == oracle` and free-list check is exact). Tests assert `pushed >= logical` and `< 2*logical` with exact semantics instead of exact counts. *Not fixed by* tightening acceptance to `tag == last+1`: if the two copies arrive out of order (t+1 before t) that drops a genuine barrier record, which is unsafe for a GC barrier. Exact counts would need a push ack/handshake.
    **Two follow-ups raised, not fixed (no approval asked yet).** (a) `csrc/fpga_gc.c:216` starts a full mark with `CTRL_CLEAR_Q` only; the 3A protocol requires `CTRL[5]=DIRTY_FLUSH` in the same step, and the dirty FIFO survives process restarts, so a record left by an earlier epoch makes the next C-API full mark force-rescan ids the bitmap has just cleared -> extra marks and `q_tail != marked`. Fix is one bit in the driver plus a directed board test (push two ids, run `test_main`, require the `q_tail` invariant to fail before the fix and pass after). (b) `test_main` Test 1 flaked once today in a small-n row (`q_tail=11 != marked=9`; marks/bitmap/STATUS all exact; standalone re-runs of the same binary passed 2/2; that log is retired, recoverable via `git log -- tools/logs/`). The dirty FIFO was empty throughout, so this is not phase-3 related; the likely mechanism is a late redelivery of the driver's `CTRL_CLEAR_Q`/`CTRL_START` stores (this platform redelivers stores, not always adjacently) restarting the engine after DONE, and a restart does not clear the object queue. Needs its own investigation.

    **Sub-gap (a) FIXED 2026-10-22.** `csrc/fpga_gc.c` (`fpga_gc_mark` and `fpga_gc_clear`) and `csrc/cmark.c` now write `CTRL = CTRL_CLEAR_Q | CTRL_DIRTY_FLUSH`; `CTRL_DIRTY_FLUSH` was added to `csrc/fpga_gc.h`. Directed test `tools/tests/dirty_leftover_test.py` leaves two barrier records in the FIFO and then runs `./bin/test_main`: with the pre-fix binaries it reports `q_tail=10 != marked=9` / `Overall: *** FAILED ***` (`tools/logs/board_phase3_leftover.log`); with the fixed binaries `ALL PASS`. Rebuilt with the PetaLinux SDK (`csrc/build_c_bins.sh`, WSL), `artifacts/SHA256SUMS` refreshed — test_main md5 `57704D38…`, libfogccc.so `550DDE06…`, cmark `495C86DF…`.

    **Sub-gap (b) closed; the producer was identified.** The flake's signature is exactly the pre-fix behaviour of (a): one small-n row, a few pushes without marks, everything else exact. The records came from the ad-hoc `tag_leak_probe.py` / `tag_leak_probe2.py` runs (they push to characterise the tag rule and never flush; they left `occ=3..5` behind), so the next `test_main` reported `q_tail = marked + 2` — only the ids inside that row's `obj_count` get scanned — and every later run was clean again. The flush fix removes the failure mode for the C API, and `tools/tests/dirty_state.py` now checks at the end of `tools/debug/run_phase3_board.ps1` that a chain run leaves the FIFO empty. The `DIRTY_PUSH` tag rule's inexactness (measured, benign) and the duplicate-store platform behaviour are recorded in the section above.

    **Cold boot DONE 2026-10-22.** The card's `BOOT.BIN` was repacked with the v4.2 bitstream by bootgen (same recipe as the Phase-2 image; structural check `tools/debug/verify_bootbin.py` PASS) and written from the host card reader; after a power-on the console shows U-Boot -> Linux -> `login:`, the PL reports `VERSION=0x00040200` and `test_main` is 4/4 (that power-on's capture has since been overwritten by the 2026-10-23 rebuilds — recoverable via `git log -- tools/logs/`; the current `tools/logs/board_coldboot_20261023.raw.log` is the arm-and-consume image's reboot capture, see #19). A control reboot with the old (Phase-2) image showed `VERSION=0x00040100`, proving the FSBL reconfigures the PL on every boot (`tools/out/control_reboot_phase2image.log`; the local image snapshot has been deleted, but the control is reproducible — any `VERSION=0x00040100` image works as the contrast input, e.g. the published `v4.1` Release `BOOT.BIN`, sha256 `7487463a…`).

19. **2026-10-22 — spill protection for the CTRL register (Phase 3B follow-up).** Because this platform redelivers every AXI-Lite store and the copies are not always adjacent (measured in #18), the driver's two `CTRL` writes can arrive again while the engine is running. `rtl/gc_top.v` now honours the software `CLEAR_Q` only while the engine is idle, and `rtl/gc_mark_engine.v` pulses `q_clear` when the FSM accepts a start so the run clears the object queue itself. Effects: a spilled `CLEAR_Q` can no longer reset the BFS queue mid-run, and a spilled `START` (a redundant re-run) still leaves `q_tail == marked`. **The register map and every interface are unchanged** (`VERSION` stays `0x0004_0200`, so the card binaries stay paired). Evidence: sim `T-CTRL-SPILL` / `T-CTRL-RESTART` in `sim/tb_gc_top.v` — the ungated RTL reports `T-CTRL-SPILL q_tail=198 != 200`, `T-CTRL-RESTART first run q_tail=198`, `re-run q_tail=398` (3 errors, `tools/out/ctrl_spill_unfixed.log`); the gated RTL is `PASS` (`tools/out/ctrl_spill_fixed.log`). Note what the simulation *did* show: the spilled clear did **not** lose marks in that workload (the prefetch ring and descriptor queue carry the work), its observable damage was the queue pointer / the `q_tail == marked` invariant.
    **Board evidence.** `tools/tests/ctrl_spill_test.py` (added to the card, run on the cold-booted image, log `tools/logs/board_phase3_ctrl_spill.log`): a 200-object fan, then `CTRL = CLEAR_Q` placed while the BFS queue is non-empty and `CTRL = START` after the first run -- both leave `marked = q_tail = 200` (`CTRL_SPILL_RESULT OK`). The same test is the functional proof that the card carries the gated bitstream: `VERSION` is `0x0004_0200` in both builds, so only behaviour distinguishes them (ungated gives 198/398 in simulation).
    **Related, FIXED 2026-10-23.** A `DIRTY_FLUSH` redelivered mid-run could discard a running epoch's pending barrier records. The earlier note here claimed it was "not reachable because the protocol only flushes while the engine is idle" — that is wrong on this platform: the write path redelivers every store and the copies are not always adjacent (measured in #18), so a full-mark's `DIRTY_FLUSH` can land while a later epoch runs. `rtl/gc_top.v` now honours `DIRTY_FLUSH` only while the engine is idle (`w_dirty_flush_eff`, the same treatment as `CLEAR_Q`). Directed test `T-DIRTY-FLUSHSPILL` in `sim/tb_gc_top.v`: the ungated RTL drops the record (`drained=0`, `marked=0`, `tools/logs/xsim_dirtyflush_ungated_20261023.log`), the arm-and-consume RTL passes (`drained=1`, `marked=2`, `tools/logs/xsim_dirtyflushidle_armconsume_20261023.log`); under arm-and-consume an idle flush is only *armed*, so clearing needs the sanctioned flow (arm + a full-mark START), which the TB's `dirty_flush_now` helper performs. Bitstream: the idle-gated-only build (`74401a0a…`, WNS +0.344 / WHS +0.052, LUT 26,910 / FF 71,473, `BOOT.BIN` `e7e581d7…`) was **superseded** the same day by the arm-and-consume build (`build.tcl`, WNS +0.120 / WHS +0.046, LUT 26,920 / FF 71,404, md5 `81f2c277d1cf9f7db4cc296a28d2303e`), repacked into `BOOT.BIN` sha256 `39fe1040feaac1bf9ab00d45d8e0e6e699662df2031b64cc7d7370dacf11e321` (bootgen ran twice byte-identical; `verify_bootbin.py` PASS) and written to the card; after a power-on on 2026-10-23 the whole board suite was re-run on that image (that was the evidence set until the id-ack rebuild in #20 replaced it). **Residual CLOSED 2026-10-23 (arm-and-consume).** The idle-window redelivery was real: a bare `DIRTY_FLUSH` arriving while the engine is idle cleared records the mutator had already pushed for the next epoch. `rtl/gc_top.v` now treats `CTRL[5]` as an *armed* flush: it is applied at the next accepted START with `BM_KEEP=0` and **discarded** by an incremental start, so no interleaving of redeliveries can silently drop a pending record. Directed test `T-DIRTY-FLUSHIDLE` (bare idle flush -> armed, not applied; full-mark start -> applied; incremental start -> discarded, the record is consumed) plus `T-DIRTY-RACE(rc2=1)`: the idle-gated-only RTL fails `T-DIRTY-FLUSHIDLE` (`tools/logs/xsim_dirtyflushidle_ungated_20261023.log`), the arm-and-consume RTL passes (`tools/logs/xsim_dirtyflushidle_armconsume_20261023.log`). The driver needed no change (it already writes `CLEAR_Q|DIRTY_FLUSH` then `START`); `dirty_flush()` in the C/Python API now documents the arming contract. **Board test scripts had to follow the same contract.** `tools/tests/dirty_set_test.py`, `dirty_overflow_test.py`, `dirty_concurrent_test.py`, `ctrl_spill_test.py` and `dirty_state.py` still assumed an immediate flush; they now arm-and-consume (`dirty_flush_now()`: arm + full-mark START + wait) or say explicitly that a `BM_KEEP` start discards the arm. The failure was real, not cosmetic: `dirty_set_test.py`'s A/B/C segments flushed away the records they had just pushed (`DIRTY_SET_RESULT FAIL:A,A-count,A-free,B,C-clear`), and `dirty_overflow_test.py`'s epoch-2 `pushed=popped=0 baseline` write was a no-op (a `BM_KEEP` start discarded it; the counters were already 0 because epoch 1 is a root full mark). Re-run on the board: `DIRTY_SET_RESULT OK` (`A: occ=4 pushed=4 | marked=6 free=58`), `DIRTY_OVERFLOW_RESULT OK`, `DIRTY_CONCURRENT_RESULT OK`, `CTRL_SPILL_RESULT OK`, end-of-chain `DIRTY_STATE occ=0`; logs `tools/logs/board_phase3_dirty_set.log` etc. carry a `# test:` line with the script md5, because those scripts are newer than the `# commit:` the header cites.
    **Found by that same re-run (test defect, fixed the same day): the object-base register was inherited, never set.** `tools/tests/dirty_set_test.py`, `dirty_overflow_test.py` and `dirty_concurrent_test.py` never wrote `0x04 R_OBJ_BASE`; they passed only because an earlier test in the chain (`test_main` through `csrc/fpga_gc.c`, `side_table_test.py`, `ctrl_spill_test.py`, `freelist_n4096_test.py`, ...) left `0x1E000000` behind. `rtl/gc_regs.v:95` resets that register to `0`, so after a fresh boot the engine reads object headers at address `0` and never traverses references. Negative control: `tools/logs/board_phase3_dirty_set_base_neg_20261023.log` — the pre-fix script run as the FIRST test after a reboot (`A marked=2 free=62` instead of `6/58`, `D e1=1` instead of 384, `DIRTY_SET_RESULT FAIL:A-count,A-free,B,D-e1,D-targets,D-oracle,D-free`). The three scripts now write `0x04` themselves and pass as the first tests after a reboot (`board_phase3_dirty_set.log`, `board_phase3_dirty_overflow.log`, `board_phase3_dirty_concurrent.log`). The shipped code was never affected: `csrc/fpga_gc.c` and the Python bindings set the base before every run.

    **Related, NOT reproducible at the current limits (guard test added 2026-10-23).** `rtl/gc_mark_engine.v` prefers the dirty FIFO over the BFS queue at `S_POP` (`:485`) and `S_DIRTY_PUSH` waits while `q_full` (`:561`), while the scanner pops only with `pf_room` (`:233`) and only `S_POP` drains the prefetch ring (`:483`). A genuinely full queue **with** a pending barrier record could therefore deadlock. It is not reachable as built: an enqueue needs an unmarked target (<= 4096 ids), the dirty path's duplicate re-scan can add at most a few, and a pop always precedes a full enqueue burst, so occupancy peaks at 4095 against a 4096-deep queue — which is why `T7` has to `force` `q_full`. Directed test `T-DIRTY-QFULL` (4096-object star + four duplicate-re-scan dirty records) completes with `marked=4096` and now *observes* the state instead of only running the workload: peak BFS-queue occupancy **4094/4096**, `q_full && dirty-pending` cycles **0**, `S_DIRTY_PUSH`-while-full cycles **0**. A forced control, `T-DIRTY-QFULLNEG` (`force dut.u_engine.q_full` with one pending record and no roots), makes the engine hang exactly as the analysis predicts (`DONE=0` after 20000 polls; reset + abort recovers to `STATUS=0x10`) — so the wait is a real deadlock **given** the precondition, while the precondition is empirically unreachable at these limits (evidence `tools/logs/xsim_qfull_dirty_20261023.log`). Kept as a GUARD: if the queue depth or the object limit ever change so that occupancy can reach 4096, the observation fails and the forced control's behaviour becomes reachable.

20. **OPEN 2026-10-23 — a `DIRTY_PUSH` record can be lost or forged when the platform interleaves AW and W beats.** `rtl/gc_regs.v` pairs a W beat with the **last latched AW address** (`awaddr_r`, `:119-160`): `AWVALID&&AWREADY` latches the address, `WVALID&&WREADY` applies the data to it. This platform redelivers every store and the copies are not always adjacent (measured in #18), so the W beat of store X can be applied while `awaddr_r` still holds store Y's address. For a plain register that only rewrites the same value twice; for `0x440 DIRTY_PUSH` it means a **foreign WDATA can be accepted as a push** (`reg_dirty_push <= 1'b1`, id = `WDATA[11:0]`) while the genuine push's own W beat can land on a different address, i.e. be **lost**. Evidence (bitstream `81F2C277D1CF9F7DB4CC296A28D2303E`, `BOOT.BIN` `39fe1040…`): `tools/tests/dirty_set_test.py` run as the FIRST test after a reboot reports `A dirty-run: occ=3 pushed=3 | marked=2 drained=3 popped=3 free=62` (expected `marked=6 free=58`), with segment D otherwise exact (`e1=384 oracle=388`); reproducible in **3 of 3** boots (`tools/logs/board_phase3_dirty_set_boot_neg_20261023.log`), while the same script run again on the warm PL reports `occ=4 pushed=4 | marked=6` in **6 of 6** runs (`tools/logs/board_phase3_dirty_set.log`). The numbers are consistent with a spurious record carrying the WDATA of an earlier `CTRL`/`COUNT` store: the engine pops and counts it, but `dirty_id >= obj_count` makes it mark nothing (`rtl/gc_mark_engine.v` `S_DIRTY_RD`), which is why `drained=popped=3` with only two ids marked. *Impact:* a lost record is a missed re-scan in an incremental (`BM_KEEP=1`) epoch — the concurrent-barrier path — and the dirty FIFO's "never lost silently" claim only covers the full-FIFO drop (which is flagged); a forged record can force an extra re-scan or consume a slot (an id `>= obj_count` is inert, a spurious overflow only triggers the safe full-mark fallback). The same mismatch can mis-apply **any** register write (e.g. `START`'s data landing on `0x08`). The full-mark path is unaffected (it flushes the FIFO anyway), and the phase-3 chain is unaffected because `test_main` runs first and leaves the write path warm — the failure needs a `DIRTY_PUSH` burst to be the first such sequence after a PL configuration. *Not a defect in the block (verified 2026-10-23).* `gc_regs` already allows only one transaction at a time (`AWREADY = ~aw_pending & ~BVALID`, `WREADY = aw_pending & ~w_pending & ~BVALID`) — the standard AXI-Lite pairing and the strongest defence available. `sim/tb_regs_aww.v` (`tools/logs/xsim_regs_aww_20261023.log`) pins that contract: P1 matched pairs land in the right register, P2 the platform's duplicate delivery fires the push exactly once, P3 a W beat is never consumed without a pending AW; P4 (INFO) shows the two consequences above. **B2 measured 2026-10-23 (bitstream `81F2C277…`).** `tools/tests/regs_aww_board_test.py` runs 15 rounds (1 cold + 14 warm); round 0 is the first `DIRTY_PUSH` sequence after a reboot and **loses one record in 4 of 4 boots** (`loss=[8]`, `marked=3` for 3 accepted records: one of them carried a foreign id `>= obj_count`, so the engine popped and drained it without marking); the 14 warm rounds lose nothing (`loss 0/14`, `REGS_AWW_RESULT OK`, `tools/logs/board_regs_aww.log`). Every round also shows an *extra* mark whose WDATA is a bitmap-probe write — so the mismatch happens on a warm PL too, in the safe direction (`board_regs_aww_probe_forge_20261023.log`); the test therefore asserts loss only. So the mismatch can only come from the interconnect delivering write data in a different order than write addresses, and no slave can attribute a W beat to a store. *Mitigation is software-side:* a dirty record must be treated as advisory (the full-mark fallback is always safe), and an epoch that must be exact has to confirm each push — the push ack AGENTS #18 already named as what exact counting would need. **A measured 2026-10-23: the tag read-back alone is NOT enough.** `dirty_push_verified()` (Python binding, no rebuild) writes the push, reads `0x444[19:16]` back and retries on a mismatch; run as the first burst after a reboot it reports `retries=0 giveups=0` while round 0 still loses a record (`loss=[8]` in **3 of 3 boots**, `tools/logs/board_regs_aww_verified.log`). The reason is visible in the same line: a *forged* record can carry the same 4-bit tag (the foreign WDATA's high nibble), so the tag check passes while the genuine id is gone. A *detectable* software guarantee therefore needs an **id-level ack**, i.e. a small interface addition (e.g. `DIRTY_STAT[31:20] = last accepted id`) plus a rebuild and a full board re-run — that is the next step, not done here. **F1 implemented the build-free guarantee in the meantime: verify the barrier's effect.** `fogccc.barrier_verify(ids)` (same pattern with the C `fpga_gc_read_mark`) checks one target per dirtied container after the epoch: all marked -> **no missed mark was observed** (treat as exact); anything unmarked -> fall back to `mark()` from the true roots. This is a **necessary, not sufficient** check: a target that was already marked *before* the epoch hides whether the container was re-scanned, so check only targets this epoch newly reaches, or confirm with a full oracle/count. Board evidence `tools/logs/board_regs_aww_verify_effect.log`: the cold round detects the lost record and recovers through the fallback in **2 of 2 boots**, while the 14 warm rounds need no fallback (`VERIFY_EFFECT_RESULT OK`). Cost: one bitmap probe per dirtied container, so the fast path stays fast and only an epoch that must be exact pays for it. **F2 landed 2026-10-23 (id-level ack).** `DIRTY_STAT[31:20]` now carries the id of the last accepted push next to its tag (a read-only addition, `VERSION` stays `0x0004_0200`), and `fpga_gc_dirty_push_acked()` / `fogccc.dirty_push_acked()` write, read `(tag,id)` back, retry with a fresh tag on a mismatch and fail fast on the sticky overflow bit; a caller that cannot confirm falls back to a full mark. Board evidence on bitstream `05AA145D…` / `BOOT.BIN` `4786ce62…` (`tools/logs/board_regs_aww_acked.log`): the cold round reports `occ=5 pushed=5 … loss=[] retries=1` — the record that would have been lost is detected and retried away — while the `--plain` control on the *same* image still loses it (`loss=[8]`, `tools/logs/board_regs_aww.log`), i.e. the ack, not a change in the push path, is what closes the window. The ack's signature is 16 bits (`tag` 4 + `id` 12), so it detects a mismatch but a foreign store carrying exactly that 16-bit value is indistinguishable from ours — the effect check stays the backstop. The 14 warm rounds lose nothing in either mode. Full suite re-run green: `irq` `IRQ_DRIVEN_DONE_OK`, cold boot `D1..D6=0`, `test_main` 4/4, `PHASE2_PASS`, `CONTRACT_RESULT OK`, `DIRTY_SET_RESULT OK` (the dirty tests now use the ack where the count must be exact), `DIRTY_CONCURRENT`/`OVERFLOW`/`CTRL_SPILL OK`, `DIRTY_API_RESULT OK` (incl. `acked push: [True, True]`), `FREELIST4096 OK`, `run_gc` 8/8, `abort` T1–T5, `abort_sweep` 11/11, `done_race` P3 20/20, `repeat`, `cmark` 72/72, end-of-chain `DIRTY_STATE occ=0`. **Concurrent A/B (2026-10-24).** `dirty_concurrent_test.py --plain-push` restores the old fire-and-forget push as the negative control.  On the same image the *acked* run reports `retries=1 giveups=0` (a record that would have been lost was repaired) while the *plain* run happened to lose nothing and matched the oracle in every round -- at 250 pushes the cold-window loss is intermittent, so the deterministic A/B for the same mechanism stays the 3-push `regs_aww` plain/acked pair.  **The concurrent path uses the ack too (2026-10-23).** `dirty_concurrent_test.py`'s `Pusher` now reads `(tag,id)` back for every push and retries on a mismatch, and the verdict fails on any giveup.  On the board it reports `ack: retries=1 giveups=0` — the ack caught one record during the five rounds that would otherwise have been lost — while `live_pushes` drops from ~40/100 to 30-31/100, i.e. the extra read is visible but the oracle still matches in every round.  *Residuals, closed 2026-10-23:* (1) **cost** — the ack costs one read per push: on the same warm image 200 pushes measure **16.0 µs/push plain vs 30.5 µs/push acked (1.91×)** (`tools/logs/board_regs_aww_cost.log`), so the plain path is unchanged and the ack is opt-in; (2) **forged records** — still possible but bounded: the extra mark is the safe direction, the ack exposes the foreign id (so an exact caller retries) and a spurious overflow only forces the safe full-mark fallback; the effect check covers the case where the caller cannot enumerate its writes; (3) **coverage** — the changed Python (`dirty_push_acked`, `barrier_verify`) is **100 % line covered** by a board `python3 -m trace --count` run of `dirty_api_test.py` (every executable line hit): the C side is **waived** (no gcov on the card; alternative evidence = the same board run plus `dirty_api_test`'s assertions), review at the next release; (4) the cold window stays a *performance* hazard only, and it is measured rather than assumed. *Waiver expiry:* review with the next RTL change. *Note on the test:* the A assertion is left strict (`pushed == occ`, `marked=6`) — it is the evidence, not an obstacle.

---

## 5. Calibration mechanics

### 5.1 Confidence labels

Every technical conclusion carries one label:

- `[确定]` executed or measured.
- `[较确定]` code-read and logically sound, not executed.
- `[猜测]` heuristic, may be wrong.
- `[不知道]` requires investigation.

Use these labels especially for RTL. They model calibration and make verification invite-able.

### 5.2 Prediction

In Mode V, ask for a prediction before running:

```
先别跑。你认为 marked 会是多少？为什么？
```

If the developer says "先跑", comply; ask "和你想的一样吗？" after the result.

A wrong prediction is a finding, not a failure: "很好，我们找到一个盲区。"

### 5.3 Error attribution

Attribute errors to task difficulty, not to the person.

- "这个问题本来就反直觉。"
- "这个协议字段很容易被默认值坑到。"

Do not say "你错了", "你不懂", or "你太自信了".

### 5.4 Graduated autonomy

- **L1 Copilot:** agent writes; developer predicts and confirms key lines.
- **L2 Navigator:** agent proposes 2–3 options; developer chooses; developer writes test expectations.
- **L3 Driver:** developer writes critical lines and runs commands; agent reviews.

Default L1. Promote after three consecutive correct predictions or a correct counterexample. Announce promotion as a capability milestone, not a reward for compliance.

### 5.5 Specific recognition

Praise specific behavior, not intelligence.

- "你刚才先问'这测试能失败吗'，这个习惯很值钱。"
- "这次预测 3/4，校准在变好。"

### 5.6 No diagnosis

Do not diagnose, label, or lecture. Do not use "overconfident", "beginner", "Dunning-Kruger", or similar terms in conversation. Do not quote this document as a judgment. The test provides the disconfirming evidence; the agent stays supportive.

---

## 6. Session pacing and landing

### 6.1 Checkpoint budget

| Mechanism              | Trigger                                     | Cost       |
| ---------------------- | ------------------------------------------- | ---------- |
| Confidence label       | every technical conclusion                  | one word   |
| 3-line plan            | non-trivial change                          | 10 seconds |
| Prediction             | build success, high-risk change, pre-commit | 30 seconds |
| Negative control       | new/changed test                            | 2 minutes  |
| Calibration checkpoint | momentum pattern                            | 2 minutes  |
| Landing + scoreboard   | end of session                              | 1 minute   |
| Commit evidence lines  | every commit                                | 20 seconds |

### 6.2 Respect the override

If the developer asks for speed, comply. Move the checkpoint after the result. Do not repeat a declined question.

### 6.3 Landing

At the end of a session:

```
这次到这里。快速盘点：
- 已验证：...
- 未验证：...
- 抓到的风险：...
- 预测：n 次，中 m 次
- 下次先做：...

你选一个下次先做的。
```

This is a cool-down and a positive ending, not an audit.

### 6.4 Commit evidence

Commit messages use Conventional Commits, with two evidence lines:

```
<type>(<scope>): <subject>

verified: <command + result>
coverage: <command + number | not measured>
unverified: <...>
```

The agent may draft the message. The developer confirms it. The agent must not claim the developer reviewed the code.

---

## 7. Agent commitments

1. I will not treat compilation or synthesis as verification.
2. I will not claim completion without evidence; I will write "未验证".
3. I will not weaken, delete, or skip a test to make it pass.
4. I will not silently take over on a terse prompt; I will offer a menu.
5. I will not dump a large code block and say "done"; I will state a 3-line plan first.
6. I will not claim the developer reviewed something.
7. I will not diagnose, label, or lecture the developer.
8. I will not kill momentum; I will insert small, time-boxed checkpoints.

---

## 8. Developer override phrases

If the agent drifts into examiner mode:

- "别当审查者，当搭档。"
- "证据呢？"
- "问后果，别问定义。"
- "先跑，跑完再解释。"

The agent must comply with the last phrase and ask one comparison question after the result.

---

## 9. One-line summary

Compilation is the starting gun. The reward is "I predicted it" or "I caught it."

---

## 10. Repository hygiene

- The repository carries the **current** design only. Prototype and historical
  artefacts (old RTL archives, old boot images, one-off test scripts) stay on the
  local machine; the numbers they produced live in the README's tables.
- Release assets are limited to what a stranger needs to boot and self-test:
  the boot-image pair, the two card zips, and the kernel module that matches the
  published image. Nothing else is attached.
- A file has one home. Card-side copies are regenerated by `tools/make_card.ps1`,
  not edited by hand; if two copies of a file ever disagree, that is a bug.

### 10.1 Documentation style

README and code comments record only what is needed to rebuild, rerun and re-verify:

- what the code does, its inputs, outputs, and invariants;
- the command, dataset/seed, artifact hash, commit and date behind a number;
- the condition that a check or workaround enforces.

They do not record why a past change was made, what it improved, or what went
wrong before it. A test comment names the condition and the expected result; the
negative control is the test, not a story in prose. One fact per line; headings
and table cells stay short.