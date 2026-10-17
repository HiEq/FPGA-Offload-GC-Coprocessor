# `fogccc_irq` — 中断驱动的完成通知（验证用）

`gc_top.irq_o` 等于引擎的 `done`，接到 `ps7_0/IRQ_F2P[0]`，即 GIC 中断 ID 61
（`ISPENDR1` bit 29）。该模块用于验证「PL 完成 → GIC → 内核 → 用户态」整条链路。

## 接口

```
/dev/fogccc_irq
    read()        -> "<count> <armed> <virq>\n"
    write("arm")  -> enable_irq()
    write("dis")  -> disable_irq_nosync()
```

`done` 为电平信号且持续保持高，因此处理函数内立即 `disable_irq_nosync()`，
否则同一中断线会重复触发；用户态在新一轮运行清掉 `done` 之后再 `write("arm")`。

## 构建

使用 PetaLinux 的模块 recipe（`driver/plnx/`）：

```bash
source ~/xilinx/petalinux/settings.sh
cd ~/xilinx/fogccc2_linux
cp -r <repo>/driver/plnx/fogccc-irq project-spec/meta-user/recipes-modules/
petalinux-build -c fogccc-irq
find build/tmp/sysroots-components -name 'fogccc-irq.ko'
```

> 不能 out-of-tree 编译：`do_rm_work` 会清掉内核构建目录（`.config` /
> `Module.symvers`），只能使用 Yocto 的 `module` bbclass。

## 两个已知问题

1. **GIC 的 irq domain 是 hierarchy 域**：其 ops 只有 `.translate` / `.alloc`，
   没有 `.map`。`irq_create_mapping()` 走 `.map` 路径，会返回半成品 descriptor
   并丢弃错误码，随后 `request_irq()` 返回 `-ENOSYS`
   （`kernel/irq/manage.c`: `desc->irq_data.chip == &no_irq_chip`）。
   正确做法是 `irq_domain_alloc_irqs(dom, 1, NUMA_NO_NODE, &fwspec)`。

2. **`irq_fwspec.param[1]` 是 SPI 编号，不是中断 ID**：
   `gic_irq_domain_translate()` 会加 32。传 61 会映射到 hwirq 93，正确值为
   61 − 32 = 29 → hwirq 61。判断依据：`ISPENDR1` bit 29（= hwirq 61）随 `done` 置位。

## 上板验证

```sh
# 前提：PL 刚配置完，done = 0
insmod fogccc-irq.ko
cat /dev/fogccc_irq        # "0 0 <virq>"
echo arm > /dev/fogccc_irq
cat /dev/fogccc_irq        # "0 1 <virq>"  此时无中断
python3 gc_test.py 1024 1 2 --seed 11      # done 0 -> 1
cat /dev/fogccc_irq        # "1 0 <virq>"  中断到达，中断线自动关闭
dmesg | tail               # "fogccc: irq fired (#1), line disabled"
```

亦可直接运行 `tools/irq_drv_test.sh`，自动判定 `IRQ_DRIVEN_DONE_OK`。

## 验证范围

- 已覆盖：virq 自动映射（hwirq 61）、`request_irq`、`arm` 后 `done` 上升触发一次、
  处理函数关线不产生重复触发、`rmmod` 正常。
- 不适用：中断丢失率、多中断源、驱动与 DMA 并发。产品侧轮询 `CYCLES` 寄存器，
  中断不参与关键路径；本设计只有一个引擎、一条 `irq_o`，无 DMA 驱动。
  该链路的作用是验证审计项 #1（`irq_o` 原为悬空）已接通。
