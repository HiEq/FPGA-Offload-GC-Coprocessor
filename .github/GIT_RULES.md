# Git 与合并规则

本文件是 **main 分支的合并契约**。规则有两层：本地钩子（提示、可绕过）和
服务端 ruleset（不可绕过）。服务端那一层以 `.github/rulesets/main.json` 为准。

## 1. 分支

| 允许 | 例子 | 说明 |
| --- | --- | --- |
| `<type>/<slug>` | `ci/strict-gates`、`fix/axi-flush` | `type` 取下面 commit 类型之一；`slug` 只含 `[a-z0-9._-]` |
| 禁止 | `main`、`dev-hieq`、`patch` | 长期分支一条都不要；合并后立刻删除 |

- 一个 PR 一条分支，一条分支一件事。`main` 不允许直接 push（服务端强制）。
- 分支落后于 `main` 时用 `git rebase`，不要 `git merge main`（服务端要求线性历史，
  最终只允许 squash 合并，中间合并提交没有意义）。

## 2. Commit

格式：`<type>(<scope>): <subject>`

```
feat(gc): add the root-clamp saturation case
fix(axi): drop the same-cycle R beat on run_start
docs(readme): quote the release-asset hash for v4.1
test(gate): prove the branch rule rejects dev-hieq
ci: pin the checkout action to a commit SHA
```

- `type` ∈ `feat fix docs test refactor perf build ci chore revert`（在 `tests/gate.py` 里定义）。
- subject ≤ 72 字符、小写开头、不以 `.` 结尾、≥ 10 字符；`scope` 可选，小写。
- 第二行必须空行，正文每行 ≤ 100 字符。
- 一个 commit 一件事；RTL / XDC / 寄存器映射的改动不与文档或格式化混在一起。
- 附带证据（与 `AGENTS.md` §4.8 一致）：

  ```
  verified: python3 -m unittest discover -s tests -p "test_*.py"
  coverage: not measured
  unverified: 未上板
  ```

## 3. Pull Request

- 目标分支只能是 `main`；标题与 commit subject 同格式（squash 后它就是 commit 标题）。
- 正文用 `.github/pull_request_template.md`，必须含 `verified:` 与 `unverified:` 两行。
  缺失时 `pr-policy` 直接失败。
- 合并方式只有 **squash**；合并后删除 head 分支。
- 通过条件（全部，缺一不可）：
  1. `lint`、`contract`、`commit-policy`、`pr-policy` 四个检查全绿；
  2. 分支与 `main` 同步（`strict_required_status_checks_policy`）。
- **不要求 approval**：`required_approving_review_count = 0`，
  `require_code_owner_review = false`，`require_last_push_approval = false`。
  `CODEOWNERS` 仍然存在，但只用于自动请求 reviewer，不参与合并判断。
- 分支名、commit 格式、PR 标题与证据两行是 **CI 检查**（`commit-policy` /
  `pr-policy`），不是 approval 检查；它们失败时 PR 直接红，无需人工 Review。

## 4. CI 检查

| 检查 | 工作流 | 内容 | 不是什么 |
| --- | --- | --- | --- |
| `lint` | `.github/workflows/lint.yml` | shell/Python/PowerShell 语法、`ruff`（未定义名/语法）、`iverilog` 解析、`gcc -fsyntax-only`、`SHA256SUMS`、`tb_runstart_race` / `tb_cmdfifo_flush` / `tb_stale_ar_flush` / `tb_flush_data` / `tb_start_while_busy`、C 驱动 host 单测 | 不综合、不 xsim、不上板 |
| `contract` | `.github/workflows/gate.yml` | `tests/` 静态契约：寄存器/STATUS/参数/API/证据日志/仓库卫生/EOL/workflow 策略/RTL 阻塞赋值/硬编码 ratchet | 不证明时序与功能 |
| `commit-policy` | 同上 | PR 范围内每个非 merge commit 的格式 | 不检查内容正确性 |
| `pr-policy` | 同上 | PR 标题、head 分支名、目标分支、证据两行 | 不检查正文质量 |

`verilator`/`shellcheck` 之类未接入：接入前先在本地跑一遍，确认现有代码是绿的，
否则等于把 main 锁死。

## 5. 启用服务端规则（需要 **admin**）

当前 `@ChalkCalliope` 是 `write`，改不了规则。由 `HiEq` 执行下面任一方式。

方式 A —— 命令行（推荐，规则与仓库里的 JSON 完全一致）：

```powershell
gh api --method PUT repos/HiEq/FPGA-Offload-GC-Coprocessor/rulesets/25292330 `
  --input .github/rulesets/main.json
```

方式 B —— 网页：**Settings → Rules → Rulesets → `Protect main` → Edit**，逐项对齐
`.github/rulesets/main.json`：Block force pushes、Restrict deletions、Require linear
history、Require a pull request（**0 approvals**，不要勾 code owner review / last push
approval / conversation resolution，合并方式只留 squash）、
Require status checks（`lint`、`contract`、`commit-policy`、`pr-policy`，勾选
"Require branches to be up to date"）。

同时打开 **Settings → General → Pull Requests → Automatically delete head branches**。

### 启用顺序（很重要）

1. 先合入本 PR（此时 ruleset 还没要求新检查，所以能合）。
2. 确认 `gate` 工作流已经在这个 PR 上跑过一次，四个检查名字在
   **Settings → Branches → Required checks** 的候选列表里出现过。
3. 再执行上面的 `gh api` / 网页操作。顺序反了，`main` 会卡在"required check 永远
   不出现"的状态。

### 锁死了怎么恢复（break-glass）

`bypass_actors` 为空，admin 也不能绕过。CI 自己坏了导致无法合并时：

1. **Settings → Rules → Rulesets → `Protect main`**，把 Enforcement 改成 **Disabled**；
2. 用 PR 修 CI（仍然走 PR，只是暂时不做检查）；
3. 修好后恢复 **Active**。

不要用 `git push --force`；`non_fast_forward` 会拒绝，历史也不需要重写。

## 6. 本地钩子（可选但建议）

```powershell
git config core.hooksPath .githooks
```

| 钩子 | 作用 |
| --- | --- |
| `commit-msg` | 用 `tests/gate.py` 检查 commit 格式；`git merge` 期间放行 |
| `pre-push` | 拒绝推送 `refs/heads/main`；其余分支放行 |

钩子需要 `python3` 或 `python` 在 PATH 上；找不到时只警告、不阻断（服务端 CI 才是权威）。

## 7. 改规则的规则

`/.github/` 与 `/AGENTS.md` 归 `@ChalkCalliope` 所有。修改门禁本身（放宽检查、改
`tests/gate.py`、改 ruleset）必须单独开 PR，并在正文写清"放宽了哪一条、为什么"。
