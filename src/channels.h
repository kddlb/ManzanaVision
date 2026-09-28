/* SPDX-License-Identifier: GPL-2.0-only */
/* Saved channel list: what scan found, so watch can tune by virtual number */
#ifndef CHANNELS_H
#define CHANNELS_H

#include <stdint.h>

struct channel {
	int major, minor;	/* virtual channel, e.g. 9.1 */
	char name[64];
	char kind[8];		/* "TV", "1seg", "radio", "data", "other" */
	int rf;
	uint16_t service_id;
	uint16_t pmt_pid;	/* as last seen; 0 if unknown. watch re-reads the PAT anyway */
};

struct channel_list {
	int n, cap;
	struct channel *ch;
};

/* $MANZANA_CHANNELS, or ~/Library/Application Support/ManzanaVision/channels.tsv */
const char *channels_path(void);

/* A missing file loads as an empty list. Returns 0, or -1 on a read error. */
int channels_load(struct channel_list *l, const char *path);
/* Writes atomically, creating the parent directory. Returns 0 or -1. */
int channels_save(const struct channel_list *l, const char *path);
void channels_free(struct channel_list *l);

/* Replaces every channel on RF channel rf with the n given ones */
void channels_replace_rf(struct channel_list *l, int rf, const struct channel *ch, int n);

/*
 * Finds a channel by virtual number ("9.1", or "9" for the first 9.x) or by
 * name, case-insensitively. Returns NULL if nothing matches.
 */
const struct channel *channels_find(const struct channel_list *l, const char *query);

#endif
