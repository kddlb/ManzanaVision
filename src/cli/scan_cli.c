// SPDX-License-Identifier: GPL-2.0-only
/* scan and tune: run the core's per-channel scan and print the results */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "cli.h"

static void print_text(const struct mzv_mux *r)
{
	const struct mzv_signal *sig = &r->signal;

	if (!sig->has_lock) {
		printf("RF %2d  %7.3f MHz  --  %s  (status 0x%02x, strength %d%%)\n", r->rf, r->frequency / 1e6,
		       sig->has_signal ? "signal, no lock" : "no signal", sig->status, sig->strength_pct);
		fflush(stdout);
		return;
	}

	printf("RF %2d  %7.3f MHz  LOCK  strength %3d%%  SNR %.1f dB\n", r->rf, r->frequency / 1e6,
	       sig->strength_pct, sig->snr_tenths / 10.0);
	if (r->have_tmcc) {
		const struct mzv_tmcc *c = &r->tmcc;

		printf("       mode %d  GI %s ", c->mode, mzv_guard_interval_name(c->guard_interval));
		for (int l = 0; l < 3; l++) {
			if (!c->layer[l].segments)
				continue;
			printf(" | %c: %2d seg %s %s I=%d %s", 'A' + l, c->layer[l].segments,
			       mzv_modulation_name(c->layer[l].modulation), mzv_code_rate_name(c->layer[l].fec),
			       c->layer[l].interleaving, (sig->layer_lock >> l) & 1 ? "ok" : "NO LOCK");
		}
		printf("\n");
	}
	if (!r->have_psi) {
		printf("       no PSI received (%d TS packets)\n", r->ts_packets);
		fflush(stdout);
		return;
	}

	if (r->have_pat)
		printf("       TSID 0x%04x ", r->transport_stream_id);
	else
		printf("       TSID  ?     ");
	printf(" ONID 0x%04x  network \"%s\"  ts \"%s\"%s%s%s\n",
	       r->original_network_id, r->network_name, r->ts_name,
	       r->have_pat ? "" : "  [no PAT: full-seg layer not decoding]",
	       r->have_sdt ? "" : "  [no SDT]", r->have_nit ? "" : "  [no NIT]");
	for (int i = 0; i < r->nservices; i++) {
		const struct mzv_service *s = &r->services[i];

		if (!s->listed)
			continue;
		printf("       %2d.%-3d %-24s %-5s sid 0x%04x", s->major, s->minor,
		       s->name[0] ? s->name : "(unnamed)", s->kind, s->service_id);
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

static void print_json(const struct mzv_mux *r, bool first)
{
	const struct mzv_signal *sig = &r->signal;

	printf("%s\n  {\"rf\": %d, \"frequency\": %u, \"lock\": %s, \"signal\": %s, \"strength\": %u, \"snr_db\": %.1f",
	       first ? "" : ",", r->rf, r->frequency, sig->has_lock ? "true" : "false",
	       sig->has_signal ? "true" : "false", sig->strength, sig->snr_tenths / 10.0);
	if (r->have_tmcc) {
		const struct mzv_tmcc *c = &r->tmcc;
		bool lfirst = true;

		printf(", \"mode\": %d, \"guard_interval\": \"%s\", \"layers\": [",
		       c->mode, mzv_guard_interval_name(c->guard_interval));
		for (int l = 0; l < 3; l++) {
			if (!c->layer[l].segments)
				continue;
			printf("%s{\"layer\": \"%c\", \"segments\": %d, \"modulation\": \"%s\", \"fec\": \"%s\", \"interleaving\": %d, \"lock\": %s}",
			       lfirst ? "" : ", ", 'A' + l, c->layer[l].segments,
			       mzv_modulation_name(c->layer[l].modulation), mzv_code_rate_name(c->layer[l].fec),
			       c->layer[l].interleaving, (sig->layer_lock >> l) & 1 ? "true" : "false");
			lfirst = false;
		}
		printf("]");
	}
	if (r->have_psi) {
		bool sfirst = true;

		printf(", \"tsid\": %u, \"onid\": %u, \"network\": ", r->transport_stream_id, r->original_network_id);
		json_str(r->network_name);
		printf(", \"ts_name\": ");
		json_str(r->ts_name);
		printf(", \"services\": [");
		for (int i = 0; i < r->nservices; i++) {
			const struct mzv_service *s = &r->services[i];

			if (!s->in_pat)
				continue;
			printf("%s\n    {\"virtual\": \"%d.%d\", \"name\": ", sfirst ? "" : ",", s->major, s->minor);
			json_str(s->name);
			printf(", \"kind\": \"%s\", \"service_id\": %u, \"pmt_pid\": %u}",
			       s->kind, s->service_id, s->pmt_pid);
			sfirst = false;
		}
		printf("]");
	}
	printf("}");
	fflush(stdout);
}

int scan_run(mzv_device *dev, const struct scan_opts *o)
{
	struct mzv_mux r;
	struct mzv_channel_list list = { 0 };
	const char *path = mzv_channels_default_path();
	int locked = 0, updated = 0, ret = MZV_OK;
	bool first = true;

	if (o->save && mzv_channels_load(path, &list) < 0)
		fprintf(stderr, "warning: cannot read %s, starting a new list\n", path);

	if (o->json)
		printf("[");
	for (int rf = o->from; rf <= o->to && !mzv_is_cancelled(dev); rf++) {
		if (!o->json) {
			fprintf(stderr, "\rscanning RF %d...", rf);
			fflush(stderr);
		}
		ret = mzv_scan_rf(dev, rf, o->psi_timeout_ms, &r);
		if (!o->json)
			fprintf(stderr, "\r                  \r");
		if (ret == MZV_ERR_CANCELLED)
			break;
		if (ret < 0) {
			fprintf(stderr, "RF %d: %s\n", rf, mzv_strerror(ret));
			break;
		}
		if (r.signal.has_lock)
			locked++;
		if (o->save && mzv_channels_merge_mux(&list, &r))
			updated++;
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

	if (o->save && updated) {
		if (mzv_channels_save(path, &list) == MZV_OK)
			fprintf(stderr, "saved %d channel%s (%d mux%s updated) to %s\n", list.count,
				list.count == 1 ? "" : "s", updated, updated == 1 ? "" : "es", path);
		else
			fprintf(stderr, "cannot write %s: %s\n", path, strerror(errno));
	}
	mzv_channels_free(&list);
	if (mzv_is_cancelled(dev))
		return 130;
	return ret < 0 && ret != MZV_ERR_CANCELLED ? 1 : 0;
}

struct dump_ctx {
	FILE *f;
	unsigned long packets;
	bool write_error;
};

static int dump_packets(const uint8_t *pkts, size_t n, uint32_t epoch, void *opaque)
{
	struct dump_ctx *dc = opaque;

	(void)epoch;
	if (fwrite(pkts, MZV_TS_PACKET_SIZE, n, dc->f) != n) {
		dc->write_error = true;
		return 1;
	}
	dc->packets += n;
	return 0;
}

int tune_run(mzv_device *dev, int rf, const char *dump_path, unsigned int seconds)
{
	struct mzv_mux r;
	int ret = mzv_scan_rf(dev, rf, 5000, &r);

	if (ret < 0 && ret != MZV_ERR_CANCELLED) {
		fprintf(stderr, "RF %d: %s\n", rf, mzv_strerror(ret));
		return 1;
	}
	print_text(&r);
	if (!dump_path)
		return r.signal.has_lock ? 0 : 1;
	if (!r.signal.has_lock) {
		fprintf(stderr, "not locked, nothing to dump\n");
		return 1;
	}

	struct dump_ctx dc = { .f = fopen(dump_path, "wb") };
	struct mzv_stream_options so = {
		.rf = rf,
		.duration_ms = seconds * 1000,
		.skip_tune_if_locked = true,
	};
	struct mzv_stream_callbacks cb = { .packets = dump_packets, .ctx = &dc };

	struct timespec t0, t1;
	double secs;

	if (!dc.f) {
		perror(dump_path);
		return 1;
	}
	clock_gettime(CLOCK_MONOTONIC, &t0);
	ret = mzv_stream(dev, &so, &cb);
	clock_gettime(CLOCK_MONOTONIC, &t1);
	fclose(dc.f);
	secs = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
	if (ret < 0) {
		fprintf(stderr, "TS read failed: %s\n", mzv_strerror(ret));
		return 1;
	}
	fprintf(stderr, "wrote %lu packets (%.1f MB, %.2f Mbit/s) to %s\n", dc.packets, dc.packets * 188.0 / 1e6,
		secs > 0 ? dc.packets * 188.0 * 8 / 1e6 / secs : 0.0, dump_path);
	return 0;
}
