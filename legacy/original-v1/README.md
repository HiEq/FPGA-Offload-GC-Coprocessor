# original-v1 —— 优化前的工程文件（存档）

这是 **优化前** 的 RTL，也就是 README 表格里 **Ver1（原始设计：单笔未完成读）** 那一版，
原样从 git 历史取出，便于对照 / 回退 / 复现。

- 来源：提交 `b231a43`（优化前的最后一个提交）
- 内容：`rtl/`（6 个 .v）+ `vivado/build.tcl`
- 与当前版本的差异：
  | 文件 | 优化前 | 现在 |
  | --- | --- | --- |
  | `gc_axi_read.v` | 单笔单拍读，引擎必须等 `rd_done` 才发下一笔 | 读命令队列（命令/数据 FIFO，多笔未完成读） |
  | `gc_mark_engine.v` | 每对象 `2 + ref_count` 次串行读；无预取；逐引用 6 拍 | 头两笔并发 + 引用压入/取回交错 + 对象头投机预取；逐引用 2 拍 |
  | `gc_bitmap.v` | 单地址口（读写共用） | 读/写地址独立（简单双口 BRAM） |
  | `gc_top.v` | AXI HP 跑 FCLK1 = 200MHz，带 2FF CDC 同步器 | 统一 FCLK0 = 100MHz，无 CDC |
- 实测性能：**90.2 拍/对象**（现在是 38.9，即 2.32x）

## 取完整的优化前工程

上面只是 RTL + build.tcl 的存档。**整棵优化前工程树**可以用标签取：

```bash
git checkout v1-original        # 或在 GitHub 的 Tags 页面直接下载 zip
```
