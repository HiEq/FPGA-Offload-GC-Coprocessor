# tools/build_routes/ — C / DMA 建图验证入口

新增的 **C/DMA 建图**验证工具。不改动 RTL，也不改动 Python BFS 的测量基线；脚本经串口把
程序推到板上 `/tmp` 运行，不写 USERDATA，因此不依赖卡镜像更新。

## 文件

| 文件 | 作用 |
| --- | --- |
| `run_c_build.ps1` | 主机入口 1：推送并运行 C direct + C cached 验证 |
| `run_dma_build.ps1` | 主机入口 2：加载 `fogccc_dma.ko`，运行 PL330 DMA 验证 |
| `show_compare.ps1` | 实时 C/DMA 验证 + 两组四路对比，停在 `Press any key` 供截图 |
| `fpga_build_routes.sh` | 卡上入口（同 `artifacts/userdata/fpga_build_routes.sh`）|
| `board-exec.ps1` | 串口登录 + 执行 + 解析提示符 |
| `board-push.ps1` | base64 分块推送 + MD5 校验 |

板端四路脚本在 `tools/tests/four_way_c_build.py`、`four_way_dma_build.py`；源码在
`csrc/build_routes/`；二进制在 `artifacts/userdata/bin/` 与 `artifacts/userdata/ko/`。

## 运行

```powershell
cd tools/build_routes

# C 建图验证
powershell -ExecutionPolicy Bypass -File .\run_c_build.ps1 -Port auto

# DMA 建图验证（自动 insmod / rmmod）
powershell -ExecutionPolicy Bypass -File .\run_dma_build.ps1 -Port auto

# 实时 C/DMA 对比控制台（截图用）
powershell -ExecutionPolicy Bypass -File .\show_compare.ps1 -Port COM3
```

- `-Build`：调用 `csrc/build_routes/build_c.sh` 或 `build_dma.sh` 重新交叉编译；
- `-NoPush`：板上 `/tmp` 已有二进制时跳过推送；
- `-KeepModule`：DMA 验证后保留 `fogccc_dma.ko`。

日志写入 `tools/logs/board_build_routes_c.log` / `board_build_routes_dma.log`。

## 卡上分发

同一批板端文件也随 `card-userdata.zip` 分发：

```text
fpga_build_routes.sh
bin/verify_c_build
bin/verify_dma_build
bin/dma_build_one
ko/fogccc_dma.ko
tests/four_way_c_build.py
tests/four_way_dma_build.py
```

板上运行：

```sh
cd /run/media/USERDATA-mmcblk0p2
sh fpga_build_routes.sh
```

`tools/make_card.ps1` 从 `tools/tests/` 与 `tools/build_routes/` 刷新 `artifacts/userdata/`；
`tools/make_manifest.ps1` 的 `SHA256SUMS` 已包含三个程序与一个模块。

## 判据

```text
C_BUILD_RESULT OK            C direct 4.97–5.38 ms，cached 2.04–2.08 ms
DMA_BUILD_RESULT OK          build 1.91–2.17 + staging 0.15–0.22 + DMA 0.20–0.24 ms
C_FOUR_WAY_RESULT OK         4000 对象端到端 5.61–6.03 ms（C cached 2.69–2.73 ms）
DMA_FOUR_WAY_RESULT OK       4000 对象端到端 2.90–6.00 ms
BUILD_ROUTES_DONE            卡上顺序执行四项后打印
```

端到端 = 建图 + 标记（FPGA 约 0.645 ms），相对 Python 建图 102.85 ms 为 17–36×。
日志与逐项数字见 `tools/logs/board_build_routes*.log`。

## 边界

- 只改“建图”，不改 FPGA 标记引擎；四路表中的 FPGA / C-u / C-c / Python 标记基线不变；
- DMA 是 **PS → PL330 mem-to-mem**，不是 PL AXI DMA；
- `fogccc_dma.ko` 按当前 FOGCCC 内核 `6.18.10-xilinx-g4f7afe14f724` 编译，换镜像后需 `-Build` 重建。
