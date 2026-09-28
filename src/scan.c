// SPDX-License-Identifier: GPL-2.0-only
/* Channel scan: tune each UHF channel, read TMCC, collect PSI, report. */
#include "scan.h"

#include <signal.h>
#include <stdio.h>
#include <string.h>

#include "dib0700.h"
#include "psi.h"
#include "stk8096gp.h"

static volatile sig_atomic_t interrupted;

void scan_interrupt(void)
{
	interrupted = 1;
}

uint32_t isdbt_channel_freq(int rf)
{
	/* ABNT NBR 15601: 473 MHz + 6 MHz steps, plus a 1/7 MHz offset */
	return 473000000u + 6000000u * (uint32_t)(rf - 14) + 142857u;
}

struct mux_result {
	int rf;
	uint32_t freq;
	enum fe_status status;
	u16 strength, snr;
	u8 layer_lock;
	bool have_tmcc;
	struct dtv_frontend_properties tmcc;
	bool have_psi;
	struct psi_mux psi;
	int ts_packets;
};

static const char *mod_name(enum fe_modulation m)
{
	switch (m) {
	case QPSK: return "QPSK";
	case DQPSK: return "DQPSK";
	case QAM_16: return "16QAM";
	case QAM_64: return "64QAM";
	default: return "?";
	}
}

static const char *fec_name(enum fe_code_rate f)
{
	switch (f) {
	case FEC_1_2: return "1/2";
	case FEC_2_3: return "2/3";
	case FEC_3_4: return "3/4";
	case FEC_5_6: return "5/6";
	case FEC_7_8: return "7/8";
	default: return "?";
	}
}

static const char *gi_name(enum fe_guard_interval g)
{
	switch (g) {
	case GUARD_INTERVAL_1_4: return "1/4";
	case GUARD_INTERVAL_1_8: return "1/8";
	case GUARD_INTERVAL_1_16: return "1/16";
	case GUARD_INTERVAL_1_32: return "1/32";
	default: return "?";
	}
}

/* ISDB-T mode 1/2/3 correspond to 2k/4k/8k FFT */
static int isdbt_mode(enum fe_transmit_mode t)
{
	switch (t) {
	case TRANSMISSION_MODE_2K: return 1;
	case TRANSMISSION_MODE_4K: return 2;
	case TRANSMISSION_MODE_8K: return 3;
	default: return 0;
	}
}

static const char *service_kind(const struct psi_service *s)
{
	if (psi_is_oneseg(s))
		return "1seg";
	switch (s->service_type) {
	case 0x01: return "TV";
	case 0x02: return "radio";
	case 0xc0: return "data";
	default: return "other";
	}
}

/* PAT lives in the full-seg layer; without it, fall back to the SDT list */
static bool service_listed(const struct psi_mux *m, const struct psi_service *s)
{
	return m->have_pat ? s->in_pat : s->in_sdt;
}

static int psi_cb(const u8 *pkt, void *opaque)
{
	struct psi_parser *p = opaque;

	psi_feed(p, pkt);
	return psi_complete(p) || interrupted;
}

static void tune_and_collect(struct dib0700 *d, int rf, unsigned int psi_timeout_ms, struct mux_result *r)
{
	memset(r, 0, sizeof(*r));
	r->rf = rf;
	r->freq = isdbt_channel_freq(rf);
	r->status = stk_tune(r->freq);
	stk_read_signal(&r->strength, &r->snr);
	if (!(r->status & FE_HAS_LOCK))
		return;

	r->have_tmcc = stk_get_tmcc(&r->tmcc) == 0;
	r->layer_lock = stk_layer_lock();

	struct psi_parser *p = psi_new();

	dib0700_streaming_ctrl(d, 1);
	r->ts_packets = dib0700_read_ts(d, psi_timeout_ms, psi_cb, p);
	dib0700_streaming_ctrl(d, 0);
	r->psi = *psi_result(p);
	r->have_psi = r->psi.have_pat || r->psi.have_sdt || r->psi.have_nit;
	psi_free(p);
}

