// SPDX-License-Identifier: GPL-2.0-only
/*
 * Live signal meter: stay on one channel and refresh SNR, level, error rate
 * and per-layer lock a few times a second, for aiming an antenna.
 */
#include "meter.h"

#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "scan.h"
#include "stk8096gp.h"
#include "tone.h"

#define REFRESH_MS 250
#define RETUNE_AFTER_MS 2000
#define SNR_FULL_SCALE 30.0	/* dB at a full bar */
#define BAR_WIDTH 30
#define TONE_LOW_HZ 300.0	/* pitch at 0 dB SNR */
#define TONE_HIGH_HZ 1500.0	/* pitch at SNR_FULL_SCALE */

struct meter_state {
	int rf;
	u32 freq;
	bool tty;
	bool beep;

	struct dtv_frontend_properties tmcc;
	bool have_tmcc;
	u8 layers_enabled;	/* bit per layer with segments */

	unsigned long start_ms;
	unsigned long locked_since_ms;	/* 0 while unlocked */
	unsigned long unlocked_since_ms;

	double peak_snr;
	u16 last_ucb;
	bool have_ucb;
	double ucb_rate;	/* errored packets per second, smoothed */
	unsigned long last_sample_ms;

	int lines_drawn;
};

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
	stk_tune(m->freq);
	m->have_tmcc = false;
	m->layers_enabled = 0;
	m->have_ucb = false;
	m->ucb_rate = 0;
}

static void refresh_tmcc(struct meter_state *m)
{
	if (m->have_tmcc || stk_get_tmcc(&m->tmcc) != 0)
		return;
	m->layers_enabled = 0;
	for (int l = 0; l < 3; l++)
		if (m->tmcc.layer[l].segment_count)
			m->layers_enabled |= 1 << l;
	m->have_tmcc = m->layers_enabled != 0;
}

/* Draws the full-screen view; moves the cursor back over the previous frame */
static void draw_tty(struct meter_state *m, enum fe_status status, double snr, int level, u8 layer_lock,
		     unsigned long now)
{
	char b[BAR_WIDTH * 4 + 1], dur[16];
	bool locked = status & FE_HAS_LOCK;
	int lines = 0;

	if (m->lines_drawn)
		printf("\033[%dA", m->lines_drawn);

	if (locked)
		fmt_duration(now - m->locked_since_ms, dur, sizeof(dur));
	printf("\033[2KRF %d  %.3f MHz   %s%s%s   (Ctrl-C to stop)\n", m->rf, m->freq / 1e6,
	       locked ? "\033[32mLOCKED\033[0m " : (status & FE_HAS_SIGNAL) ? "\033[33msearching\033[0m" : "\033[31mno signal\033[0m",
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
			const struct dtv_frontend_properties *c = &m->tmcc;
			bool ok = (layer_lock >> l) & 1;

			if (!(m->layers_enabled & (1 << l)))
				continue;
			printf("\033[2K Layer %c  %2d seg  %-5s %-3s   %s\n", 'A' + l, c->layer[l].segment_count,
			       isdbt_mod_name(c->layer[l].modulation), isdbt_fec_name(c->layer[l].fec),
			       ok ? "\033[32mok\033[0m" : "\033[31mNO LOCK\033[0m");
			lines++;
		}
	} else {
		printf("\033[2K Layers  (waiting for TMCC)\n");
		lines++;
	}

	if (locked && m->have_ucb)
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
static void draw_line(struct meter_state *m, enum fe_status status, double snr, int level, u8 layer_lock,
		      unsigned long now)
{
	printf("%6.1fs  RF %d  %-9s  SNR %5.1f dB  level %3d%%", (now - m->start_ms) / 1000.0, m->rf,
	       (status & FE_HAS_LOCK) ? "LOCKED" : (status & FE_HAS_SIGNAL) ? "searching" : "no signal",
	       snr, level);
	for (int l = 0; l < 3; l++)
		if (m->layers_enabled & (1 << l))
			printf("  %c:%s", 'A' + l, (layer_lock >> l) & 1 ? "ok" : "--");
	if ((status & FE_HAS_LOCK) && m->have_ucb)
		printf("  err %.0f/s", m->ucb_rate);
	printf("\n");
	fflush(stdout);
}

int meter_run(struct dib0700 *d, int rf, bool beep)
{
	struct meter_state m = {
		.rf = rf,
		.freq = isdbt_channel_freq(rf),
		.tty = isatty(STDOUT_FILENO),
		.beep = beep,
	};
	unsigned long last_line_ms = 0;

	(void)d;
	m.start_ms = jiffies;
	if (m.beep && tone_start() < 0)
		m.beep = false;
	if (m.tty)
		printf("\033[?25l"); /* hide cursor */
	printf("tuning RF %d...\n", rf);
	fflush(stdout);
	if (m.tty)
		printf("\033[1A");
	retune(&m);
	m.unlocked_since_ms = jiffies;

	while (!scan_interrupted()) {
		unsigned long now = jiffies;
		enum fe_status status = stk_read_status();
		bool locked = status & FE_HAS_LOCK;
		u16 strength, snr10;
		u8 layer_lock = 0;
		double snr;
		int level;

		stk_read_signal(&strength, &snr10);
		snr = snr10 / 10.0;
		level = strength * 100 / 65535;

		if (locked) {
			bool fully;

			if (!m.locked_since_ms)
				m.locked_since_ms = now;
			m.unlocked_since_ms = 0;
			refresh_tmcc(&m);
			layer_lock = stk_layer_lock();
			if (snr > m.peak_snr)
				m.peak_snr = snr;

			/*
			 * The uncorrectable-packet count is windowed: it climbs
			 * during a measurement period, then restarts. A drop means
			 * a new window, whose errors so far are the new value.
			 */
			u16 ucb = stk_read_ucb();

			if (m.have_ucb && now > m.last_sample_ms) {
				u16 delta = ucb >= m.last_ucb ? ucb - m.last_ucb : ucb;
				double rate = delta * 1000.0 / (now - m.last_sample_ms);

				m.ucb_rate = m.ucb_rate * 0.6 + rate * 0.4;
			}
			m.last_ucb = ucb;
			m.have_ucb = true;
			m.last_sample_ms = now;

			fully = m.have_tmcc && (layer_lock & m.layers_enabled) == m.layers_enabled;
			if (m.beep)
				tone_set(snr_to_hz(snr), fully ? TONE_STEADY : TONE_PULSED);
		} else {
			if (m.beep)
				tone_set(TONE_LOW_HZ, TONE_SILENT);
			m.locked_since_ms = 0;
			m.have_ucb = false;
			if (!m.unlocked_since_ms)
				m.unlocked_since_ms = now;
		}

		if (m.tty) {
			draw_tty(&m, status, snr, level, layer_lock, now);
		} else if (now - last_line_ms >= 1000) {
			draw_line(&m, status, snr, level, layer_lock, now);
			last_line_ms = now;
		}

		/* the demod doesn't re-acquire by itself once it has lost lock */
		if (!locked && now - m.unlocked_since_ms >= RETUNE_AFTER_MS) {
			retune(&m);
			m.unlocked_since_ms = jiffies;
			continue;
		}
		msleep(REFRESH_MS);
	}

	if (m.beep)
		tone_stop();
	if (m.tty)
		printf("\033[?25h"); /* show cursor */
	printf("\npeak SNR %.1f dB\n", m.peak_snr);
	return 0;
}
