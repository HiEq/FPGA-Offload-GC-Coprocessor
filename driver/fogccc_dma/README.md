# fogccc_dma — 建图 DMA staging 模块

C/DMA 建图验证用的最小内核模块，不改变现有 RTL，也不接入产品驱动。

## 接口

- `/dev/fogccc_dma`；
- 初始化时申请 256 KiB **coherent** staging buffer；
- `FOGCCC_DMA_IOC_INFO`：返回 `size` / `src_phys` / `dst_phys`；
- `FOGCCC_DMA_IOC_COPY`：把 staging buffer 经 PL330 mem-to-mem DMA 搬到调用者给出的物理地址（验证脚本传 `0x1E000000`）；
- 用户态 `mmap` staging buffer 后填入图字节，再触发 ioctl。

## 边界

- 这是 **PS → PL330** 的 mem-to-mem，不是 PL 里的 AXI DMA；
- 目的地址是保留的图窗 `0x1E000000`，不是 Linux System RAM；
- coherent staging 避免 CPU cache 与 DMA 的一致性处理，因此没有额外的 cache flush 路径；
- 模块只用于建图路径验证，不参与标记引擎的数据通路。

## 构建

```bash
SDK_ENV=<sdk> KERNEL_BUILD=<linux build dir> ./csrc/build_routes/build_dma.sh
```

需要与板卡镜像匹配的 PetaLinux 内核构建树；默认路径见脚本，可用 `KERNEL_BUILD=<path>`
覆盖。产物写入 `artifacts/userdata/ko/fogccc_dma.ko`，内核版本 `6.18.10-xilinx-g4f7afe14f724`。
