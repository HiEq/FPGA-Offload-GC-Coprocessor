// SPDX-License-Identifier: GPL-2.0
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
 * image.ub 的 kernel 子镜像约 101 MiB, 默认上限不足.
 * 上调至 256 MiB; CONFIG_ 与 CFG_ 两种拼写同时定义.
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
