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
