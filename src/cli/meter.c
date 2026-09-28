// SPDX-License-Identifier: GPL-2.0-only
/*
 * Live signal meter: stay on one channel and refresh SNR, level, error rate
 * and per-layer lock a few times a second, for aiming an antenna.
 */
#include "meter.h"

#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "manzana.h"
#include "tone.h"

#define REFRESH_MS 250
#define RETUNE_AFTER_MS 2000
#define SNR_FULL_SCALE 30.0	/* dB at a full bar */
#define BAR_WIDTH 30
#define TONE_LOW_HZ 300.0	/* pitch at 0 dB SNR */
#define TONE_HIGH_HZ 1500.0	/* pitch at SNR_FULL_SCALE */

struct meter_state {
	mzv_device *dev;
	int rf;
	uint32_t freq;
	bool tty;
	bool beep;

	struct mzv_tmcc tmcc;
	bool have_tmcc;
	uint8_t layers_enabled;	/* bit per layer with segments */

	unsigned long start_ms;
	unsigned long locked_since_ms;	/* 0 while unlocked */
	unsigned long unlocked_since_ms;

	double peak_snr;
	double ucb_rate;	/* errored packets per second, smoothed by the core */

	int lines_drawn;
};

static unsigned long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (unsigned long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void bar(double fraction, char *out)
{
	int full = (int)(fraction * BAR_WIDTH + 0.5);

	if (full < 0)
		full = 0;
	if (full > BAR_WIDTH)
		full = BAR_WIDTH;
	out[0] = '\0';
	for (int i = 0; i < BAR_WIDTH; i++)
		strcat(out, i < full ? "█" : "░");
}

static void fmt_duration(unsigned long ms, char *out, size_t len)
{
	unsigned long s = ms / 1000;

	snprintf(out, len, "%lu:%02lu", s / 60, s % 60);
}

/* Higher SNR, higher pitch; exponential so equal dB steps sound equal */
static double snr_to_hz(double snr)
{
	double f = snr / SNR_FULL_SCALE;

	if (f < 0)
		f = 0;
	if (f > 1)
		f = 1;
	return TONE_LOW_HZ * pow(TONE_HIGH_HZ / TONE_LOW_HZ, f);
}

static void retune(struct meter_state *m)
{
	mzv_tune(m->dev, m->rf, NULL);
	m->have_tmcc = false;
	m->layers_enabled = 0;
	m->ucb_rate = 0;
}

static void refresh_tmcc(struct meter_state *m)
{
	if (m->have_tmcc || mzv_read_tmcc(m->dev, &m->tmcc) != MZV_OK)
		return;
	m->layers_enabled = 0;
	for (int l = 0; l < 3; l++)
		if (m->tmcc.layer[l].segments)
			m->layers_enabled |= 1 << l;
	m->have_tmcc = m->layers_enabled != 0;
}

/* Draws the full-screen view; moves the cursor back over the previous frame */
static void draw_tty(struct meter_state *m, const struct mzv_signal *sig, double snr, int level, uint8_t layer_lock,
		     unsigned long now)
{
	char b[BAR_WIDTH * 4 + 1], dur[16];
	bool locked = sig->has_lock;
	int lines = 0;

	if (m->lines_drawn)
		printf("\033[%dA", m->lines_drawn);

	if (locked)
		fmt_duration(now - m->locked_since_ms, dur, sizeof(dur));
	printf("\033[2KRF %d  %.3f MHz   %s%s%s   (Ctrl-C to stop)\n", m->rf, m->freq / 1e6,
	       locked ? "\033[32mLOCKED\033[0m " : sig->has_signal ? "\033[33msearching\033[0m" : "\033[31mno signal\033[0m",
	       locked ? dur : "", "");
	lines++;

	bar(snr / SNR_FULL_SCALE, b);
	printf("\033[2K SNR   %5.1f dB  %s  peak %.1f dB\n", snr, b, m->peak_snr);
	lines++;
	bar(level / 100.0, b);
	printf("\033[2K Level   %3d %%  %s\n", level, b);
	lines++;

	if (m->have_tmcc) {
		for (int l = 0; l < 3; l++) {
			const struct mzv_tmcc *c = &m->tmcc;
			bool ok = (layer_lock >> l) & 1;

			if (!(m->layers_enabled & (1 << l)))
				continue;
			printf("\033[2K Layer %c  %2d seg  %-5s %-3s   %s\n", 'A' + l, c->layer[l].segments,
			       mzv_modulation_name(c->layer[l].modulation), mzv_code_rate_name(c->layer[l].fec),
			       ok ? "\033[32mok\033[0m" : "\033[31mNO LOCK\033[0m");
			lines++;
		}
	} else {
		printf("\033[2K Layers  (waiting for TMCC)\n");
		lines++;
	}

	if (locked)
		printf("\033[2K Errors  %.0f packets/s%s\n", m->ucb_rate,
		       m->ucb_rate < 0.5 ? "  (clean)" : "");
	else
		printf("\033[2K Errors  -\n");
	lines++;

	/* pad to the tallest frame so far, so the next redraw lines up */
	for (; lines < m->lines_drawn; lines++)
		printf("\033[2K\n");
	m->lines_drawn = lines;
	fflush(stdout);
}

/* One line per second for logs and pipes */
static void draw_line(struct meter_state *m, const struct mzv_signal *sig, double snr, int level, uint8_t layer_lock,
		      unsigned long now)
{
	printf("%6.1fs  RF %d  %-9s  SNR %5.1f dB  level %3d%%", (now - m->start_ms) / 1000.0, m->rf,
	       sig->has_lock ? "LOCKED" : sig->has_signal ? "searching" : "no signal",
	       snr, level);
	for (int l = 0; l < 3; l++)
		if (m->layers_enabled & (1 << l))
			printf("  %c:%s", 'A' + l, (layer_lock >> l) & 1 ? "ok" : "--");
	if (sig->has_lock)
		printf("  err %.0f/s", m->ucb_rate);
	printf("\n");
	fflush(stdout);
}

int meter_run(mzv_device *dev, int rf, bool beep)
{
	struct meter_state m = {
		.dev = dev,
		.rf = rf,
		.freq = mzv_rf_frequency(rf),
		.tty = isatty(STDOUT_FILENO),
		.beep = beep,
	};
	unsigned long last_line_ms = 0;

	m.start_ms = now_ms();
	if (m.beep && tone_start() < 0)
		m.beep = false;
	if (m.tty)
		printf("\033[?25l"); /* hide cursor */
	printf("tuning RF %d...\n", rf);
	fflush(stdout);
	if (m.tty)
		printf("\033[1A");
	retune(&m);
	m.unlocked_since_ms = now_ms();

	while (!mzv_is_cancelled(dev)) {
		unsigned long now = now_ms();
		struct mzv_signal sig;
		bool locked;
		uint8_t layer_lock = 0;
		double snr;
		int level;

		mzv_read_signal(dev, &sig);
		locked = sig.has_lock;
		snr = sig.snr_db;
		level = sig.strength_pct;

		if (locked) {
			bool fully;

			if (!m.locked_since_ms)
				m.locked_since_ms = now;
			m.unlocked_since_ms = 0;
			refresh_tmcc(&m);
			layer_lock = sig.layer_lock;
			if (snr > m.peak_snr)
				m.peak_snr = snr;
			m.ucb_rate = sig.errors_per_s;

			fully = m.have_tmcc && (layer_lock & m.layers_enabled) == m.layers_enabled;
			if (m.beep)
				tone_set(snr_to_hz(snr), fully ? TONE_STEADY : TONE_PULSED);
		} else {
			if (m.beep)
				tone_set(TONE_LOW_HZ, TONE_SILENT);
			m.locked_since_ms = 0;
			if (!m.unlocked_since_ms)
				m.unlocked_since_ms = now;
		}

		if (m.tty) {
			draw_tty(&m, &sig, snr, level, layer_lock, now);
		} else if (now - last_line_ms >= 1000) {
			draw_line(&m, &sig, snr, level, layer_lock, now);
			last_line_ms = now;
		}

		/* the demod doesn't re-acquire by itself once it has lost lock */
		if (!locked && now - m.unlocked_since_ms >= RETUNE_AFTER_MS) {
			retune(&m);
			m.unlocked_since_ms = now_ms();
			continue;
		}
		usleep(REFRESH_MS * 1000);
	}

	if (m.beep)
		tone_stop();
	if (m.tty)
		printf("\033[?25h"); /* show cursor */
	printf("\npeak SNR %.1f dB\n", m.peak_snr);
	return 0;
}
