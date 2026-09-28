// SPDX-License-Identifier: GPL-2.0-only
/*
 * Channel list stored as tab-separated text, one service per line:
 *   virtual  name  kind  rf  service_id  pmt_pid
 * Easy to read, diff and hand-edit; lines starting with '#' are comments.
 */
#include "channels.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#define DEFAULT_SUBPATH "Library/Application Support/ManzanaVision/channels.tsv"

const char *channels_path(void)
{
	static char path[PATH_MAX];
	const char *env = getenv("MANZANA_CHANNELS");
	const char *home = getenv("HOME");

	if (env && *env)
		return env;
	snprintf(path, sizeof(path), "%s/%s", home ? home : ".", DEFAULT_SUBPATH);
	return path;
}

static void push(struct channel_list *l, const struct channel *c)
{
	if (l->n == l->cap) {
		l->cap = l->cap ? l->cap * 2 : 32;
		l->ch = realloc(l->ch, l->cap * sizeof(*l->ch));
	}
	l->ch[l->n++] = *c;
}

void channels_free(struct channel_list *l)
{
	free(l->ch);
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

int channels_load(struct channel_list *l, const char *path)
{
	FILE *f = fopen(path, "r");
	char line[512];

	memset(l, 0, sizeof(*l));
	if (!f)
		return errno == ENOENT ? 0 : -1;

	while (fgets(line, sizeof(line), f)) {
		char *field[6];
		struct channel c = { 0 };

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
	return 0;
}

static int by_virtual(const void *a, const void *b)
{
	const struct channel *x = a, *y = b;

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

int channels_save(const struct channel_list *l, const char *path)
{
	char tmp[PATH_MAX];
	FILE *f;

	if (mkdir_parents(path) < 0)
		return -1;
	snprintf(tmp, sizeof(tmp), "%s.tmp", path);
	f = fopen(tmp, "w");
	if (!f)
		return -1;

	qsort(l->ch, l->n, sizeof(*l->ch), by_virtual);
	fprintf(f, "# ManzanaVision channel list (written by `manzanavision scan`)\n");
	fprintf(f, "# virtual\tname\tkind\trf\tservice_id\tpmt_pid\n");
	for (int i = 0; i < l->n; i++) {
		const struct channel *c = &l->ch[i];

		fprintf(f, "%d.%d\t", c->major, c->minor);
		put_field(f, c->name);
		fprintf(f, "\t%s\t%d\t0x%04x\t0x%04x\n", c->kind, c->rf, c->service_id, c->pmt_pid);
	}
	if (fclose(f) != 0 || rename(tmp, path) < 0) {
		unlink(tmp);
		return -1;
	}
	return 0;
}

void channels_replace_rf(struct channel_list *l, int rf, const struct channel *ch, int n)
{
	int w = 0;

	for (int i = 0; i < l->n; i++)
		if (l->ch[i].rf != rf)
			l->ch[w++] = l->ch[i];
	l->n = w;
	for (int i = 0; i < n; i++)
		push(l, &ch[i]);
}

const struct channel *channels_find(const struct channel_list *l, const char *query)
{
	int major, minor;
	char extra;

	if (sscanf(query, "%d.%d%c", &major, &minor, &extra) == 2) {
		for (int i = 0; i < l->n; i++)
			if (l->ch[i].major == major && l->ch[i].minor == minor)
				return &l->ch[i];
		return NULL;
	}
	if (sscanf(query, "%d%c", &major, &extra) == 1) {
		const struct channel *best = NULL;

		for (int i = 0; i < l->n; i++)
			if (l->ch[i].major == major && (!best || l->ch[i].minor < best->minor))
				best = &l->ch[i];
		return best;
	}
	for (int i = 0; i < l->n; i++)
		if (!strcasecmp(l->ch[i].name, query))
			return &l->ch[i];
	return NULL;
}
