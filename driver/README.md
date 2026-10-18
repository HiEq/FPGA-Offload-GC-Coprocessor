# `fogccc_irq` — 中断完成通知

`gc_top.irq_o`（`done`）接 `ps7_0/IRQ_F2P[0]`，GIC 中断 ID 61（`ISPENDR1` bit 29）。

## 接口

```
/dev/fogccc_irq
    read()        -> "<count> <armed> <virq>\n"
    write("arm")  -> enable_irq()
    write("dis")  -> disable_irq_nosync()
```

`done` 为电平信号并保持高电平，处理函数内 `disable_irq_nosync()`；
用户态在下一轮运行前 `write("arm")`。

## 映射

GIC 的 irq domain 为 hierarchy 域，ops 仅有 `.translate` / `.alloc`，因此使用
`irq_domain_alloc_irqs(dom, 1, NUMA_NO_NODE, &fwspec)`。

`irq_fwspec.param[1]` 为 SPI 编号，`gic_irq_domain_translate()` 会加 32：
`IRQ_F2P[0]` = 中断 ID 61 = SPI 29 = hwirq 61。

模块参数 `irq=N` 可直接指定 virq。

## 构建

使用 PetaLinux 模块 recipe（`driver/plnx/`）：

```bash
source ~/xilinx/petalinux/settings.sh
cd ~/xilinx/fogccc2_linux
cp -r <repo>/driver/plnx/fogccc-irq project-spec/meta-user/recipes-modules/
petalinux-build -c fogccc-irq
find build/tmp/sysroots-components -name 'fogccc-irq.ko'
```

内核构建目录在 `do_rm_work` 之后不再保留，模块通过 Yocto 的 `module` bbclass 构建。

## 上板验证

```sh
insmod fogccc-irq.ko
cat /dev/fogccc_irq        # "0 0 <virq>"
echo arm > /dev/fogccc_irq
cat /dev/fogccc_irq        # "0 1 <virq>"
python3 gc_test.py 1024 1 2 --seed 11
cat /dev/fogccc_irq        # "1 0 <virq>"
dmesg | tail               # "fogccc: irq fired (#1), line disabled"
```

`tools/tests/irq_drv_test.sh` 自动判定 `IRQ_DRIVEN_DONE_OK`。

## 覆盖范围

- 覆盖：virq 映射（hwirq 61）、`request_irq`、`arm` 后单次触发、
  处理函数关线、`rmmod`。
- 不覆盖：中断丢失率、多中断源、DMA 并发。产品路径轮询 `CYCLES`，中断不参与。
