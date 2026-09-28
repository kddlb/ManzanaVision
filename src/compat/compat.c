// SPDX-License-Identifier: GPL-2.0-only
/* Runtime half of the kernel shim: time, sleeps, I2C dispatch, debug params. */
#include "kcompat.h"
#include <linux/i2c.h>
#include <time.h>

int kcompat_debug;

#define MAX_PARAMS 16
static struct { const char *name; int *var; } params[MAX_PARAMS];
static int nparams;

void kcompat_register_param(const char *name, int *var)
{
	if (nparams < MAX_PARAMS) {
		params[nparams].name = name;
		params[nparams].var = var;
		nparams++;
	}
}

/* Sets every registered driver "debug" param (and printk output) to level. */
void kcompat_set_debug(int level)
{
	kcompat_debug = level;
	for (int i = 0; i < nparams; i++)
		if (strstr(params[i].name, ".debug"))
			*params[i].var = level;
}

unsigned long kcompat_jiffies(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (unsigned long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void sleep_us(unsigned long us)
{
	struct timespec ts = { .tv_sec = us / 1000000, .tv_nsec = (us % 1000000) * 1000 };

	while (nanosleep(&ts, &ts) == -1 && errno == EINTR)
		;
}

void msleep(unsigned int ms) { sleep_us((unsigned long)ms * 1000); }
void usleep_range(unsigned long min_us, unsigned long max_us) { (void)max_us; sleep_us(min_us); }

int i2c_transfer(struct i2c_adapter *adap, struct i2c_msg *msgs, int num)
{
	if (!adap || !adap->algo || !adap->algo->master_xfer)
		return -ENODEV;
	return adap->algo->master_xfer(adap, msgs, num);
}
