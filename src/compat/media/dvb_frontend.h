/* SPDX-License-Identifier: LGPL-2.1+ */
/*
 * Trimmed copy of include/media/dvb_frontend.h: only the structures the
 * vendored DiBcom drivers touch, without the dvb-core machinery.
 */
#ifndef _DVB_FRONTEND_H_
#define _DVB_FRONTEND_H_

#include "../kcompat.h"
#include <linux/i2c.h>
#include <linux/dvb/frontend.h>

#define MAX_DELSYS	8

/* Helper definitions to be used at frontend drivers */
#define kHz 1000UL
#define MHz 1000000UL

/**
 * struct dvb_frontend_tune_settings - parameters to adjust frontend tuning
 *
 * @min_delay_ms:	minimum delay for tuning, in ms
 * @step_size:		step size between two consecutive frequencies
 * @max_drift:		maximum drift
 *
 * NOTE: step_size is in Hz, for terrestrial/cable or kHz for satellite
 */
struct dvb_frontend_tune_settings {
	int min_delay_ms;
	int step_size;
	int max_drift;
};

struct dvb_frontend;
struct dtv_frontend_properties;

enum dvbfe_algo {
	DVBFE_ALGO_HW			= BIT(0),
	DVBFE_ALGO_SW			= BIT(1),
	DVBFE_ALGO_CUSTOM		= BIT(2),
	DVBFE_ALGO_RECOVERY		= BIT(31),
};

enum dvbfe_search {
	DVBFE_ALGO_SEARCH_SUCCESS	= BIT(0),
	DVBFE_ALGO_SEARCH_ASLEEP	= BIT(1),
	DVBFE_ALGO_SEARCH_FAILED	= BIT(2),
	DVBFE_ALGO_SEARCH_INVALID	= BIT(3),
	DVBFE_ALGO_SEARCH_AGAIN		= BIT(4),
	DVBFE_ALGO_SEARCH_ERROR		= BIT(31),
};


/**
 * struct dvb_tuner_info - Frontend name and min/max ranges/bandwidths
 *
 * @name:		name of the Frontend
 * @frequency_min_hz:	minimal frequency supported in Hz
 * @frequency_max_hz:	maximum frequency supported in Hz
 * @frequency_step_hz:	frequency step in Hz
 * @bandwidth_min:	minimal frontend bandwidth supported
 * @bandwidth_max:	maximum frontend bandwidth supported
 * @bandwidth_step:	frontend bandwidth step
 */
struct dvb_tuner_info {
	char name[128];

	u32 frequency_min_hz;
	u32 frequency_max_hz;
	u32 frequency_step_hz;

	u32 bandwidth_min;
	u32 bandwidth_max;
	u32 bandwidth_step;
};

struct dvb_tuner_ops {

	struct dvb_tuner_info info;

	void (*release)(struct dvb_frontend *fe);
	int (*init)(struct dvb_frontend *fe);
	int (*sleep)(struct dvb_frontend *fe);
	int (*suspend)(struct dvb_frontend *fe);
	int (*resume)(struct dvb_frontend *fe);

	/* This is the recommended way to set the tuner */
	int (*set_params)(struct dvb_frontend *fe);

	int (*set_config)(struct dvb_frontend *fe, void *priv_cfg);

	int (*get_frequency)(struct dvb_frontend *fe, u32 *frequency);
	int (*get_bandwidth)(struct dvb_frontend *fe, u32 *bandwidth);
	int (*get_if_frequency)(struct dvb_frontend *fe, u32 *frequency);

#define TUNER_STATUS_LOCKED 1
#define TUNER_STATUS_STEREO 2
	int (*get_status)(struct dvb_frontend *fe, u32 *status);
	int (*get_rf_strength)(struct dvb_frontend *fe, u16 *strength);
	int (*get_afc)(struct dvb_frontend *fe, s32 *afc);

	/*
	 * This is support for demods like the mt352 - fills out the supplied
	 * buffer with what to write.
	 *
	 * Don't use on newer drivers.
	 */
	int (*calc_regs)(struct dvb_frontend *fe, u8 *buf, int buf_len);

	/*
	 * These are provided separately from set_params in order to
	 * facilitate silicon tuners which require sophisticated tuning loops,
	 * controlling each parameter separately.
	 *
	 * Don't use on newer drivers.
	 */
	int (*set_frequency)(struct dvb_frontend *fe, u32 frequency);
	int (*set_bandwidth)(struct dvb_frontend *fe, u32 bandwidth);
};

struct dvb_frontend_internal_info {
	char	name[128];
	u32	frequency_min_hz;
	u32	frequency_max_hz;
	u32	frequency_stepsize_hz;
	u32	frequency_tolerance_hz;
	u32	symbol_rate_min;
	u32	symbol_rate_max;
	u32	symbol_rate_tolerance;
	enum fe_caps caps;
};

struct dvb_frontend_ops {
	struct dvb_frontend_internal_info info;

	u8 delsys[MAX_DELSYS];

