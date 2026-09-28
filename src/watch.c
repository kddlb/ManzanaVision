// SPDX-License-Identifier: GPL-2.0-only
/*
 * watch: tune a saved channel and write that one program as an MPEG-TS
 * (rewritten PAT + PMT + PCR + elementary streams) to stdout or a file,
 * for piping into ffplay, VLC, mpv, ffmpeg, ...
 */
#include "watch.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "channels.h"
#include "dib0700.h"
#include "psi.h"
#include "scan.h"
#include "stk8096gp.h"

#define LOCK_CHECK_MS 500
#define RELOCK_AFTER_MS 2000

struct watch_ctx {
	FILE *out;
	struct psi_parser *psi;
	u16 service_id;

	u8 allowed[8192 / 8];	/* PIDs of the program, besides the PAT */
	unsigned int pmt_generation;
	u16 pat_pmt_pid;	/* PMT PID the current synthetic PAT points at */
	u8 pat_version;
	u8 pat_cc;

	unsigned long packets;
	bool write_error;

	unsigned long last_lock_check_ms;
	unsigned long unlocked_since_ms;	/* 0 while locked */
	bool need_retune;
	int relocks;
};

static void allow(struct watch_ctx *w, u16 pid)
{
	w->allowed[pid / 8] |= 1 << (pid % 8);
}

static bool allowed(const struct watch_ctx *w, u16 pid)
{
	return w->allowed[pid / 8] & (1 << (pid % 8));
}

static uint32_t crc32_mpeg(const u8 *data, int len)
{
	uint32_t crc = 0xffffffff;

	while (len--) {
		crc ^= (uint32_t)*data++ << 24;
		for (int i = 0; i < 8; i++)
			crc = (crc & 0x80000000) ? (crc << 1) ^ 0x04c11db7 : crc << 1;
	}
	return crc;
}

static void emit(struct watch_ctx *w, const u8 *pkt)
{
	if (w->write_error)
		return;
	if (fwrite(pkt, 1, TS_PACKET_SIZE, w->out) != TS_PACKET_SIZE)
		w->write_error = true;
	else
		w->packets++;
}

/* A PAT listing only our program, so players open it without being told */
static void emit_pat(struct watch_ctx *w, u16 tsid, u16 pmt_pid)
{
	u8 pkt[TS_PACKET_SIZE];
	u8 *sec = &pkt[5];
	uint32_t crc;

	if (pmt_pid != w->pat_pmt_pid) {
		w->pat_pmt_pid = pmt_pid;
		w->pat_version = (w->pat_version + 1) & 0x1f;
	}
	memset(pkt, 0xff, sizeof(pkt));
	pkt[0] = 0x47;
	pkt[1] = 0x40;			/* payload_unit_start, PID 0 */
	pkt[2] = 0x00;
	pkt[3] = 0x10 | w->pat_cc;	/* payload only */
	w->pat_cc = (w->pat_cc + 1) & 0x0f;
	pkt[4] = 0x00;			/* pointer_field */

	sec[0] = 0x00;			/* table_id: PAT */
	sec[1] = 0xb0;			/* syntax indicator, section_length 13 */
	sec[2] = 13;
	sec[3] = tsid >> 8;
	sec[4] = tsid & 0xff;
	sec[5] = 0xc1 | (w->pat_version << 1);	/* current_next */
	sec[6] = 0;			/* section_number */
	sec[7] = 0;			/* last_section_number */
	sec[8] = w->service_id >> 8;
	sec[9] = w->service_id & 0xff;
	sec[10] = 0xe0 | (pmt_pid >> 8);
	sec[11] = pmt_pid & 0xff;
	crc = crc32_mpeg(sec, 12);
	sec[12] = crc >> 24;
	sec[13] = crc >> 16;
	sec[14] = crc >> 8;
	sec[15] = crc;
	emit(w, pkt);
}

static void rebuild_pid_set(struct watch_ctx *w, const struct psi_program *prog)
{
	memset(w->allowed, 0, sizeof(w->allowed));
	allow(w, prog->pmt_pid);
	if (prog->pcr_pid != 0x1fff)
		allow(w, prog->pcr_pid);
	for (int i = 0; i < prog->nes; i++)
		allow(w, prog->es[i].pid);
	w->pmt_generation = prog->generation;
}

static int watch_cb(const u8 *pkt, void *opaque)
{
	struct watch_ctx *w = opaque;
	const struct psi_mux *m;
	const struct psi_program *prog;
	u16 pid;

	if (!pkt) {
		/* idle tick: watch the lock, and bail out to re-tune if it's gone */
		unsigned long now = jiffies;

		if (now - w->last_lock_check_ms >= LOCK_CHECK_MS) {
			w->last_lock_check_ms = now;
			if (stk_read_status() & FE_HAS_LOCK) {
				w->unlocked_since_ms = 0;
			} else if (!w->unlocked_since_ms) {
				w->unlocked_since_ms = now;
			} else if (now - w->unlocked_since_ms >= RELOCK_AFTER_MS) {
				w->need_retune = true;
				return 1;
			}
		}
		return scan_interrupted() || w->write_error;
	}

	psi_feed(w->psi, pkt);
	m = psi_result(w->psi);
	prog = &m->program;
	pid = ((pkt[1] & 0x1f) << 8) | pkt[2];

	if (prog->have_pmt && prog->generation != w->pmt_generation) {
		rebuild_pid_set(w, prog);
		fprintf(stderr, "program %d: PMT 0x%04x, %d stream%s\n", w->service_id, prog->pmt_pid,
			prog->nes, prog->nes == 1 ? "" : "s");
	}

	if (pid == 0) {
		/* replace each PAT with ours, once the real one told us the PMT PID */
		if ((pkt[1] & 0x40) && prog->pmt_pid)
			emit_pat(w, m->transport_stream_id, prog->pmt_pid);
	} else if ((prog->pmt_pid && pid == prog->pmt_pid) || allowed(w, pid)) {
		emit(w, pkt);
	}
	return scan_interrupted() || w->write_error;
}

