#if defined(CONFIG_MICROBLAZE)
#include <configs/microblaze-generic.h>
#define CONFIG_SYS_BOOTM_LEN 0xF000000
#endif
#if defined(CONFIG_ARCH_ZYNQ)
#include <configs/zynq-common.h>

/* Hardcoded DRAM */
#define CFG_NR_DRAM_BANKS	1
#define CFG_SYS_SDRAM_BASE	0x00000000
#define CFG_SYS_SDRAM_SIZE	0x40000000

/*
 * PetaLinux initramfs image.ub carries a ~101MiB kernel subimage (the
 * initramfs is linked into the kernel Image).  The stock limit is much
 * smaller, so 'bootm' aborts with
 *     "Image too large: increase CONFIG_SYS_BOOTM_LEN"
 * Raise the limit to 256MiB.  Define both the CONFIG_ and CFG_ spellings
 * (U-Boot migrated the symbol to CFG_SYS_BOOTM_LEN) so whichever one the
 * boot code uses gets the bigger value.
 */
#ifdef CONFIG_SYS_BOOTM_LEN
#undef CONFIG_SYS_BOOTM_LEN
#endif
#define CONFIG_SYS_BOOTM_LEN 0x10000000

#ifdef CFG_SYS_BOOTM_LEN
#undef CFG_SYS_BOOTM_LEN
#endif
#define CFG_SYS_BOOTM_LEN 0x10000000

#endif
#if defined(CONFIG_ARCH_ZYNQMP)
#include <configs/xilinx_zynqmp.h>
#endif
#if defined(CONFIG_ARCH_VERSAL)
#include <configs/xilinx_versal.h>
#endif
#if defined(CONFIG_ARCH_VERSAL_NET)
#include <configs/xilinx_versal_net.h>
#endif
