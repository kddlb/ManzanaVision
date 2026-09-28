/* SPDX-License-Identifier: GPL-2.0-only */
/* Internals shared by the core's implementation files */
#ifndef MZV_CORE_H
#define MZV_CORE_H

#include <libusb.h>
#include <stdatomic.h>

#include "manzana.h"
#include "dib0700.h"
#include "psi.h"

struct mzv_device {
	struct dib0700 *bridge;
	atomic_bool cancel;
	struct mzv_device_info info;
	int tuned_rf;		/* 0 = none */

	/* uncorrectable-packet rate: the demod count is windowed, see signal_fill */
	bool have_ucb;
	u16 last_ucb;
	unsigned long last_ucb_ms;
	double ucb_rate;
};

void mzv_log(enum mzv_log_level level, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

/* Fills a mzv_mux's PSI fields from a parser (shared by scan and offline) */
void mzv_mux_fill_psi(struct mzv_mux *out, const struct psi_mux *m);

#endif
