// SPDX-License-Identifier: GPL-2.0-only
/*
 * MPEG-TS PSI/SI parsing for the scanner: PAT, SDT actual and NIT actual,
 * with the ISDB-T (ARIB STD-B10 / ABNT NBR 15603) descriptors that carry
 * the virtual channel number.
 */
#include "psi.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PID_PAT 0x0000
#define PID_NIT 0x0010
#define PID_SDT 0x0011

#define TID_PAT 0x00
#define TID_NIT_ACTUAL 0x40
#define TID_SDT_ACTUAL 0x42

#define DESC_NETWORK_NAME 0x40
#define DESC_SERVICE 0x48
#define DESC_TS_INFORMATION 0xcd

#define MAX_SECTION 4096

struct section_buf {
	uint16_t pid;
	uint8_t data[MAX_SECTION];
	int len;	/* bytes collected so far */
	int need;	/* total section length once known, 0 while unknown */
	int cc;		/* last continuity counter, -1 for none */
};

/* Tracks which section_numbers of one table have been seen */
struct table_state {
	int version;	/* -1 until the first section */
	int last_section;
	uint8_t seen[256 / 8];
};

struct psi_parser {
	struct section_buf pat_buf, nit_buf, sdt_buf;
	struct table_state pat, nit, sdt;
	struct psi_mux mux;
};

static inline int min_int(int a, int b)
{
	return a < b ? a : b;
}

static uint32_t crc32_mpeg(const uint8_t *data, int len)
{
	uint32_t crc = 0xffffffff;

	while (len--) {
		crc ^= (uint32_t)*data++ << 24;
		for (int i = 0; i < 8; i++)
			crc = (crc & 0x80000000) ? (crc << 1) ^ 0x04c11db7 : crc << 1;
	}
	return crc;
}

struct psi_parser *psi_new(void)
{
	struct psi_parser *p = calloc(1, sizeof(*p));

	p->pat_buf.pid = PID_PAT;
	p->nit_buf.pid = PID_NIT;
	p->sdt_buf.pid = PID_SDT;
	p->pat_buf.cc = p->nit_buf.cc = p->sdt_buf.cc = -1;
	p->pat.version = p->nit.version = p->sdt.version = -1;
	return p;
}

void psi_free(struct psi_parser *p)
{
	free(p);
}

const struct psi_mux *psi_result(const struct psi_parser *p)
{
	return &p->mux;
}

bool psi_complete(const struct psi_parser *p)
{
	return p->mux.have_pat && p->mux.have_sdt && p->mux.have_nit;
}

static struct psi_service *service_get(struct psi_mux *m, uint16_t service_id)
{
	for (int i = 0; i < m->nservices; i++)
		if (m->services[i].service_id == service_id)
			return &m->services[i];
	if (m->nservices == PSI_MAX_SERVICES)
		return NULL;
	m->services[m->nservices].service_id = service_id;
	return &m->services[m->nservices++];
}

/*
 * Brazilian/Chilean ISDB-T text is ISO/IEC 8859-15 (NBR 15603-2): drop
 * control codes and character-set selectors, map the rest to UTF-8.
 */
static void decode_text(const uint8_t *s, int len, char *out, int outlen)
{
	static const struct { uint8_t latin9; uint16_t ucs; } l9[] = {
		{ 0xa4, 0x20ac }, { 0xa6, 0x0160 }, { 0xa8, 0x0161 }, { 0xb4, 0x017d },
		{ 0xb8, 0x017e }, { 0xbc, 0x0152 }, { 0xbd, 0x0153 }, { 0xbe, 0x0178 },
	};
	int o = 0;

	/* DVB-style leading charset selector (0x01..0x1f) */
	if (len > 0 && s[0] < 0x20) {
		int skip = s[0] == 0x10 ? 3 : 1;

		s += skip;
		len -= skip;
	}
	for (int i = 0; i < len && o < outlen - 4; i++) {
		uint16_t c = s[i];

		if (c < 0x20 || (c >= 0x7f && c < 0xa0))
			continue;
		for (size_t k = 0; k < sizeof(l9) / sizeof(l9[0]); k++)
			if (l9[k].latin9 == c)
				c = l9[k].ucs;
		if (c < 0x80) {
			out[o++] = c;
		} else if (c < 0x800) {
			out[o++] = 0xc0 | (c >> 6);
			out[o++] = 0x80 | (c & 0x3f);
		} else {
			out[o++] = 0xe0 | (c >> 12);
			out[o++] = 0x80 | ((c >> 6) & 0x3f);
			out[o++] = 0x80 | (c & 0x3f);
		}
	}
	while (o > 0 && out[o - 1] == ' ')
		o--;
	out[o] = '\0';
}

