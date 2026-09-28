/* SPDX-License-Identifier: GPL-2.0-only */
/* DiBcom STK8096GP reference board: DiB0700 bridge + DiB8000 + DiB0090 */
#ifndef STK8096GP_H
#define STK8096GP_H

#include <media/dvb_frontend.h>

struct dib0700;

/* Brings up the demod and tuner behind an opened bridge */
int stk_open(struct dib0700 *bridge);
void stk_close(void);

/* demod chip revision read at attach time (0x8000..0x8002) */
u16 stk_demod_revision(void);

/*
 * Tunes to an ISDB-T 6 MHz channel with every transmission parameter on
 * AUTO. Blocks until the demod locks or gives up, and returns the fe_status
 * bits read afterwards.
 */
enum fe_status stk_tune(u32 freq_hz);

enum fe_status stk_read_status(void);

/* MPEG lock per ISDB-T layer: bit0 = A, bit1 = B, bit2 = C */
u8 stk_layer_lock(void);

/* Signal strength (0..65535) and SNR in 0.1 dB, as reported by the demod */
void stk_read_signal(u16 *strength, u16 *snr);

/* TMCC parameters decoded by the demod after a lock */
int stk_get_tmcc(struct dtv_frontend_properties *out);

#endif
