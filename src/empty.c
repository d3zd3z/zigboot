// SPDX-License-Identifier: Apache-2.0
/*
 * The Zephyr build system demands a source file in this directory.
 * This file can be used for C interface stubs as they are needed.
 */

#include <zephyr.h>
#include <drivers/timer/system_timer.h>
#include <string.h>

int __empty;

/*
 * Zig builds with LLVM, whereas Zephyr is built with GCC.  As such,
 * we may need to implement some of its expected functions.
 */

/* Note that the arguments are in a different order than memset. */
void *__aeabi_memset(void *data, size_t n, int c)
{
	return memset(data, c, n);
}

/* Not sure what this is about.  Perhaps this should be an alias. */
void *__aeabi_memset4(void *data, size_t n, int c)
{
	return memset(data, c, n);
}

/*
 * Chain jump to the next image from the bootloader.
 */
void chain_jump(uint32_t vt, uint32_t msp, uint32_t pc)
{
	/* The Zig code doesn't know the FLASH_BASE, so add that the
	 * vt.  The other values came from the image and are already
	 * adjusted.
	 */
	vt += FLASH_BASE;

	sys_clock_disable();

#ifdef CONFIG_USB_DEVICE_STACK
	/* Disable the USB to prevent it from firing interrupts */
	usb_disable();
#endif
#if CONFIG_MCUBOOT_CLEANUP_ARM_CORE
	cleanup_arm_nvic(); /* cleanup NVIC registers */

#ifdef CONFIG_CPU_CORTEX_M7
	/* Disable instruction cache and data cache before chain-load the application */
	SCB_DisableDCache();
	SCB_DisableICache();
#endif

#if CONFIG_CPU_HAS_ARM_MPU || CONFIG_CPU_HAS_NXP_MPU
	z_arm_clear_arm_mpu_config();
#endif

#if defined(CONFIG_BUILTIN_STACK_GUARD) && \
    defined(CONFIG_CPU_CORTEX_M_HAS_SPLIM)
	/* Reset limit registers to avoid inflicting stack overflow on image
	 * being booted.
	 */
	__set_PSPLIM(0);
	__set_MSPLIM(0);
#endif

#else
	irq_lock();
#endif /* CONFIG_MCUBOOT_CLEANUP_ARM_CORE */

#ifdef CONFIG_BOOT_INTR_VEC_RELOC
#if defined(CONFIG_SW_VECTOR_RELAY)
	_vector_table_pointer = vt;
#ifdef CONFIG_CPU_CORTEX_M_HAS_VTOR
	SCB->VTOR = (uint32_t)__vector_relay_table;
#endif
#elif defined(CONFIG_CPU_CORTEX_M_HAS_VTOR)
	SCB->VTOR = (uint32_t)vt;
#endif /* CONFIG_SW_VECTOR_RELAY */
#else /* CONFIG_BOOT_INTR_VEC_RELOC */
#if defined(CONFIG_CPU_CORTEX_M_HAS_VTOR) && defined(CONFIG_SW_VECTOR_RELAY)
	_vector_table_pointer = _vector_start;
	SCB->VTOR = (uint32_t)__vector_relay_table;
#endif
#endif /* CONFIG_BOOT_INTR_VEC_RELOC */

	__set_MSP(msp);
#if CONFIG_MCUBOOT_CLEANUP_ARM_CORE
	__set_CONTROL(0x00); /* application will configures core on its own */
	__ISB();
#endif
	((void (*)(void))pc)();
}