static void print_text(const struct mux_result *r)
{
	if (!(r->status & FE_HAS_LOCK)) {
		printf("RF %2d  %7.3f MHz  --  %s  (status 0x%02x, strength %d%%)\n", r->rf, r->freq / 1e6,
		       (r->status & FE_HAS_SIGNAL) ? "signal, no lock" : "no signal", r->status,
		       r->strength * 100 / 65535);
		fflush(stdout);
		return;
	}

	printf("RF %2d  %7.3f MHz  LOCK  strength %3d%%  SNR %.1f dB\n", r->rf, r->freq / 1e6,
	       r->strength * 100 / 65535, r->snr / 10.0);
	if (r->have_tmcc) {
		const struct dtv_frontend_properties *c = &r->tmcc;

		printf("       mode %d  GI %s ", isdbt_mode(c->transmission_mode), gi_name(c->guard_interval));
		for (int l = 0; l < 3; l++) {
			if (!c->layer[l].segment_count)
				continue;
			printf(" | %c: %2d seg %s %s I=%d %s", 'A' + l, c->layer[l].segment_count,
			       mod_name(c->layer[l].modulation), fec_name(c->layer[l].fec),
			       c->layer[l].interleaving, (r->layer_lock >> l) & 1 ? "ok" : "NO LOCK");
		}
		printf("\n");
	}
	if (!r->have_psi) {
		printf("       no PSI received (%d TS packets)\n", r->ts_packets);
		fflush(stdout);
		return;
	}

	const struct psi_mux *m = &r->psi;

	if (m->have_pat)
		printf("       TSID 0x%04x ", m->transport_stream_id);
	else
		printf("       TSID  ?     ");
	printf(" ONID 0x%04x  network \"%s\"  ts \"%s\"%s%s%s\n",
	       m->original_network_id, m->network_name, m->ts_name,
	       m->have_pat ? "" : "  [no PAT: full-seg layer not decoding]",
	       m->have_sdt ? "" : "  [no SDT]", m->have_nit ? "" : "  [no NIT]");
	for (int i = 0; i < m->nservices; i++) {
		const struct psi_service *s = &m->services[i];
		int major, minor;

		if (!service_listed(m, s))
			continue;
		psi_virtual_channel(m, s, &major, &minor);
		printf("       %2d.%-3d %-24s %-5s sid 0x%04x", major, minor,
		       s->name[0] ? s->name : "(unnamed)", service_kind(s), s->service_id);
		if (s->in_pat)
			printf("  pmt 0x%04x", s->pmt_pid);
		printf("\n");
	}
	fflush(stdout);
}

static void json_str(const char *s)
{
	putchar('"');
	for (; *s; s++) {
		if (*s == '"' || *s == '\\')
			printf("\\%c", *s);
		else if ((unsigned char)*s < 0x20)
			printf("\\u%04x", *s);
		else
			putchar(*s);
	}
	putchar('"');
}