static void list_hint(const struct channel_list *l)
{
	fprintf(stderr, "saved channels:");
	for (int i = 0; i < l->n; i++)
		fprintf(stderr, " %d.%d", l->ch[i].major, l->ch[i].minor);
	fprintf(stderr, "\n");
}

int watch_run(struct dib0700 *d, const char *query, const char *output_path)
{
	struct channel_list list;
	const struct channel *ch;
	struct watch_ctx w = { 0 };
	const char *path = channels_path();
	enum fe_status status;
	unsigned long start;
	int ret = 1, n;

	if (!output_path && isatty(STDOUT_FILENO)) {
		fprintf(stderr, "refusing to write a TS to the terminal; pipe it into a player, e.g.\n"
			"  manzanavision watch %s | ffplay -\n"
			"or use --output FILE\n", query);
		return 2;
	}
	if (channels_load(&list, path) < 0 || list.n == 0) {
		fprintf(stderr, "no saved channels in %s; run `manzanavision scan` first\n", path);
		channels_free(&list);
		return 1;
	}
	ch = channels_find(&list, query);
	if (!ch) {
		fprintf(stderr, "no channel matches \"%s\"\n", query);
		list_hint(&list);
		channels_free(&list);
		return 1;
	}

	w.out = output_path ? fopen(output_path, "wb") : stdout;
	if (!w.out) {
		perror(output_path);
		channels_free(&list);
		return 1;
	}
	setvbuf(w.out, NULL, _IOFBF, 64 * 1024);
	signal(SIGPIPE, SIG_IGN); /* a closed player shows up as a write error */

	fprintf(stderr, "tuning %d.%d %s (RF %d)...\n", ch->major, ch->minor, ch->name, ch->rf);
	status = stk_tune(isdbt_channel_freq(ch->rf));
	if (!(status & FE_HAS_LOCK)) {
		fprintf(stderr, "RF %d did not lock; check reception with `manzanavision signal %d`\n",
			ch->rf, ch->rf);
		goto out;
	}

	w.psi = psi_new();
	w.service_id = ch->service_id;
	psi_watch_program(w.psi, ch->service_id);

	fprintf(stderr, "locked, streaming (Ctrl-C to stop)\n");
	start = jiffies;
	for (;;) {
		unsigned long lost_at;

		dib0700_streaming_ctrl(d, 1);
		n = dib0700_read_ts(d, 0, watch_cb, &w);
		dib0700_streaming_ctrl(d, 0);
		fflush(w.out);
		if (n < 0 || !w.need_retune || scan_interrupted() || w.write_error)
			break;

		/* the demod won't re-acquire on its own; keep re-tuning until it does */
		w.need_retune = false;
		lost_at = jiffies;
		fprintf(stderr, "signal lost, re-tuning RF %d...\n", ch->rf);
		while (!scan_interrupted() && !(stk_tune(isdbt_channel_freq(ch->rf)) & FE_HAS_LOCK))
			;
		if (scan_interrupted())
			break;
		w.relocks++;
		w.unlocked_since_ms = 0;
		fprintf(stderr, "re-locked after %.0f s, streaming again\n", (jiffies - lost_at) / 1000.0);
	}

	if (n < 0) {
		fprintf(stderr, "TS read failed (%d)\n", n);
	} else {
		double secs = (jiffies - start) / 1000.0;

		fprintf(stderr, "%s after %.0f s, %.1f MB written", w.write_error ? "output closed" : "stopped",
			secs, w.packets * 188 / 1e6);
		if (w.relocks)
			fprintf(stderr, ", %d re-lock%s", w.relocks, w.relocks == 1 ? "" : "s");
		fprintf(stderr, "\n");
		if (!w.psi || !psi_result(w.psi)->program.have_pmt)
			fprintf(stderr, "never saw the program's PMT: the full-seg layer may not be decoding\n");
		ret = 0;
	}
	psi_free(w.psi);
out:
	if (output_path)
		fclose(w.out);
	channels_free(&list);
	return ret;
}

int channels_run(void)
{
	struct channel_list list;
	const char *path = channels_path();

	if (channels_load(&list, path) < 0) {
		fprintf(stderr, "cannot read %s\n", path);
		return 1;
	}
	if (list.n == 0) {
		fprintf(stderr, "no saved channels in %s; run `manzanavision scan` first\n", path);
		channels_free(&list);
		return 1;
	}
	for (int i = 0; i < list.n; i++) {
		const struct channel *c = &list.ch[i];

		printf("%3d.%-3d %-24s %-5s RF %2d  sid 0x%04x\n", c->major, c->minor, c->name, c->kind,
		       c->rf, c->service_id);
	}
	fprintf(stderr, "%d channel%s in %s\n", list.n, list.n == 1 ? "" : "s", path);
	channels_free(&list);
	return 0;
}
