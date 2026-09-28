// SPDX-License-Identifier: GPL-2.0-only
/*
 * Channel list stored as tab-separated text, one service per line:
 *   virtual  name  kind  rf  service_id  pmt_pid
 * Easy to read, diff and hand-edit; lines starting with '#' are comments.
 */
#include "core.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#define DEFAULT_SUBPATH "Library/Application Support/ManzanaVision/channels.tsv"

const char *mzv_channels_default_path(void)
{
	static char path[PATH_MAX];
	const char *env = getenv("MANZANA_CHANNELS");
	const char *home = getenv("HOME");

	if (env && *env)
		return env;
	snprintf(path, sizeof(path), "%s/%s", home ? home : ".", DEFAULT_SUBPATH);
	return path;
}

static void push(struct mzv_channel_list *l, const struct mzv_channel *c)
{
	if (l->count == l->capacity) {
		l->capacity = l->capacity ? l->capacity * 2 : 32;
		l->items = realloc(l->items, l->capacity * sizeof(*l->items));
	}
	l->items[l->count++] = *c;
}

void mzv_channels_free(struct mzv_channel_list *l)
{
	free(l->items);
	memset(l, 0, sizeof(*l));
}

/* Splits line in place on tabs; returns the number of fields */
static int split_tabs(char *line, char **field, int max)
{
	int n = 0;

	while (n < max) {
		field[n++] = line;
		line = strchr(line, '\t');
		if (!line)
			break;
		*line++ = '\0';
	}
	return n;
}

int mzv_channels_load(const char *path, struct mzv_channel_list *l)
{
	FILE *f = fopen(path, "r");
	char line[512];

	memset(l, 0, sizeof(*l));
	if (!f)
		return errno == ENOENT ? MZV_OK : MZV_ERR_IO;

	while (fgets(line, sizeof(line), f)) {
		char *field[6];
		struct mzv_channel c = { 0 };

		line[strcspn(line, "\r\n")] = '\0';
		if (line[0] == '#' || line[0] == '\0')
			continue;
		if (split_tabs(line, field, 6) != 6)
			continue;
		if (sscanf(field[0], "%d.%d", &c.major, &c.minor) != 2)
			continue;
		snprintf(c.name, sizeof(c.name), "%s", field[1]);
		snprintf(c.kind, sizeof(c.kind), "%s", field[2]);
		c.rf = atoi(field[3]);
		c.service_id = strtoul(field[4], NULL, 0);
		c.pmt_pid = strtoul(field[5], NULL, 0);
		push(l, &c);
	}
	fclose(f);
	return MZV_OK;
}

static int by_virtual(const void *a, const void *b)
{
	const struct mzv_channel *x = a, *y = b;

	if (x->major != y->major)
		return x->major - y->major;
	if (x->minor != y->minor)
		return x->minor - y->minor;
	return x->rf - y->rf;
}

static int mkdir_parents(const char *path)
{
	char dir[PATH_MAX], *p;

	snprintf(dir, sizeof(dir), "%s", path);
	p = strrchr(dir, '/');
	if (!p)
		return 0;
	*p = '\0';
	for (p = dir + 1; *p; p++) {
		if (*p != '/')
			continue;
		*p = '\0';
		if (mkdir(dir, 0755) < 0 && errno != EEXIST)
			return -1;
		*p = '/';
	}
	return mkdir(dir, 0755) < 0 && errno != EEXIST ? -1 : 0;
}

/* Names come from the broadcast; keep them from breaking the format */
static void put_field(FILE *f, const char *s)
{
	for (; *s; s++)
		fputc(*s == '\t' || *s == '\n' || *s == '\r' ? ' ' : *s, f);
}

int mzv_channels_save(const char *path, struct mzv_channel_list *l)
{
	char tmp[PATH_MAX];
	FILE *f;

	if (mkdir_parents(path) < 0)
		return MZV_ERR_IO;
	snprintf(tmp, sizeof(tmp), "%s.tmp", path);
	f = fopen(tmp, "w");
	if (!f)
		return MZV_ERR_IO;

	qsort(l->items, l->count, sizeof(*l->items), by_virtual);
	fprintf(f, "# ManzanaVision channel list (written by `manzanavision scan`)\n");
	fprintf(f, "# virtual\tname\tkind\trf\tservice_id\tpmt_pid\n");
	for (int i = 0; i < l->count; i++) {
		const struct mzv_channel *c = &l->items[i];

		fprintf(f, "%d.%d\t", c->major, c->minor);
		put_field(f, c->name);
		fprintf(f, "\t%s\t%d\t0x%04x\t0x%04x\n", c->kind, c->rf, c->service_id, c->pmt_pid);
	}
	if (fclose(f) != 0 || rename(tmp, path) < 0) {
		unlink(tmp);
		return MZV_ERR_IO;
	}
	return MZV_OK;
}

static void replace_rf(struct mzv_channel_list *l, int rf, const struct mzv_channel *ch, int n)
{
	int w = 0;

	for (int i = 0; i < l->count; i++)
		if (l->items[i].rf != rf)
			l->items[w++] = l->items[i];
	l->count = w;
	for (int i = 0; i < n; i++)
		push(l, &ch[i]);
}

static bool list_has_rf(const struct mzv_channel_list *l, int rf)
{
	for (int i = 0; i < l->count; i++)
		if (l->items[i].rf == rf)
			return true;
	return false;
}

bool mzv_channels_merge_mux(struct mzv_channel_list *l, const struct mzv_mux *m)
{
	struct mzv_channel ch[MZV_MAX_SERVICES];
	int n = 0;

	if (!m->signal.has_lock || !m->have_psi)
		return false;
	/* without the PAT, one-seg numbering and PMTs are guesses: keep what we had */
	if (!m->have_pat && list_has_rf(l, m->rf))
		return false;

	for (int i = 0; i < m->nservices; i++) {
		const struct mzv_service *s = &m->services[i];
		struct mzv_channel *c = &ch[n];

		if (!s->listed)
			continue;
		memset(c, 0, sizeof(*c));
		c->major = s->major;
		c->minor = s->minor;
		snprintf(c->name, sizeof(c->name), "%s", s->name[0] ? s->name : "(unnamed)");
		snprintf(c->kind, sizeof(c->kind), "%s", s->kind);
		c->rf = m->rf;
		c->service_id = s->service_id;
		c->pmt_pid = s->pmt_pid;
		n++;
	}
	if (!n)
		return false;
	replace_rf(l, m->rf, ch, n);
	return true;
}

const struct mzv_channel *mzv_channels_find(const struct mzv_channel_list *l, const char *query)
{
	int major, minor;
	char extra;

	if (sscanf(query, "%d.%d%c", &major, &minor, &extra) == 2) {
		for (int i = 0; i < l->count; i++)
			if (l->items[i].major == major && l->items[i].minor == minor)
				return &l->items[i];
		return NULL;
	}
	if (sscanf(query, "%d%c", &major, &extra) == 1) {
		const struct mzv_channel *best = NULL;

		for (int i = 0; i < l->count; i++)
			if (l->items[i].major == major && (!best || l->items[i].minor < best->minor))
				best = &l->items[i];
		return best;
	}
	for (int i = 0; i < l->count; i++)
		if (!strcasecmp(l->items[i].name, query))
			return &l->items[i];
	return NULL;
}
