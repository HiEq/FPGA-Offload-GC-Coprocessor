# csrc/build_routes/ — C / DMA 建图验证源码

对应报告 §3.3.2 / §4.1 的“用 C 与 DMA 重写建图”路线。三个板端程序：

| 文件 | 作用 |
| --- | --- |
| `verify_c_build.c` | 同一张 4000 对象图上比较 C 直接写 `/dev/mem` 与 C 缓存构建 + 一次 `memcpy`；校验布局、软件 BFS、硬件 bitmap |
| `verify_dma_build.c` | C 缓存构建 → 256 KiB coherent staging → PS PL330 DMA → `0x1E000000`；同一套校验 |
| `dma_build_one.c` | 四路对比用的单图构建工具：`dma_build_one <n> [avg_refs]`，输出 build / stage / DMA 时间 |

## 构建

```bash
# 板上程序（PC，PetaLinux SDK）
SDK_ENV=<sdk> ./csrc/build_routes/build_c.sh

# DMA staging 模块（需匹配板卡内核的构建树）
SDK_ENV=<sdk> KERNEL_BUILD=<linux build dir> ./csrc/build_routes/build_dma.sh
```

产物写入 `artifacts/userdata/bin/`（三个程序）与 `artifacts/userdata/ko/fogccc_dma.ko`。
`build_c.sh` 链接 `csrc/fpga_gc.c`，与现有 C 驱动共用，不复制、不改动原驱动。

## 口径

- 图生成使用与 `fpga_gc_build_graph()` 相同的 `srand(42)` 生成器；
- 只计“建图 + 写入 DDR”，不含标记；
- DMA 是 **PS → PL330 mem-to-mem**，不是 PL AXI DMA；
- 结果与 `tools/logs/board_build_routes*.log` 一致。

上板入口见 `tools/build_routes/README.md`。
