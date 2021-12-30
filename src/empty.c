// SPDX-License-Identifier: Apache-2.0
/*
 * The Zephyr build system demands a source file in this directory.
 * This file can be used for C interface stubs as they are needed.
 */

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
