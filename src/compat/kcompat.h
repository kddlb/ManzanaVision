/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Minimal Linux kernel API shim so the vendored DiBcom frontend drivers
 * build as ordinary userspace C. Single-threaded: locks are no-ops.
 */
#ifndef _KCOMPAT_H_
#define _KCOMPAT_H_

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* types */
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int8_t s8;
typedef int16_t s16;
typedef int32_t s32;
typedef int64_t s64;
typedef u8 __u8;
typedef u16 __u16;
typedef u32 __u32;
typedef u64 __u64;
typedef s8 __s8;
typedef s16 __s16;
typedef s32 __s32;
typedef s64 __s64;

#ifndef EREMOTEIO
#define EREMOTEIO 121
#endif

#define fallthrough __attribute__((__fallthrough__))
#define __init
#define __exit
#define __user
#define __iomem
#define __always_unused __attribute__((unused))
#define __maybe_unused __attribute__((unused))

#define BIT(n) (1UL << (n))
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define min(a, b) ((a) < (b) ? (a) : (b))
#define max(a, b) ((a) > (b) ? (a) : (b))
#define min_t(t, a, b) min((t)(a), (t)(b))
#define max_t(t, a, b) max((t)(a), (t)(b))

#define likely(x) __builtin_expect(!!(x), 1)
#define unlikely(x) __builtin_expect(!!(x), 0)
#define WARN_ON(x) ({ int __w = !!(x); if (__w) fprintf(stderr, "WARN_ON at %s:%d\n", __FILE__, __LINE__); __w; })

/* fls() comes from libc */
#include <strings.h>

/* every frontend we vendor is built in */
#define IS_REACHABLE(option) 1
#define IS_ENABLED(option) 1

/* 64-bit division in place; returns the remainder */
#define do_div(n, base) ({                        \
	u32 __base = (base);                      \
	u32 __rem = (u32)((u64)(n) % __base);     \
	(n) = (u64)(n) / __base;                  \
	__rem;                                    \
})

/* logging */
extern int kcompat_debug;
#define KERN_SOH ""
#define KERN_ERR ""
#define KERN_WARNING ""
#define KERN_NOTICE ""
#define KERN_INFO ""
#define KERN_DEBUG ""
#define KERN_CONT ""
#define printk(fmt, ...) \
	do { if (kcompat_debug) fprintf(stderr, fmt, ##__VA_ARGS__); } while (0)
#define pr_err(fmt, ...) fprintf(stderr, pr_fmt(fmt), ##__VA_ARGS__)
#define pr_warn(fmt, ...) fprintf(stderr, pr_fmt(fmt), ##__VA_ARGS__)
#define pr_info(fmt, ...) printk(pr_fmt(fmt), ##__VA_ARGS__)
#define pr_debug(fmt, ...) printk(pr_fmt(fmt), ##__VA_ARGS__)
#ifndef pr_fmt
#define pr_fmt(fmt) fmt
#endif
#ifndef KBUILD_MODNAME
#define KBUILD_MODNAME "kcompat"
#endif

/* module boilerplate */
/* int module params register themselves so -v can switch driver debug on */
void kcompat_register_param(const char *name, int *var);
#define module_param(name, type, perm) module_param_named(name, name, type, perm)
#define module_param_named(name, var, type, perm)                          \
	static void __attribute__((constructor)) kc_param_##name(void)     \
	{ kcompat_register_param(KBUILD_MODNAME "." #name, &(var)); }
#define MODULE_PARM_DESC(p, d)
#define MODULE_AUTHOR(a)
#define MODULE_DESCRIPTION(d)
#define MODULE_LICENSE(l)
#define EXPORT_SYMBOL(s)
#define EXPORT_SYMBOL_GPL(s)
#define THIS_MODULE NULL

/* memory */
#define GFP_KERNEL 0
#define kmalloc(sz, flags) malloc(sz)
#define kzalloc(sz, flags) calloc(1, (sz))
#define kzalloc_obj(T) ((T *)calloc(1, sizeof(T)))
#define kfree(p) free(p)

static inline size_t strscpy(char *dst, const char *src, size_t n)
{
	size_t len = strnlen(src, n - 1);
	memcpy(dst, src, len);
	dst[len] = '\0';
	return len;
}

/* locking: the whole program is single-threaded */
struct mutex { int unused; };
#define mutex_init(m) ((void)(m))
#define mutex_lock(m) ((void)(m))
#define mutex_lock_interruptible(m) ((void)(m), 0)
#define mutex_unlock(m) ((void)(m))

/* time: jiffies are milliseconds */
#define HZ 1000
unsigned long kcompat_jiffies(void);
#define jiffies kcompat_jiffies()
#define time_after(a, b) ((long)((b) - (a)) < 0)
#define time_before(a, b) time_after(b, a)
#define msecs_to_jiffies(ms) ((unsigned long)(ms))
#define usecs_to_jiffies(us) ((unsigned long)(((us) + 999) / 1000))
#define jiffies_to_msecs(j) ((unsigned int)(j))

void msleep(unsigned int ms);
void usleep_range(unsigned long min_us, unsigned long max_us);

#endif
