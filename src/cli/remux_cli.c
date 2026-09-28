// SPDX-License-Identifier: GPL-2.0-only
/*
 * remux: run the single-program filter over a recording, exactly as
 * `watch` does live. Handy for checking the filter and cutting test clips.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cli.h"

#define CHUNK_PACKETS 4096
#define PSI_PROBE_BYTES (16u << 20)

/* A virtual number ("9.1") resolved through the recording's own PSI */
static int resolve_service(FILE *in, const char *what, uint16_t *sid)
{
	char *end;
	unsigned long v = strtoul(what, &end, 0);
	struct mzv_mux mux;
	uint8_t *buf;
	size_t n;
	int major, minor;

	if (*end == '\0' && v > 0 && v <= 0xffff) {
		*sid = (uint16_t)v;
		return 0;
	}
	if (sscanf(what, "%d.%d", &major, &minor) != 2)
		return -1;

	buf = malloc(PSI_PROBE_BYTES);
	n = fread(buf, 1, PSI_PROBE_BYTES, in) / MZV_TS_PACKET_SIZE;
	rewind(in);
	mzv_mux_from_packets(buf, n, 0, &mux);
	free(buf);
	for (int i = 0; i < mux.nservices; i++) {
		if (mux.services[i].listed && mux.services[i].major == major && mux.services[i].minor == minor) {
			*sid = mux.services[i].service_id;
			return 0;
		}
	}
	return -1;
}

int remux_run(const char *in_path, const char *what, const char *out_path)
{
	FILE *in = fopen(in_path, "rb"), *out;
	uint8_t *ibuf, *obuf;
	uint16_t sid;
	size_t n, kept = 0, total = 0;
	mzv_filter *f;
	struct mzv_program prog;

	if (!in) {
		perror(in_path);
		return 1;
	}
	if (resolve_service(in, what, &sid) < 0) {
		fprintf(stderr, "no service \"%s\" in %s\n", what, in_path);
		fclose(in);
		return 1;
	}
	out = fopen(out_path, "wb");
	if (!out) {
		perror(out_path);
		fclose(in);
		return 1;
	}
	ibuf = malloc(CHUNK_PACKETS * MZV_TS_PACKET_SIZE);
	obuf = malloc(CHUNK_PACKETS * MZV_TS_PACKET_SIZE);
	f = mzv_filter_new(sid, true);
	while ((n = fread(ibuf, MZV_TS_PACKET_SIZE, CHUNK_PACKETS, in)) > 0) {
		size_t k = mzv_filter_feed(f, ibuf, n, obuf);

		fwrite(obuf, MZV_TS_PACKET_SIZE, k, out);
		kept += k;
		total += n;
	}
	if (mzv_filter_program(f, &prog))
		fprintf(stderr, "program %d: PMT 0x%04x, %d stream%s\n", prog.service_id, prog.pmt_pid, prog.nes,
			prog.nes == 1 ? "" : "s");
	else
		fprintf(stderr, "never saw the PMT of service 0x%04x\n", sid);
	fprintf(stderr, "kept %zu of %zu packets\n", kept, total);
	mzv_filter_free(f);
	free(ibuf);
	free(obuf);
	fclose(in);
	fclose(out);
	return 0;
}
