# tests/ —— 静态契约测试

`gate` 工作流跑的就是这个目录。它**只读文本**：不综合、不仿真、不连板子。
全绿的含义是"源码、寄存器映射、文档、工作流彼此一致"，不是"设计能用"
（证据分级见 `AGENTS.md` §4.2）。

```bash
python3 -m unittest discover -s tests -p "test_*.py" -v
```

Windows 上把 `python3` 换成 `python`。只依赖标准库。

## 覆盖什么

| 文件 | 检查 |
| --- | --- |
| `test_repo_contract.py` | 寄存器偏移（`fpga_gc.h` ↔ `gc_regs.v` ↔ README 表）；STATUS 位顺序与 RTL 拼接顺序；MAGIC/VERSION；`MAXO`/`QD`/`PD`/`DQD`/对象上限（RTL ↔ README ↔ HP 口 `NUM_READ_OUTSTANDING`）；驱动 API（头文件 ↔ 实现）；ctypes 绑定（只调用导出符号、调用必有 `argtypes`）；`make card` 副本与源文件逐字节一致；README 引用的证据日志存在且已入库；Release 哈希与 `SHA256SUMS.release` 一致；仓库卫生（二进制/1 MiB 上限/UTF-8/EOL）；testbench 无孤儿；`sim/run_*` 两种 shell 齐全；workflow 权限最小化 + action 固定 SHA；ruleset 要求的检查名真的存在；RTL 时钟块里没有阻塞赋值 |
| `test_gate.py` | `gate.py` 每条规则的**反向验证**：合规输入通过、违规输入必须失败 |
| `hardcoded.py` | 硬编码 ratchet 的扫描器：`--check` 与 `--write-baseline` |
| `test_hardcoded.py` | ratchet 每条规则的反向验证 + 全仓库只允许"不超过 baseline" |

## 硬编码 ratchet

`contract` job 会跑 `test_hardcoded.py`。规则是**只拦新增**：

- `magic`：`≥1000` 的十进制、`≥3` 位十六进制、Verilog 带位宽字面量；
  `#define` / `parameter` / `localparam` / `const` 声明行豁免（那正是"命名"）。
- `seed`：`random.seed(<字面量>)` / `random.Random(<字面量>)`，种子必须来自 `--seed`。
- `path`：代码文件（含 `.bat`/`.cmd`）里的 `C:\...`、`/home/<user>/...`、`COM<n>`、IPv4；`/mnt/userdata` 是板子契约，不算。
- `hostpath`：`.md`/`.yml` 等文档只查 `C:\...`、`/home/<user>/`、`/Users/<user>/`，不查 COM/IPv4，避免示例误报。
- `secret`：私钥块、`AKIA…`、`ghp_…`、`xox…-`、`sk-…`。**这条不能进 baseline**。

测试文件（`sim/`、`tools/tests/`、`tb_*`、`test_*`）不参与前三类：按 `AGENTS.md` §4.3，
期望值必须是独立 oracle，写死常量是正确做法。

新增一个字面量时，按优先级处理：

```c
// 1) 命名成常量（首选）
#define GC_CAP 4096
uint32_t cap = GC_CAP;

// 2) 确实是契约，就单行豁免，并写理由
uint32_t cap = 4096;  // allow-hardcoded: FIFO 深度与队列 BRAM 深度一致
```

```bash
python3 tests/hardcoded.py --write-baseline   # 3) 确认要保留，就更新 baseline
```

把 baseline 改小永远放行；`git diff` 里看到 baseline 变大，PR 里必须解释。

## 不覆盖什么

- 功能正确性、AXI 协议、时序收敛：靠 `sim/`（xsim/Icarus）与 `tools/logs/` 里的板上证据。
- 二进制是否与源码同源：只能靠 `artifacts/SHA256SUMS`（`lint` 工作流用
  `tools/make_manifest.ps1 -Check` 挡）。
- 覆盖率：这些是文本断言，没有行覆盖概念。不报"覆盖率 87%"这种数字。

## 加一条检查

1. 先写测试，确认它在**当前**代码上失败（否则它测不到东西）。
2. 把解析逻辑拆成纯函数（输入是文本），再用一个改坏的字符串做反向验证。
3. 如果检查会挡住别人的正常改动，先和 owner 商量，再放宽或加 `ci-allow-*` 标记；
   不要偷偷把断言删掉。

## Gate status

The strict `Protect main` ruleset (`.github/rulesets/main.json`) is applied: main
runs the four gate checks on every pull request and declines a direct push to main
unless the pushed commit is the head of an open pull request whose checks are green;
the enforced behaviour was observed in both directions.