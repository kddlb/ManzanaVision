// SPDX-License-Identifier: GPL-2.0-only
/* One-channel scan: tune, read TMCC, collect PAT/SDT/NIT */
#include "core.h"
#include "stk8096gp.h"

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

void mzv_mux_fill_psi(struct mzv_mux *out, const struct psi_mux *m)
{
	out->have_pat = m->have_pat;
	out->have_sdt = m->have_sdt;
	out->have_nit = m->have_nit;
	out->have_psi = m->have_pat || m->have_sdt || m->have_nit;
	out->transport_stream_id = m->transport_stream_id;
	out->original_network_id = m->original_network_id;
	out->network_id = m->network_id;
	out->remote_control_key_id = m->remote_control_key_id;
	snprintf(out->network_name, sizeof(out->network_name), "%s", m->network_name);
	snprintf(out->ts_name, sizeof(out->ts_name), "%s", m->ts_name);

	out->nservices = 0;
	for (int i = 0; i < m->nservices && out->nservices < MZV_MAX_SERVICES; i++) {
		const struct psi_service *s = &m->services[i];
		struct mzv_service *o = &out->services[out->nservices++];

		memset(o, 0, sizeof(*o));
		o->service_id = s->service_id;
		o->pmt_pid = s->in_pat ? s->pmt_pid : 0;
		o->service_type = s->service_type;
		o->in_pat = s->in_pat;
		o->in_sdt = s->in_sdt;
		/* PAT lives in the full-seg layer; without it, fall back to the SDT list */
		o->listed = m->have_pat ? s->in_pat : s->in_sdt;
		psi_virtual_channel(m, s, &o->major, &o->minor);
		snprintf(o->kind, sizeof(o->kind), "%s", service_kind(s));
		snprintf(o->name, sizeof(o->name), "%s", s->name);
		snprintf(o->provider, sizeof(o->provider), "%s", s->provider);
	}
}

struct collect_ctx {
	mzv_device *dev;
	struct psi_parser *psi;
};

static int collect_cb(const u8 *pkt, void *opaque)
{
	struct collect_ctx *c = opaque;

	if (!pkt)
		return mzv_is_cancelled(c->dev);
	psi_feed(c->psi, pkt);
	return psi_complete(c->psi) || mzv_is_cancelled(c->dev);
}

int mzv_scan_rf(mzv_device *dev, int rf, unsigned int psi_timeout_ms, struct mzv_mux *out)
{
	struct collect_ctx c = { .dev = dev };
	int ret;

	memset(out, 0, sizeof(*out));
	out->rf = rf;
	out->frequency = mzv_rf_frequency(rf);
	ret = mzv_tune(dev, rf, &out->signal);
	if (ret < 0)
		return ret;
	if (!out->signal.has_lock)
		return MZV_OK;

	out->have_tmcc = mzv_read_tmcc(dev, &out->tmcc) == MZV_OK;

	c.psi = psi_new();
	dib0700_streaming_ctrl(dev->bridge, 1);
	ret = dib0700_read_ts(dev->bridge, psi_timeout_ms, collect_cb, &c);
	dib0700_streaming_ctrl(dev->bridge, 0);
	out->ts_packets = ret > 0 ? ret : 0;
	mzv_mux_fill_psi(out, psi_result(c.psi));
	psi_free(c.psi);

	if (ret == LIBUSB_ERROR_NO_DEVICE)
		return MZV_ERR_GONE;
	if (ret < 0)
		return MZV_ERR_IO;
	return mzv_is_cancelled(dev) ? MZV_ERR_CANCELLED : MZV_OK;
}

void mzv_mux_from_packets(const uint8_t *packets, size_t count, int rf, struct mzv_mux *out)
{
	struct psi_parser *psi = psi_new();

	memset(out, 0, sizeof(*out));
	out->rf = rf;
	out->frequency = rf ? mzv_rf_frequency(rf) : 0;
	for (size_t i = 0; i < count; i++)
		psi_feed(psi, packets + i * MZV_TS_PACKET_SIZE);
	out->ts_packets = (int)count;
	mzv_mux_fill_psi(out, psi_result(psi));
	psi_free(psi);
}
