// SPDX-License-Identifier: GPL-2.0-only
/*
 * watch: stream one saved channel as a single-program MPEG-TS to stdout or
 * a file, for piping into ffplay, VLC, mpv, ffmpeg, ...; and `channels`.
 */
#include <signal.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

#include "cli.h"

struct watch_ctx {
	FILE *out;
	const struct mzv_channel *ch;
	unsigned long packets;
	bool write_error;
	bool have_pmt;
	int relocks;
	double lost_at;
};

static double now_s(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int on_packets(const uint8_t *pkts, size_t n, uint32_t epoch, void *opaque)
{
	struct watch_ctx *w = opaque;

	(void)epoch;
	if (fwrite(pkts, MZV_TS_PACKET_SIZE, n, w->out) != n) {
		w->write_error = true;
		return 1;
	}
	w->packets += n;
	return 0;
}

static void on_program(const struct mzv_program *p, void *opaque)
{
	struct watch_ctx *w = opaque;

	w->have_pmt = true;
	fprintf(stderr, "program %d: PMT 0x%04x, %d stream%s\n", p->service_id, p->pmt_pid, p->nes,
		p->nes == 1 ? "" : "s");
}

static void on_event(enum mzv_event ev, uint32_t epoch, void *opaque)
{
	struct watch_ctx *w = opaque;

	(void)epoch;
	switch (ev) {
	case MZV_EVENT_LOCKED:
		fprintf(stderr, "locked, streaming (Ctrl-C to stop)\n");
		break;
	case MZV_EVENT_LOCK_LOST:
		w->lost_at = now_s();
		fprintf(stderr, "signal lost, re-tuning RF %d...\n", w->ch->rf);
		break;
	case MZV_EVENT_RELOCKED:
		w->relocks++;
		fprintf(stderr, "re-locked after %.0f s, streaming again\n", now_s() - w->lost_at);
		break;
	default:
		break;
	}
}

static void list_hint(const struct mzv_channel_list *l)
{
	fprintf(stderr, "saved channels:");
	for (int i = 0; i < l->count; i++)
		fprintf(stderr, " %d.%d", l->items[i].major, l->items[i].minor);
	fprintf(stderr, "\n");
}

int watch_run(mzv_device *dev, const char *query, const char *output_path)
{
	struct mzv_channel_list list = { 0 };
	const struct mzv_channel *ch;
	struct watch_ctx w = { 0 };
	const char *path = mzv_channels_default_path();
	double start;
	int ret;

	if (!output_path && isatty(STDOUT_FILENO)) {
		fprintf(stderr, "refusing to write a TS to the terminal; pipe it into a player, e.g.\n"
			"  manzanavision watch %s | ffplay -\n"
			"or use --output FILE\n", query);
		return 2;
	}
	if (mzv_channels_load(path, &list) < 0 || list.count == 0) {
		fprintf(stderr, "no saved channels in %s; run `manzanavision scan` first\n", path);
		mzv_channels_free(&list);
		return 1;
	}
	ch = mzv_channels_find(&list, query);
	if (!ch) {
		fprintf(stderr, "no channel matches \"%s\"\n", query);
		list_hint(&list);
		mzv_channels_free(&list);
		return 1;
	}

	w.ch = ch;
	w.out = output_path ? fopen(output_path, "wb") : stdout;
	if (!w.out) {
		perror(output_path);
		mzv_channels_free(&list);
		return 1;
	}
	setvbuf(w.out, NULL, _IOFBF, 64 * 1024);
	signal(SIGPIPE, SIG_IGN); /* a closed player shows up as a write error */

	struct mzv_stream_options so = {
		.rf = ch->rf,
		.service_id = ch->service_id,
		.rewrite_pat = true,
	};
	struct mzv_stream_callbacks cb = {
		.packets = on_packets,
		.program = on_program,
		.event = on_event,
		.ctx = &w,
	};

	fprintf(stderr, "tuning %d.%d %s (RF %d)...\n", ch->major, ch->minor, ch->name, ch->rf);
	start = now_s();
	ret = mzv_stream(dev, &so, &cb);
	fflush(w.out);

	if (ret == MZV_ERR_NO_LOCK) {
		fprintf(stderr, "RF %d did not lock; check reception with `manzanavision signal %d`\n",
			ch->rf, ch->rf);
	} else if (ret < 0) {
		fprintf(stderr, "streaming failed: %s\n", mzv_strerror(ret));
	} else {
		fprintf(stderr, "%s after %.0f s, %.1f MB written", w.write_error ? "output closed" : "stopped",
			now_s() - start, w.packets * 188 / 1e6);
		if (w.relocks)
			fprintf(stderr, ", %d re-lock%s", w.relocks, w.relocks == 1 ? "" : "s");
		fprintf(stderr, "\n");
		if (!w.have_pmt)
			fprintf(stderr, "never saw the program's PMT: the full-seg layer may not be decoding\n");
	}
	if (output_path)
		fclose(w.out);
	mzv_channels_free(&list);
	return ret < 0 ? 1 : 0;
}

int channels_run(void)
{
	struct mzv_channel_list list = { 0 };
	const char *path = mzv_channels_default_path();

	if (mzv_channels_load(path, &list) < 0) {
		fprintf(stderr, "cannot read %s\n", path);
		return 1;
	}
	if (list.count == 0) {
		fprintf(stderr, "no saved channels in %s; run `manzanavision scan` first\n", path);
		mzv_channels_free(&list);
		return 1;
	}
	for (int i = 0; i < list.count; i++) {
		const struct mzv_channel *c = &list.items[i];

		printf("%3d.%-3d %-24s %-5s RF %2d  sid 0x%04x\n", c->major, c->minor, c->name, c->kind,
		       c->rf, c->service_id);
	}
	fprintf(stderr, "%d channel%s in %s\n", list.count, list.count == 1 ? "" : "s", path);
	mzv_channels_free(&list);
	return 0;
}
