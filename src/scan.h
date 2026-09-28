/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef SCAN_H
#define SCAN_H

#include <stdbool.h>
#include <stdint.h>

#include <media/dvb_frontend.h>

struct dib0700;

struct scan_opts {
	int from, to;			/* RF channel range, inclusive */
	bool json;
	unsigned int psi_timeout_ms;	/* how long to wait for PAT+SDT+NIT */
};

/* Centre frequency of ISDB-T (ABNT/Chile) UHF channel rf, in Hz */
uint32_t isdbt_channel_freq(int rf);

int scan_run(struct dib0700 *d, const struct scan_opts *o);

/*
 * Tunes one channel and reports it like scan does. With dump_path, also
 * writes the raw TS for `seconds` seconds.
 */
int tune_run(struct dib0700 *d, int rf, const char *dump_path, unsigned int seconds);

/* request a clean stop from a signal handler */
void scan_interrupt(void);
bool scan_interrupted(void);

/* Names for TMCC values, shared with the signal meter */
const char *isdbt_mod_name(enum fe_modulation m);
const char *isdbt_fec_name(enum fe_code_rate f);

#endif