static void print_json(const struct mux_result *r, bool first)
{
	printf("%s\n  {\"rf\": %d, \"frequency\": %u, \"lock\": %s, \"signal\": %s, \"strength\": %u, \"snr_db\": %.1f",
	       first ? "" : ",", r->rf, r->freq, (r->status & FE_HAS_LOCK) ? "true" : "false",
	       (r->status & FE_HAS_SIGNAL) ? "true" : "false", r->strength, r->snr / 10.0);
	if (r->have_tmcc) {
		const struct dtv_frontend_properties *c = &r->tmcc;
		bool lfirst = true;

		printf(", \"mode\": %d, \"guard_interval\": \"%s\", \"layers\": [",
		       isdbt_mode(c->transmission_mode), gi_name(c->guard_interval));
		for (int l = 0; l < 3; l++) {
			if (!c->layer[l].segment_count)
				continue;
			printf("%s{\"layer\": \"%c\", \"segments\": %d, \"modulation\": \"%s\", \"fec\": \"%s\", \"interleaving\": %d, \"lock\": %s}",
			       lfirst ? "" : ", ", 'A' + l, c->layer[l].segment_count,
			       mod_name(c->layer[l].modulation), fec_name(c->layer[l].fec), c->layer[l].interleaving,
			       (r->layer_lock >> l) & 1 ? "true" : "false");
			lfirst = false;
		}
		printf("]");
	}
	if (r->have_psi) {
		const struct psi_mux *m = &r->psi;
		bool sfirst = true;

		printf(", \"tsid\": %u, \"onid\": %u, \"network\": ", m->transport_stream_id, m->original_network_id);
		json_str(m->network_name);
		printf(", \"ts_name\": ");
		json_str(m->ts_name);
		printf(", \"services\": [");
		for (int i = 0; i < m->nservices; i++) {
			const struct psi_service *s = &m->services[i];
			int major, minor;

			if (!s->in_pat)
				continue;
			psi_virtual_channel(m, s, &major, &minor);
			printf("%s\n    {\"virtual\": \"%d.%d\", \"name\": ", sfirst ? "" : ",", major, minor);
			json_str(s->name);
			printf(", \"kind\": \"%s\", \"service_id\": %u, \"pmt_pid\": %u}",
			       service_kind(s), s->service_id, s->pmt_pid);
			sfirst = false;
		}
		printf("]");
	}
	printf("}");
	fflush(stdout);
}

int scan_run(struct dib0700 *d, const struct scan_opts *o)
{
	struct mux_result r;
	int locked = 0;
	bool first = true;

	if (o->json)
		printf("[");
	for (int rf = o->from; rf <= o->to && !interrupted; rf++) {
		if (!o->json) {
			fprintf(stderr, "\rscanning RF %d...", rf);
			fflush(stderr);
		}
		tune_and_collect(d, rf, o->psi_timeout_ms, &r);
		if (!o->json)
			fprintf(stderr, "\r                  \r");
		if (r.status & FE_HAS_LOCK)
			locked++;
		if (o->json) {
			print_json(&r, first);
			first = false;
		} else {
			print_text(&r);
		}
	}
	if (o->json)
		printf("\n]\n");
	else
		printf("\n%d mux%s locked\n", locked, locked == 1 ? "" : "es");
	return interrupted ? 130 : 0;
}

struct dump_ctx {
	FILE *f;
	struct psi_parser *p;
};

static int dump_cb(const u8 *pkt, void *opaque)
{
	struct dump_ctx *dc = opaque;

	fwrite(pkt, 1, TS_PACKET_SIZE, dc->f);
	psi_feed(dc->p, pkt);
	return interrupted;
}

int tune_run(struct dib0700 *d, int rf, const char *dump_path, unsigned int seconds)
{
	struct mux_result r;

	tune_and_collect(d, rf, 5000, &r);
	print_text(&r);
	if (!dump_path)
		return (r.status & FE_HAS_LOCK) ? 0 : 1;
	if (!(r.status & FE_HAS_LOCK)) {
		fprintf(stderr, "not locked, nothing to dump\n");
		return 1;
	}

	struct dump_ctx dc = { .f = fopen(dump_path, "wb"), .p = psi_new() };
	int n;

	if (!dc.f) {
		perror(dump_path);
		psi_free(dc.p);
		return 1;
	}
	dib0700_streaming_ctrl(d, 1);
	n = dib0700_read_ts(d, seconds * 1000, dump_cb, &dc);
	dib0700_streaming_ctrl(d, 0);
	fclose(dc.f);
	psi_free(dc.p);
	if (n < 0) {
		fprintf(stderr, "TS read failed (%d)\n", n);
		return 1;
	}
	fprintf(stderr, "wrote %d packets (%.1f MB, %.2f Mbit/s) to %s\n", n, n * 188 / 1e6,
		n * 188 * 8 / 1e6 / seconds, dump_path);
	return 0;
}
