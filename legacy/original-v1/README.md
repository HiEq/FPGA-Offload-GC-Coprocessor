# original-v1 —— 优化前的工程文件（存档）

优化前的 RTL，对应 README 性能表中的 Ver1（单笔未完成读）。原样取自 git 历史，用于对照与回退。

- 来源：提交 `b231a43`
- 内容：`rtl/`（6 个 .v）+ `vivado/build.tcl`
- 与当前版本的差异：

| 文件 | 优化前 | 现在 |
| --- | --- | --- |
| `gc_axi_read.v` | 单笔单拍读，引擎需等 `rd_done` 才能发下一笔 | 读命令队列，多笔未完成读 |
| `gc_mark_engine.v` | 每对象 2 + ref_count 次串行读，无预取，逐引用 6 拍 | 头两笔并发 + 引用压入/取回交错 + 对象头预取，逐引用 2 拍 |
| `gc_bitmap.v` | 单地址口，读写共用 | 读/写地址独立 |
| `gc_top.v` | AXI HP 于 FCLK1 = 200MHz，带 2FF CDC | 统一 FCLK0 = 100MHz，无 CDC |

- 实测性能：90.2 拍/对象，当前版本 15.4 拍/对象。

## 取完整的优化前工程

本目录仅存 RTL 与 `build.tcl`。完整工程树按标签取：

```bash
git checkout v1-original
```

## 直接运行

启动镜像见 Release `v1-original`：

| 文件 | 大小 | md5 |
| --- | --- | --- |
| `BOOT.BIN` | 18,582,708 B | `A33C0591E8455C798955DEB18493B0E6` |
| `image.ub` | 43,213,279 B | `2B446CFB755CB4FC9CB9A15A159BE6E7` |

放置位置：TF 卡 BOOT 分区（FAT32）根目录。

> `image.ub` 与 v4 通用（PS7 参数未改），`BOOT.BIN` 必须使用 Ver1 版本。
