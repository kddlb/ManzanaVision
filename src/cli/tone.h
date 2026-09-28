/* SPDX-License-Identifier: GPL-2.0-only */
/* Continuous sine tone for the signal meter, like a satellite box's finder */
#ifndef TONE_H
#define TONE_H

enum tone_mode {
	TONE_SILENT,
	TONE_PULSED,	/* short beeps: partial lock */
	TONE_STEADY,	/* continuous: full lock */
};

/* Opens the default output device; returns 0 on success */
int tone_start(void);
void tone_stop(void);

/* Sets the target pitch and pattern; the pitch glides there smoothly */
void tone_set(double hz, enum tone_mode mode);

#endif