	void (*detach)(struct dvb_frontend *fe);
	void (*release)(struct dvb_frontend* fe);
	void (*release_sec)(struct dvb_frontend* fe);

	int (*init)(struct dvb_frontend* fe);
	int (*sleep)(struct dvb_frontend* fe);
	int (*suspend)(struct dvb_frontend *fe);
	int (*resume)(struct dvb_frontend *fe);

	int (*write)(struct dvb_frontend* fe, const u8 buf[], int len);

	/* if this is set, it overrides the default swzigzag */
	int (*tune)(struct dvb_frontend* fe,
		    bool re_tune,
		    unsigned int mode_flags,
		    unsigned int *delay,
		    enum fe_status *status);

	/* get frontend tuning algorithm from the module */
	enum dvbfe_algo (*get_frontend_algo)(struct dvb_frontend *fe);

	/* these two are only used for the swzigzag code */
	int (*set_frontend)(struct dvb_frontend *fe);
	int (*get_tune_settings)(struct dvb_frontend* fe, struct dvb_frontend_tune_settings* settings);

	int (*get_frontend)(struct dvb_frontend *fe,
			    struct dtv_frontend_properties *props);

	int (*read_status)(struct dvb_frontend *fe, enum fe_status *status);
	int (*read_ber)(struct dvb_frontend* fe, u32* ber);
	int (*read_signal_strength)(struct dvb_frontend* fe, u16* strength);
	int (*read_snr)(struct dvb_frontend* fe, u16* snr);
	int (*read_ucblocks)(struct dvb_frontend* fe, u32* ucblocks);

	int (*i2c_gate_ctrl)(struct dvb_frontend* fe, int enable);
	int (*ts_bus_ctrl)(struct dvb_frontend* fe, int acquire);
	int (*set_lna)(struct dvb_frontend *);

	/*
	 * These callbacks are for devices that implement their own
	 * tuning algorithms, rather than a simple swzigzag
	 */
	enum dvbfe_search (*search)(struct dvb_frontend *fe);

	struct dvb_tuner_ops tuner_ops;
};

struct dtv_frontend_properties {
	u32			frequency;
	enum fe_modulation	modulation;

	enum fe_sec_voltage	voltage;
	enum fe_sec_tone_mode	sectone;
	enum fe_spectral_inversion inversion;
	enum fe_code_rate	fec_inner;
	enum fe_transmit_mode	transmission_mode;
	u32			bandwidth_hz;	/* 0 = AUTO */
	enum fe_guard_interval	guard_interval;
	enum fe_hierarchy	hierarchy;
	u32			symbol_rate;
	enum fe_code_rate	code_rate_HP;
	enum fe_code_rate	code_rate_LP;

	enum fe_pilot		pilot;
	enum fe_rolloff		rolloff;

	enum fe_delivery_system	delivery_system;

	enum fe_interleaving	interleaving;

	/* ISDB-T specifics */
	u8			isdbt_partial_reception;
	u8			isdbt_sb_mode;
	u8			isdbt_sb_subchannel;
	u32			isdbt_sb_segment_idx;
	u32			isdbt_sb_segment_count;
	u8			isdbt_layer_enabled;
	struct {
	    u8			segment_count;
	    enum fe_code_rate	fec;
	    enum fe_modulation	modulation;
	    u8			interleaving;
	} layer[3];

	/* Multistream specifics */
	u32			stream_id;

	/* Physical Layer Scrambling specifics */
	u32			scrambling_sequence_index;

	/* ATSC-MH specifics */
	u8			atscmh_fic_ver;
	u8			atscmh_parade_id;
	u8			atscmh_nog;
	u8			atscmh_tnog;
	u8			atscmh_sgn;
	u8			atscmh_prc;

	u8			atscmh_rs_frame_mode;
	u8			atscmh_rs_frame_ensemble;
	u8			atscmh_rs_code_mode_pri;
	u8			atscmh_rs_code_mode_sec;
	u8			atscmh_sccc_block_mode;
	u8			atscmh_sccc_code_mode_a;
	u8			atscmh_sccc_code_mode_b;
	u8			atscmh_sccc_code_mode_c;
	u8			atscmh_sccc_code_mode_d;

	u32			lna;

	/* statistics data */
	struct dtv_fe_stats	strength;
	struct dtv_fe_stats	cnr;
	struct dtv_fe_stats	pre_bit_error;
	struct dtv_fe_stats	pre_bit_count;
	struct dtv_fe_stats	post_bit_error;
	struct dtv_fe_stats	post_bit_count;
	struct dtv_fe_stats	block_error;
	struct dtv_fe_stats	block_count;
};

struct dvb_adapter;

struct dvb_frontend {
	struct dvb_frontend_ops ops;
	struct dvb_adapter *dvb;
	void *demodulator_priv;
	void *tuner_priv;
	void *frontend_priv;
	struct dtv_frontend_properties dtv_property_cache;
	int (*callback)(void *adapter_priv, int component, int cmd, int arg);
	int id;
	unsigned int exit;
};

static inline void dvb_frontend_detach(struct dvb_frontend *fe) { (void)fe; }

#endif
