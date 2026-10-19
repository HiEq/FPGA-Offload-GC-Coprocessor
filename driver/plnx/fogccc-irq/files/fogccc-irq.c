// SPDX-License-Identifier: GPL-2.0
/*
 * fogccc_irq.c - completion interrupt for the FOGCCC GC engine
 *
 * Event   : gc_top.irq_o (done) -> ps7_0/IRQ_F2P[0] -> GIC SPI 61
 * Level   : level high, held until the engine is restarted
 * Mapping : no device tree node; the module resolves the GIC irq domain
 *           (arm,cortex-a9-gic) and allocates SPI 29 / hwirq 61.
 *           Module parameter irq=N overrides the mapping.
 *
 *   /dev/fogccc_irq
 *     read()        -> "<count> <armed> <virq>\n"
 *     write("arm")  -> enable_irq()
 *     write("dis")  -> disable_irq_nosync()
 *
 * The module does not access PL registers; graph and control registers
 * remain with the /dev/mem interface.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/string.h>
#include <linux/interrupt.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/uaccess.h>
#include <linux/irq.h>
#include <linux/irqdomain.h>
#include <linux/numa.h>
#include <linux/of.h>
#include <linux/of_irq.h>
#include <linux/irqdesc.h>
#include <linux/atomic.h>

#define FOGCCC_SPI   61        /* IRQ_F2P[0] on Zynq-7000 */

static int irq = -1;
module_param(irq, int, 0444);
MODULE_PARM_DESC(irq, "Linux virq to use; -1 (default) maps SPI 61 in the GIC domain");

static int virq;
static atomic_t irq_count = ATOMIC_INIT(0);
static atomic_t armed     = ATOMIC_INIT(0);

/* Resolve the GIC irq domain and allocate SPI 61. */
static int fogccc_map_virq(void)
{
	struct device_node *np;
	struct irq_domain *dom;
	struct irq_fwspec fwspec;
	int ret;

	np = of_find_compatible_node(NULL, NULL, "arm,cortex-a9-gic");
	if (!np) {
		pr_err("fogccc: GIC node not found in the device tree\n");
		return -ENODEV;
	}
	dom = irq_find_host(np);
	if (!dom) {
		pr_err("fogccc: GIC irq domain not found\n");
		of_node_put(np);
		return -ENODEV;
	}
	pr_info("fogccc: domain '%s' map=%s alloc=%s\n",
		dom->name ? dom->name : "?",
		dom->ops && dom->ops->map ? "yes" : "no",
		dom->ops && dom->ops->alloc ? "yes" : "no");

	fwspec.fwnode      = of_node_to_fwnode(np);
	fwspec.param_count = 3;
	fwspec.param[0]    = 0;                    /* GIC_SPI */
	/*
	 * The DT cell carries the SPI number, not the GIC interrupt ID;
	 * gic_irq_domain_translate() adds 32.  IRQ_F2P[0] is GIC ID 61
	 * (ISPENDR1 bit 29), i.e. SPI number 29.
	 */
	fwspec.param[1]    = FOGCCC_SPI - 32;      /* 61 -> 29 -> hwirq 61 */
	fwspec.param[2]    = IRQ_TYPE_LEVEL_HIGH;  /* level line */

	ret = irq_domain_alloc_irqs(dom, 1, NUMA_NO_NODE, &fwspec);
	of_node_put(np);
	if (ret < 0) {
		pr_err("fogccc: irq_domain_alloc_irqs(SPI %d) = %d\n",
		       FOGCCC_SPI, ret);
		return ret;
	}
	virq = ret;
	{
		struct irq_data *d = irq_get_irq_data(virq);
		pr_info("fogccc: virq %d chip=%ps hwirq=%lu\n", virq,
			d && d->chip ? d->chip : NULL,
			d ? (unsigned long)d->hwirq : 0UL);
	}
	return 0;
}

static irqreturn_t fogccc_irq_handler(int irqno, void *dev_id)
{
	atomic_inc(&irq_count);
	atomic_set(&armed, 0);
	/* level-triggered: mask the line after the first event */
	disable_irq_nosync(irqno);
	pr_info("fogccc: irq fired (#%d), line disabled\n",
		atomic_read(&irq_count));
	return IRQ_HANDLED;
}

static ssize_t fogccc_read(struct file *f, char __user *buf, size_t len,
			   loff_t *off)
{
	char tmp[48];
	int n = snprintf(tmp, sizeof(tmp), "%d %d %d\n",
			 atomic_read(&irq_count), atomic_read(&armed), virq);

	if (*off >= n)
		return 0;
	if (len > n - *off)
		len = n - *off;
	if (copy_to_user(buf, tmp + *off, len))
		return -EFAULT;
	*off += len;
	return len;
}

static ssize_t fogccc_write(struct file *f, const char __user *buf,
			    size_t len, loff_t *off)
{
	char tmp[8];

	if (len >= sizeof(tmp))
		len = sizeof(tmp) - 1;
	if (copy_from_user(tmp, buf, len))
		return -EFAULT;
	tmp[len] = '\0';

	if (!strncmp(tmp, "arm", 3)) {
		/* enable_irq() on an already-enabled line unbalances the IRQ core,
		 * so only the 0->1 transition touches it. */
		if (atomic_cmpxchg(&armed, 0, 1) == 0)
			enable_irq(virq);
		return len;
	}
	if (!strncmp(tmp, "dis", 3)) {
		if (atomic_cmpxchg(&armed, 1, 0) == 1)
			disable_irq_nosync(virq);
		return len;
	}
	return -EINVAL;
}

static const struct file_operations fogccc_fops = {
	.owner = THIS_MODULE,
	.read  = fogccc_read,
	.write = fogccc_write,
};

static struct miscdevice fogccc_misc = {
	.minor = MISC_DYNAMIC_MINOR,
	.name  = "fogccc_irq",
	.fops  = &fogccc_fops,
};

static int __init fogccc_init(void)
{
	struct irq_data *d;
	int ret;

	if (irq >= 0) {
		virq = irq;
	} else {
		ret = fogccc_map_virq();
		if (ret)
			return ret;
	}

	d = irq_get_irq_data(virq);
	if (!d) {
		pr_err("fogccc: virq %d is not mapped\n", virq);
		return -ENODEV;
	}
	pr_info("fogccc: using virq %d (hwirq %lu)\n", virq, (unsigned long)d->hwirq);

	/* request, then mask; userspace arms with write("arm") */
	ret = request_irq(virq, fogccc_irq_handler, 0, "fogccc", &fogccc_misc);
	if (ret) {
		pr_err("fogccc: request_irq(%d) failed: %d\n", virq, ret);
		return ret;
	}
	disable_irq(virq);

	ret = misc_register(&fogccc_misc);
	if (ret) {
		free_irq(virq, &fogccc_misc);
		return ret;
	}
	pr_info("fogccc: ready, /dev/fogccc_irq (virq %d, hwirq %lu)\n",
		virq, (unsigned long)d->hwirq);
	return 0;
}

static void __exit fogccc_exit(void)
{
	misc_deregister(&fogccc_misc);
	free_irq(virq, &fogccc_misc);
	pr_info("fogccc: unloaded after %d interrupts\n",
		atomic_read(&irq_count));
}

module_init(fogccc_init);
module_exit(fogccc_exit);
MODULE_LICENSE("GPL");
MODULE_AUTHOR("HiEq");
MODULE_DESCRIPTION("FOGCCC GC engine completion interrupt (IRQ_F2P[0], SPI 61)");
