/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef WATCH_H
#define WATCH_H

struct dib0700;

/*
 * Tunes the saved channel matching query ("9.1", "9", or a name) and writes
 * that single program as MPEG-TS to output_path, or stdout when NULL, until
 * interrupted or the reader goes away.
 */
int watch_run(struct dib0700 *d, const char *query, const char *output_path);

/* Prints the saved channel list; needs no hardware */
int channels_run(void);

#endif
