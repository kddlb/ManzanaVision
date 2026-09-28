// SPDX-License-Identifier: GPL-2.0-only
/*
 * Single-program filter: keeps one service's PAT (optionally rewritten to
 * list only that service), PMT, PCR and elementary streams, so players open
 * the right program without being told.
 */
#include "core.h"

struct mzv_filter {
	struct psi_parser *psi;
	u16 service_id;
	bool rewrite_pat;

	u8 allowed[8192 / 8];	/* PIDs of the program, besides the PAT */
	unsigned int pmt_generation;
	u16 pat_pmt_pid;	/* PMT PID the current synthetic PAT points at */
	u8 pat_version;
	u8 pat_cc;
};

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

mzv_filter *mzv_filter_new(uint16_t service_id, bool rewrite_pat)
{
	mzv_filter *f = calloc(1, sizeof(*f));

	f->psi = psi_new();
	f->service_id = service_id;
	f->rewrite_pat = rewrite_pat;
	psi_watch_program(f->psi, service_id);
	return f;
}

void mzv_filter_free(mzv_filter *f)
{
	if (!f)
		return;
	psi_free(f->psi);
	free(f);
}

static void allow(mzv_filter *f, u16 pid)
{
	f->allowed[pid / 8] |= 1 << (pid % 8);
}

static bool allowed(const mzv_filter *f, u16 pid)
{
	return f->allowed[pid / 8] & (1 << (pid % 8));
}

static void rebuild_pid_set(mzv_filter *f, const struct psi_program *prog)
{
	memset(f->allowed, 0, sizeof(f->allowed));
	allow(f, prog->pmt_pid);
	if (prog->pcr_pid != 0x1fff)
		allow(f, prog->pcr_pid);
	for (int i = 0; i < prog->nes; i++)
		allow(f, prog->es[i].pid);
	f->pmt_generation = prog->generation;
}

/* A PAT listing only our program */
static void make_pat(mzv_filter *f, u16 tsid, u16 pmt_pid, u8 *pkt)
{
	u8 *sec = &pkt[5];
	uint32_t crc;

	if (pmt_pid != f->pat_pmt_pid) {
		f->pat_pmt_pid = pmt_pid;
		f->pat_version = (f->pat_version + 1) & 0x1f;
	}
	memset(pkt, 0xff, MZV_TS_PACKET_SIZE);
	pkt[0] = 0x47;
	pkt[1] = 0x40;			/* payload_unit_start, PID 0 */
	pkt[2] = 0x00;
	pkt[3] = 0x10 | f->pat_cc;	/* payload only */
	f->pat_cc = (f->pat_cc + 1) & 0x0f;
	pkt[4] = 0x00;			/* pointer_field */

	sec[0] = 0x00;			/* table_id: PAT */
	sec[1] = 0xb0;			/* syntax indicator, section_length 13 */
	sec[2] = 13;
	sec[3] = tsid >> 8;
	sec[4] = tsid & 0xff;
	sec[5] = 0xc1 | (f->pat_version << 1);	/* current_next */
	sec[6] = 0;			/* section_number */
	sec[7] = 0;			/* last_section_number */
	sec[8] = f->service_id >> 8;
	sec[9] = f->service_id & 0xff;
	sec[10] = 0xe0 | (pmt_pid >> 8);
	sec[11] = pmt_pid & 0xff;
	crc = crc32_mpeg(sec, 12);
	sec[12] = crc >> 24;
	sec[13] = crc >> 16;
	sec[14] = crc >> 8;
	sec[15] = crc;
}

size_t mzv_filter_feed(mzv_filter *f, const uint8_t *packets, size_t count, uint8_t *out)
{
	size_t n = 0;

	for (size_t i = 0; i < count; i++) {
		const u8 *pkt = packets + i * MZV_TS_PACKET_SIZE;
		u8 *dst = out + n * MZV_TS_PACKET_SIZE;
		const struct psi_mux *m;
		const struct psi_program *prog;
		u16 pid;

		psi_feed(f->psi, pkt);
		m = psi_result(f->psi);
		prog = &m->program;
		pid = ((pkt[1] & 0x1f) << 8) | pkt[2];

		if (prog->have_pmt && prog->generation != f->pmt_generation)
			rebuild_pid_set(f, prog);

		if (pid == 0) {
			if (!f->rewrite_pat) {
				memcpy(dst, pkt, MZV_TS_PACKET_SIZE);
				n++;
			} else if ((pkt[1] & 0x40) && prog->pmt_pid) {
				/* replace each PAT once the real one told us the PMT PID */
				make_pat(f, m->transport_stream_id, prog->pmt_pid, dst);
				n++;
			}
		} else if ((prog->pmt_pid && pid == prog->pmt_pid) || allowed(f, pid)) {
			memcpy(dst, pkt, MZV_TS_PACKET_SIZE);
			n++;
		}
	}
	return n;
}

bool mzv_filter_program(const mzv_filter *f, struct mzv_program *out)
{
	const struct psi_program *prog = &psi_result(f->psi)->program;

	if (!prog->have_pmt)
		return false;
	memset(out, 0, sizeof(*out));
	out->service_id = f->service_id;
	out->pmt_pid = prog->pmt_pid;
	out->pcr_pid = prog->pcr_pid;
	out->generation = prog->generation;
	out->nes = prog->nes < MZV_MAX_ES ? prog->nes : MZV_MAX_ES;
	for (int i = 0; i < out->nes; i++) {
		out->es[i].stream_type = prog->es[i].stream_type;
		out->es[i].pid = prog->es[i].pid;
	}
	return true;
}
