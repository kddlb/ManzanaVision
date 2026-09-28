// SPDX-License-Identifier: GPL-2.0-only
/* Device lifecycle, tuning and signal readings */
#include <signal.h>

#include "core.h"
#include "stk8096gp.h"

/* the board glue keeps one global state, so one device per process */
static atomic_bool device_open;

int mzv_open(const char *firmware_path, mzv_device **out)
{
	mzv_device *dev;
	int ret;

	*out = NULL;
	if (!firmware_path)
		return MZV_ERR_INVALID;
	if (atomic_exchange(&device_open, true))
		return MZV_ERR_BUSY;

	dev = calloc(1, sizeof(*dev));
	ret = dib0700_open(firmware_path, &dev->bridge);
	if (ret < 0)
		goto fail;
	dev->info.firmware_version = dib0700_fw_version(dev->bridge);
	dev->info.firmware_uploaded = dib0700_was_cold(dev->bridge);

	if (stk_open(dev->bridge) < 0) {
		dib0700_close(dev->bridge);
		ret = MZV_ERR_NO_FRONTEND;
		goto fail;
	}
	dev->info.demod_revision = stk_demod_revision();
	*out = dev;
	return MZV_OK;

fail:
	free(dev);
	atomic_store(&device_open, false);
	return ret;
}

void mzv_close(mzv_device *dev)
{
	if (!dev)
		return;
	stk_close();
	dib0700_close(dev->bridge);
	free(dev);
	atomic_store(&device_open, false);
}

void mzv_get_info(const mzv_device *dev, struct mzv_device_info *info)
{
	*info = dev->info;
}

void mzv_cancel(mzv_device *dev)
{
	atomic_store(&dev->cancel, true);
}

void mzv_reset_cancel(mzv_device *dev)
{
	atomic_store(&dev->cancel, false);
}

bool mzv_is_cancelled(const mzv_device *dev)
{
	return atomic_load(&((mzv_device *)dev)->cancel);
}

uint32_t mzv_rf_frequency(int rf)
{
	/* ABNT NBR 15601: 473 MHz + 6 MHz steps, plus a 1/7 MHz offset */
	return 473000000u + 6000000u * (uint32_t)(rf - 14) + 142857u;
}

/*
 * Fills a reading for the given status. The demod's uncorrectable-packet
 * count is windowed: it climbs during a measurement period, then restarts,
 * so a drop means a new window whose errors so far are the new value.
 */
static void signal_fill(mzv_device *dev, enum fe_status status, struct mzv_signal *s)
{
	unsigned long now = jiffies;

	memset(s, 0, sizeof(*s));
	s->status = status;
	s->has_signal = status & FE_HAS_SIGNAL;
	s->has_lock = status & FE_HAS_LOCK;
	stk_read_signal(&s->strength, &s->snr_tenths);
	s->strength_pct = s->strength * 100 / 65535;
	s->snr_db = s->snr_tenths / 10.0;

	if (!s->has_lock) {
		dev->have_ucb = false;
		dev->ucb_rate = 0;
		return;
	}
	s->layer_lock = stk_layer_lock();

	u16 ucb = stk_read_ucb();

	if (dev->have_ucb && now > dev->last_ucb_ms) {
		u16 delta = ucb >= dev->last_ucb ? ucb - dev->last_ucb : ucb;
		double rate = delta * 1000.0 / (now - dev->last_ucb_ms);

		dev->ucb_rate = dev->ucb_rate * 0.6 + rate * 0.4;
	}
	dev->last_ucb = ucb;
	dev->last_ucb_ms = now;
	dev->have_ucb = true;
	s->errors_per_s = dev->ucb_rate;
}

