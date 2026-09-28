/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef METER_H
#define METER_H

#include <stdbool.h>

struct dib0700;

/*
 * Stays tuned to one channel and redraws SNR, level, error rate and
 * per-layer lock until interrupted. With beep, plays a finder tone whose
 * pitch follows SNR: steady at full lock, pulsed at partial lock.
 */
int meter_run(struct dib0700 *d, int rf, bool beep);

#endif