/* Records a section; returns true when every section of the table is in */
static bool table_mark(struct table_state *t, const uint8_t *sec)
{
	int version = (sec[5] >> 1) & 0x1f;
	int number = sec[6];
	int last = sec[7];

	if (t->version != version) {
		t->version = version;
		memset(t->seen, 0, sizeof(t->seen));
	}
	t->last_section = last;
	t->seen[number / 8] |= 1 << (number % 8);
	for (int i = 0; i <= last; i++)
		if (!(t->seen[i / 8] & (1 << (i % 8))))
			return false;
	return true;
}

static void parse_pat(struct psi_parser *p, const uint8_t *sec, int len)
{
	struct psi_mux *m = &p->mux;

	m->transport_stream_id = (sec[3] << 8) | sec[4];
	for (int i = 8; i + 4 <= len - 4; i += 4) {
		uint16_t program = (sec[i] << 8) | sec[i + 1];
		uint16_t pid = ((sec[i + 2] & 0x1f) << 8) | sec[i + 3];
		struct psi_service *s;

		if (program == 0)
			continue; /* network PID */
		s = service_get(m, program);
		if (s) {
			s->pmt_pid = pid;
			s->in_pat = true;
		}
	}
	if (table_mark(&p->pat, sec))
		m->have_pat = true;
}

static void parse_sdt(struct psi_parser *p, const uint8_t *sec, int len)
{
	struct psi_mux *m = &p->mux;
	int i = 11;

	m->original_network_id = (sec[8] << 8) | sec[9];
	while (i + 5 <= len - 4) {
		uint16_t sid = (sec[i] << 8) | sec[i + 1];
		int dlen = ((sec[i + 3] & 0x0f) << 8) | sec[i + 4];
		int d = i + 5, end = min_int(d + dlen, len - 4);
		struct psi_service *s = service_get(m, sid);

		if (s)
			s->in_sdt = true;
		while (s && d + 2 <= end) {
			uint8_t tag = sec[d], dl = sec[d + 1];

			if (d + 2 + dl > end)
				break;
			if (tag == DESC_SERVICE && dl >= 3) {
				const uint8_t *b = &sec[d + 2];
				int plen = b[1], nlen;

				s->service_type = b[0];
				if (2 + plen < dl) {
					decode_text(&b[2], plen, s->provider, sizeof(s->provider));
					nlen = b[2 + plen];
					if (3 + plen + nlen <= dl)
						decode_text(&b[3 + plen], nlen, s->name, sizeof(s->name));
				}
			}
			d += 2 + dl;
		}
		i += 5 + dlen;
	}
	if (table_mark(&p->sdt, sec))
		m->have_sdt = true;
}

static void parse_nit_descriptors(struct psi_mux *m, const uint8_t *d, int len)
{
	int i = 0;

	while (i + 2 <= len) {
		uint8_t tag = d[i], dl = d[i + 1];
		const uint8_t *b = &d[i + 2];

		if (i + 2 + dl > len)
			break;
		if (tag == DESC_NETWORK_NAME) {
			decode_text(b, dl, m->network_name, sizeof(m->network_name));
		} else if (tag == DESC_TS_INFORMATION && dl >= 2) {
			int nlen = b[1] >> 2;

			m->remote_control_key_id = b[0];
			if (2 + nlen <= dl)
				decode_text(&b[2], nlen, m->ts_name, sizeof(m->ts_name));
		}
		i += 2 + dl;
	}
}

static void parse_nit(struct psi_parser *p, const uint8_t *sec, int len)
{
	struct psi_mux *m = &p->mux;
	int ndl = ((sec[8] & 0x0f) << 8) | sec[9];
	int i = 10 + ndl, tsl;

	m->network_id = (sec[3] << 8) | sec[4];
	parse_nit_descriptors(m, &sec[10], min_int(ndl, len - 4 - 10));

	if (i + 2 > len - 4)
		goto done;
	tsl = ((sec[i] & 0x0f) << 8) | sec[i + 1];
	i += 2;
	while (i + 6 <= len - 4 && tsl >= 6) {
		uint16_t tsid = (sec[i] << 8) | sec[i + 1];
		int tdl = ((sec[i + 4] & 0x0f) << 8) | sec[i + 5];

		/* only our own TS carries the descriptors we care about */
		if (tsid == m->transport_stream_id || !m->have_pat)
			parse_nit_descriptors(m, &sec[i + 6], min_int(tdl, len - 4 - (i + 6)));
		i += 6 + tdl;
		tsl -= 6 + tdl;
	}
done:
	if (table_mark(&p->nit, sec))
		m->have_nit = true;
}

