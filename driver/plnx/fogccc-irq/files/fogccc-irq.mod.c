#include <linux/module.h>
#include <linux/export-internal.h>
#include <linux/compiler.h>

MODULE_INFO(name, KBUILD_MODNAME);

__visible struct module __this_module
__section(".gnu.linkonce.this_module") = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};



static const struct modversion_info ____versions[]
__used __section("__versions") = {
	{ 0xae353d77, "arm_copy_from_user" },
	{ 0x84b183ae, "strncmp" },
	{ 0xfcec0987, "enable_irq" },
	{ 0xf0fdf6cb, "__stack_chk_fail" },
	{ 0x5f754e5a, "memset" },
	{ 0x27bbf221, "disable_irq_nosync" },
	{ 0xefd6cf06, "__aeabi_unwind_cpp_pr0" },
	{ 0x0d5a0333, "misc_deregister" },
	{ 0xc1514a3b, "free_irq" },
	{ 0x92997ed8, "_printk" },
	{ 0xc358aaf8, "snprintf" },
	{ 0x51a910c0, "arm_copy_to_user" },
	{ 0x3edfb260, "of_find_compatible_node" },
	{ 0x5343f083, "irq_find_matching_fwspec" },
	{ 0x29e7b853, "of_node_put" },
	{ 0xad318455, "__irq_domain_alloc_irqs" },
	{ 0xfb1126e2, "irq_get_irq_data" },
	{ 0x92d5838e, "request_threaded_irq" },
	{ 0x3ce4ca6f, "disable_irq" },
	{ 0x9c57bb20, "misc_register" },
	{ 0x3bb12b66, "param_ops_int" },
	{ 0x884d03a6, "module_layout" },
};

MODULE_INFO(depends, "");