int mzv_tune(mzv_device *dev, int rf, struct mzv_signal *signal)
{
	struct mzv_signal tmp;
	enum fe_status status;

	if (rf < MZV_RF_MIN || rf > MZV_RF_MAX)
		return MZV_ERR_INVALID;
	if (mzv_is_cancelled(dev))
		return MZV_ERR_CANCELLED;

	status = stk_tune(mzv_rf_frequency(rf));
	dev->tuned_rf = rf;
	dev->have_ucb = false;
	dev->ucb_rate = 0;
	signal_fill(dev, status, signal ? signal : &tmp);
	return MZV_OK;
}

int mzv_read_signal(mzv_device *dev, struct mzv_signal *signal)
{
	signal_fill(dev, stk_read_status(), signal);
	return MZV_OK;
}

static enum mzv_modulation modulation(enum fe_modulation m)
{
	switch (m) {
	case QPSK: return MZV_MOD_QPSK;
	case DQPSK: return MZV_MOD_DQPSK;
	case QAM_16: return MZV_MOD_QAM16;
	case QAM_64: return MZV_MOD_QAM64;
	default: return MZV_MOD_UNKNOWN;
	}
}

static enum mzv_code_rate code_rate(enum fe_code_rate f)
{
	switch (f) {
	case FEC_1_2: return MZV_FEC_1_2;
	case FEC_2_3: return MZV_FEC_2_3;
	case FEC_3_4: return MZV_FEC_3_4;
	case FEC_5_6: return MZV_FEC_5_6;
	case FEC_7_8: return MZV_FEC_7_8;
	default: return MZV_FEC_UNKNOWN;
	}
}

int mzv_read_tmcc(mzv_device *dev, struct mzv_tmcc *tmcc)
{
	struct dtv_frontend_properties c;
	int used = 0;

	(void)dev;
	memset(tmcc, 0, sizeof(*tmcc));
	if (stk_get_tmcc(&c) != 0)
		return MZV_ERR_IO;

	switch (c.transmission_mode) {
	case TRANSMISSION_MODE_2K: tmcc->mode = 1; break;
	case TRANSMISSION_MODE_4K: tmcc->mode = 2; break;
	case TRANSMISSION_MODE_8K: tmcc->mode = 3; break;
	default: break;
	}
	switch (c.guard_interval) {
	case GUARD_INTERVAL_1_4: tmcc->guard_interval = 4; break;
	case GUARD_INTERVAL_1_8: tmcc->guard_interval = 8; break;
	case GUARD_INTERVAL_1_16: tmcc->guard_interval = 16; break;
	case GUARD_INTERVAL_1_32: tmcc->guard_interval = 32; break;
	default: break;
	}
	for (int l = 0; l < 3; l++) {
		tmcc->layer[l].segments = c.layer[l].segment_count;
		tmcc->layer[l].modulation = modulation(c.layer[l].modulation);
		tmcc->layer[l].fec = code_rate(c.layer[l].fec);
		tmcc->layer[l].interleaving = c.layer[l].interleaving;
		used += c.layer[l].segment_count;
	}
	/* the demod only fills TMCC once it has synced */
	return used ? MZV_OK : MZV_ERR_NO_LOCK;
}

const char *mzv_modulation_name(enum mzv_modulation m)
{
	switch (m) {
	case MZV_MOD_QPSK: return "QPSK";
	case MZV_MOD_DQPSK: return "DQPSK";
	case MZV_MOD_QAM16: return "16QAM";
	case MZV_MOD_QAM64: return "64QAM";
	default: return "?";
	}
}

const char *mzv_code_rate_name(enum mzv_code_rate f)
{
	switch (f) {
	case MZV_FEC_1_2: return "1/2";
	case MZV_FEC_2_3: return "2/3";
	case MZV_FEC_3_4: return "3/4";
	case MZV_FEC_5_6: return "5/6";
	case MZV_FEC_7_8: return "7/8";
	default: return "?";
	}
}

const char *mzv_guard_interval_name(int denominator)
{
	switch (denominator) {
	case 4: return "1/4";
	case 8: return "1/8";
	case 16: return "1/16";
	case 32: return "1/32";
	default: return "?";
	}
}