static void section_done(struct psi_parser *p, struct section_buf *sb)
{
	const uint8_t *sec = sb->data;
	int len = sb->need;

	if (len < 12 || !(sec[1] & 0x80) || !(sec[5] & 0x01))
		return; /* needs section_syntax_indicator and current_next */
	if (crc32_mpeg(sec, len) != 0)
		return;

	if (sb->pid == PID_PAT && sec[0] == TID_PAT)
		parse_pat(p, sec, len);
	else if (sb->pid == PID_SDT && sec[0] == TID_SDT_ACTUAL)
		parse_sdt(p, sec, len);
	else if (sb->pid == PID_NIT && sec[0] == TID_NIT_ACTUAL)
		parse_nit(p, sec, len);
}

/* Appends payload bytes, emitting each completed section */
static void section_append(struct psi_parser *p, struct section_buf *sb, const uint8_t *data, int len)
{
	while (len > 0) {
		int take;

		if (sb->len == 0 && data[0] == 0xff)
			return; /* stuffing */
		if (sb->need == 0 && sb->len < 3) {
			take = min_int(3 - sb->len, len);
			memcpy(&sb->data[sb->len], data, take);
			sb->len += take;
			data += take;
			len -= take;
			if (sb->len == 3) {
				sb->need = 3 + (((sb->data[1] & 0x0f) << 8) | sb->data[2]);
				if (sb->need > MAX_SECTION) {
					sb->len = sb->need = 0;
					return;
				}
			}
			continue;
		}
		take = min_int(sb->need - sb->len, len);
		memcpy(&sb->data[sb->len], data, take);
		sb->len += take;
		data += take;
		len -= take;
		if (sb->len == sb->need) {
			section_done(p, sb);
			sb->len = sb->need = 0;
		}
	}
}

void psi_feed(struct psi_parser *p, const uint8_t *pkt)
{
	uint16_t pid = ((pkt[1] & 0x1f) << 8) | pkt[2];
	bool pusi = pkt[1] & 0x40;
	int afc = (pkt[3] >> 4) & 3, cc = pkt[3] & 0x0f;
	int off = 4;
	struct section_buf *sb;

	if (pkt[0] != 0x47 || (pkt[1] & 0x80))
		return; /* lost sync or transport_error_indicator */
	switch (pid) {
	case PID_PAT: sb = &p->pat_buf; break;
	case PID_NIT: sb = &p->nit_buf; break;
	case PID_SDT: sb = &p->sdt_buf; break;
	default: return;
	}
	if (!(afc & 1))
		return; /* no payload */
	if (afc & 2)
		off += 1 + pkt[4];
	if (off >= 188)
		return;

	/* a gap in the counter corrupts whatever section was in progress */
	if (sb->cc >= 0 && cc != ((sb->cc + 1) & 0x0f) && sb->len) {
		sb->len = sb->need = 0;
	}
	sb->cc = cc;

	if (pusi) {
		int pointer = pkt[off++];

		if (off + pointer > 188)
			return;
		if (sb->len)
			section_append(p, sb, &pkt[off], pointer);
		sb->len = sb->need = 0;
		off += pointer;
	} else if (sb->len == 0) {
		return; /* mid-section, and we never saw its start */
	}
	section_append(p, sb, &pkt[off], 188 - off);
}

bool psi_is_oneseg(const struct psi_service *s)
{
	return s->pmt_pid >= 0x1fc8 && s->pmt_pid <= 0x1fcf;
}

void psi_virtual_channel(const struct psi_mux *m, const struct psi_service *s, int *major, int *minor)
{
	*major = m->remote_control_key_id;
	if (psi_is_oneseg(s))
		*minor = 31 + (s->pmt_pid - 0x1fc8);
	else
		*minor = (s->service_id & 0x7) + 1;
}
