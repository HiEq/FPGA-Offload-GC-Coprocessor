# `fogccc_irq` — 中断驱动的完成通知（验证用）

`gc_top.irq_o` 等于引擎的 `done`，接到 `ps7_0/IRQ_F2P[0]`，即 **GIC 中断 ID 61**
（`ISPENDR1` 的 bit 29）。这个最小模块用来证明「PL 完成 → GIC → 内核 → 用户态」
整条链路是通的。

## 接口

```
/dev/fogccc_irq
    read()        -> "<count> <armed> <virq>\n"
    write("arm")  -> enable_irq()
    write("dis")  -> disable_irq_nosync()
```

`done` 是**电平**信号且会一直保持高，所以处理函数里**立刻**
`disable_irq_nosync()`，否则同一条线会无限重触发；用户态在 `done` 被新一轮
运行清掉之后再 `write("arm")`。

## 构建

走 PetaLinux 的模块 recipe（`driver/plnx/`）：

```bash
source ~/xilinx/petalinux/settings.sh
cd ~/xilinx/fogccc2_linux
cp -r <repo>/driver/plnx/fogccc-irq project-spec/meta-user/recipes-modules/
petalinux-build -c fogccc-irq
find build/tmp/sysroots-components -name 'fogccc-irq.ko'
```

> 不能 out-of-tree 编译：`do_rm_work` 会清掉内核构建目录（`.config` /
> `Module.symvers`），只能借 Yocto 的 `module` bbclass。

## 两个踩过的坑（都实测过）

1. **GIC 的 irq domain 是 hierarchy 域**：它的 ops 只有 `.translate` / `.alloc`，
   **没有 `.map`**。`irq_create_mapping()` 走的是 `.map` 路径，会返回一个
   **半成品 descriptor** 并且丢掉错误码，随后 `request_irq()` 返回 `-ENOSYS`
   （`kernel/irq/manage.c`: `desc->irq_data.chip == &no_irq_chip`）。
   正确做法是 `irq_domain_alloc_irqs(dom, 1, NUMA_NO_NODE, &fwspec)`。

2. **`irq_fwspec.param[1]` 是 SPI 编号，不是中断 ID**：
   `gic_irq_domain_translate()` 会加 32。传 61 会映射到 **hwirq 93**
   （别人的中断），正确值是 **61 − 32 = 29 → hwirq 61**。
   判断依据：`ISPENDR1` 的 bit 29（= hwirq 61）确实会随 `done` 置位。

## 上板验证

```sh
# 前提：PL 刚配置完，done = 0
insmod fogccc-irq.ko
cat /dev/fogccc_irq        # "0 0 <virq>"
echo arm > /dev/fogccc_irq
cat /dev/fogccc_irq        # "0 1 <virq>"  还没有中断
python3 gc_test.py 1024 1 2 --seed 11      # done 0 -> 1
cat /dev/fogccc_irq        # "1 0 <virq>"  中断来了，线被自动关掉
dmesg | tail               # "fogccc: irq fired (#1), line disabled"
```

也可以直接跑 `tools/irq_drv_test.sh`（自动判定 `IRQ_DRIVEN_DONE_OK`）。

## 已验证 / 未验证

- 已验证：virq 自动映射（hwirq 61）、`request_irq`、`arm` 后 `done` 上升触发
  一次、处理函数关线不产生风暴、`rmmod` 正常。
- 未验证：连续高频完成时的丢失率；多引擎/多中断源；驱动与 DMA 并发。
