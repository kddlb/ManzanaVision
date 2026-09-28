// SPDX-License-Identifier: GPL-2.0-only
/*
 * mzv_stream: tune, stream (whole mux or one program), watch the lock from
 * the USB idle tick, and re-tune when it's gone. Packets reach the caller in
 * batches so the libusb event path stays short.
 */
#include "core.h"
#include "stk8096gp.h"

#define BATCH_PACKETS 256
#define BATCH_MAX_AGE_MS 50
#define LOCK_CHECK_MS 500
#define DEFAULT_RELOCK_AFTER_MS 2000
#define RETUNE_PAUSE_MS 200

struct stream_ctx {
	mzv_device *dev;
	const struct mzv_stream_options *opts;
	const struct mzv_stream_callbacks *cb;
	mzv_filter *filter;
	unsigned int relock_after_ms;

	u8 batch[BATCH_PACKETS * MZV_TS_PACKET_SIZE];
	size_t nbatch;
	unsigned long batch_started_ms;
	uint32_t epoch;
	unsigned int program_generation;

	unsigned long start_ms;
	unsigned long last_lock_check_ms;
	unsigned long last_signal_ms;
	unsigned long unlocked_since_ms;	/* 0 while locked */
	bool need_retune;
	bool stop;
};

static void flush(struct stream_ctx *s)
{
	if (!s->nbatch)
		return;
	if (s->cb->packets && s->cb->packets(s->batch, s->nbatch, s->epoch, s->cb->ctx))
		s->stop = true;
	s->nbatch = 0;
}

static void check_program(struct stream_ctx *s)
{
	struct mzv_program prog;

	if (!s->filter || !s->cb->program || !mzv_filter_program(s->filter, &prog))
		return;
	if (prog.generation != s->program_generation) {
		s->program_generation = prog.generation;
		s->cb->program(&prog, s->cb->ctx);
	}
}

/* Idle tick from the read loop: timers, lock watch, signal callbacks */
static void tick(struct stream_ctx *s)
{
	unsigned long now = jiffies;
	const struct mzv_stream_options *o = s->opts;

	if (o->duration_ms && now - s->start_ms >= o->duration_ms)
		s->stop = true;
	if (s->nbatch && now - s->batch_started_ms >= BATCH_MAX_AGE_MS)
		flush(s);

	bool signal_due = o->signal_interval_ms && s->cb->signal &&
			  now - s->last_signal_ms >= o->signal_interval_ms;
	bool lock_due = now - s->last_lock_check_ms >= LOCK_CHECK_MS;
	bool locked;

	if (!signal_due && !lock_due)
		return;
	if (signal_due) {
		struct mzv_signal sig;

		mzv_read_signal(s->dev, &sig);
		s->cb->signal(&sig, s->cb->ctx);
		s->last_signal_ms = now;
		locked = sig.has_lock;
	} else {
		locked = stk_read_status() & FE_HAS_LOCK;
	}
	s->last_lock_check_ms = now;

	if (locked) {
		s->unlocked_since_ms = 0;
	} else if (!s->unlocked_since_ms) {
		s->unlocked_since_ms = now;
	} else if (now - s->unlocked_since_ms >= s->relock_after_ms) {
		s->need_retune = true;
	}
}

static int read_cb(const u8 *pkt, void *opaque)
{
	struct stream_ctx *s = opaque;

	if (!pkt) {
		tick(s);
	} else {
		u8 *dst = s->batch + s->nbatch * MZV_TS_PACKET_SIZE;
		size_t n;

		if (!s->nbatch)
			s->batch_started_ms = jiffies;
		if (s->filter) {
			n = mzv_filter_feed(s->filter, pkt, 1, dst);
			check_program(s);
		} else {
			memcpy(dst, pkt, MZV_TS_PACKET_SIZE);
			n = 1;
		}
		s->nbatch += n;
		if (s->nbatch == BATCH_PACKETS)
			flush(s);
	}
	return s->stop || s->need_retune || mzv_is_cancelled(s->dev);
}

static void event(struct stream_ctx *s, enum mzv_event ev)
{
	if (s->cb->event)
		s->cb->event(ev, s->epoch, s->cb->ctx);
}

/* Keeps re-tuning until lock or cancel */
static int retune(struct stream_ctx *s)
{
	struct mzv_signal sig;

	event(s, MZV_EVENT_RETUNING);
	for (;;) {
		if (mzv_is_cancelled(s->dev))
			return MZV_ERR_CANCELLED;
		if (mzv_tune(s->dev, s->opts->rf, &sig) == MZV_OK && sig.has_lock)
			return MZV_OK;
		msleep(RETUNE_PAUSE_MS);
	}
}

int mzv_stream(mzv_device *dev, const struct mzv_stream_options *opts, const struct mzv_stream_callbacks *cb)
{
	struct stream_ctx *s;
	struct mzv_signal sig;
	int ret = MZV_OK;

	if (!opts || !cb || opts->rf < MZV_RF_MIN || opts->rf > MZV_RF_MAX)
		return MZV_ERR_INVALID;

	if (!(opts->skip_tune_if_locked && dev->tuned_rf == opts->rf && (stk_read_status() & FE_HAS_LOCK))) {
		ret = mzv_tune(dev, opts->rf, &sig);
		if (ret < 0)
			return ret;
		if (!sig.has_lock)
			return MZV_ERR_NO_LOCK;
	}

	s = calloc(1, sizeof(*s));
	s->dev = dev;
	s->opts = opts;
	s->cb = cb;
	s->relock_after_ms = opts->relock_after_ms ? opts->relock_after_ms : DEFAULT_RELOCK_AFTER_MS;
	if (opts->service_id)
		s->filter = mzv_filter_new(opts->service_id, opts->rewrite_pat);
	s->start_ms = s->last_lock_check_ms = jiffies;

	event(s, MZV_EVENT_LOCKED);
	for (;;) {
		int n;

		dib0700_streaming_ctrl(dev->bridge, 1);
		n = dib0700_read_ts(dev->bridge, 0, read_cb, s);
		dib0700_streaming_ctrl(dev->bridge, 0);
		flush(s);

		if (n == LIBUSB_ERROR_NO_DEVICE) {
			ret = MZV_ERR_GONE;
			break;
		}
		if (n < 0) {
			ret = MZV_ERR_IO;
			break;
		}
		if (s->stop || mzv_is_cancelled(dev) || !s->need_retune)
			break;

		/* the demod won't re-acquire on its own */
		s->need_retune = false;
		event(s, MZV_EVENT_LOCK_LOST);
		if (retune(s) < 0)
			break;
		s->epoch++;
		s->unlocked_since_ms = 0;
		s->last_lock_check_ms = jiffies;
		event(s, MZV_EVENT_RELOCKED);
	}

	mzv_filter_free(s->filter);
	free(s);
	return ret;
}
