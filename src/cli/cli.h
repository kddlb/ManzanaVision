/* SPDX-License-Identifier: GPL-2.0-only */
/* The manzanavision command-line tool, built on the public core API */
#ifndef CLI_H
#define CLI_H

#include <stdbool.h>

#include "manzana.h"

struct scan_opts {
	int from, to;			/* RF channel range, inclusive */
	bool json;
	unsigned int psi_timeout_ms;	/* how long to wait for PAT+SDT+NIT */
	bool save;			/* merge results into the channel list */
};

int scan_run(mzv_device *dev, const struct scan_opts *o);

/*
 * Tunes one channel and reports it like scan does. With dump_path, also
 * writes the whole mux's TS for `seconds` seconds.
 */
int tune_run(mzv_device *dev, int rf, const char *dump_path, unsigned int seconds);

/* Streams one saved channel as a single-program TS to stdout or a file */
int watch_run(mzv_device *dev, const char *query, const char *output_path);

/* Filters one service out of a recording (service id or virtual number) */
int remux_run(const char *in_path, const char *what, const char *out_path);

/* Prints the saved channel list; needs no hardware */
int channels_run(void);

#endif
