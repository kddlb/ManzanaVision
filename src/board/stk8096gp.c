// SPDX-License-Identifier: GPL-2.0-only
/*
 * DiBcom STK8096GP reference design: DiB0700 bridge, DiB8000 demod,
 * DiB0090 tuner.
 *
 * The block between the "upstream" markers is copied verbatim from
 * linux drivers/media/usb/dvb-usb/dib0700_devices.c
 *  Copyright (C) 2005-9 DiBcom, SA et al.
 * The stand-ins above it let that code build against the userspace bridge.
 */
#include "stk8096gp.h"

#include "dib0700.h"
#include "dib0090.h"
#include "dib8000.h"

/* dvb-usb stand-ins: just enough structure for the upstream board code */
struct dvb_usb_device {
	struct dib0700 *bridge;
	struct i2c_adapter i2c_adap;
};

struct dvb_usb_fe_adapter {
	struct dvb_frontend *fe;
};

struct dvb_usb_adapter {
	struct dvb_usb_device *dev;
	void *priv;
	struct dvb_usb_fe_adapter fe_adap[1];
};

struct dvb_adapter {
	void *priv;
};

struct dib0700_adapter_state {
	int (*set_param_save) (struct dvb_frontend *);
	struct dib8000_ops dib8000_ops;
};

#define deb_info(args...) printk(args)
#define dvb_attach(FUNCTION, ARGS...) FUNCTION(ARGS)
#define dib0700_set_gpio(dev, gpio, dir, val) dib0700_set_gpio((dev)->bridge, gpio, dir, val)
#define dib0700_ctrl_clock(dev, mhz, gp3) dib0700_ctrl_clock((dev)->bridge, mhz, gp3)

/* ---- upstream: dib0700_devices.c ---- */

static int dib80xx_tuner_reset(struct dvb_frontend *fe, int onoff)
{
	struct dvb_usb_adapter *adap = fe->dvb->priv;
	struct dib0700_adapter_state *state = adap->priv;

	return state->dib8000_ops.set_gpio(fe, 5, 0, !onoff);
}

static int dib80xx_tuner_sleep(struct dvb_frontend *fe, int onoff)
{
	struct dvb_usb_adapter *adap = fe->dvb->priv;
	struct dib0700_adapter_state *state = adap->priv;

	return state->dib8000_ops.set_gpio(fe, 0, 0, onoff);
}


/* STK8096GP */
static struct dibx000_agc_config dib8090_agc_config[2] = {
	{
	.band_caps = BAND_UHF | BAND_VHF | BAND_LBAND | BAND_SBAND,
	/* P_agc_use_sd_mod1=0, P_agc_use_sd_mod2=0, P_agc_freq_pwm_div=1,
	 * P_agc_inv_pwm1=0, P_agc_inv_pwm2=0, P_agc_inh_dc_rv_est=0,
	 * P_agc_time_est=3, P_agc_freeze=0, P_agc_nb_est=5, P_agc_write=0 */
	.setup = (0 << 15) | (0 << 14) | (5 << 11) | (0 << 10) | (0 << 9) | (0 << 8)
	| (3 << 5) | (0 << 4) | (5 << 1) | (0 << 0),

	.inv_gain = 787,
	.time_stabiliz = 10,

	.alpha_level = 0,
	.thlock = 118,

	.wbd_inv = 0,
	.wbd_ref = 3530,
	.wbd_sel = 1,
	.wbd_alpha = 5,

	.agc1_max = 65535,
	.agc1_min = 0,

	.agc2_max = 65535,
	.agc2_min = 0,

	.agc1_pt1 = 0,
	.agc1_pt2 = 32,
	.agc1_pt3 = 114,
	.agc1_slope1 = 143,
	.agc1_slope2 = 144,
	.agc2_pt1 = 114,
	.agc2_pt2 = 227,
	.agc2_slope1 = 116,
	.agc2_slope2 = 117,

	.alpha_mant = 28,
	.alpha_exp = 26,
	.beta_mant = 31,
	.beta_exp = 51,

	.perform_agc_softsplit = 0,
	},
	{
	.band_caps = BAND_CBAND,
	/* P_agc_use_sd_mod1=0, P_agc_use_sd_mod2=0, P_agc_freq_pwm_div=1,
	 * P_agc_inv_pwm1=0, P_agc_inv_pwm2=0, P_agc_inh_dc_rv_est=0,
	 * P_agc_time_est=3, P_agc_freeze=0, P_agc_nb_est=5, P_agc_write=0 */
	.setup = (0 << 15) | (0 << 14) | (5 << 11) | (0 << 10) | (0 << 9) | (0 << 8)
	| (3 << 5) | (0 << 4) | (5 << 1) | (0 << 0),

	.inv_gain = 787,
	.time_stabiliz = 10,

	.alpha_level = 0,
	.thlock = 118,

	.wbd_inv = 0,
	.wbd_ref = 3530,
	.wbd_sel = 1,
	.wbd_alpha = 5,

	.agc1_max = 0,
	.agc1_min = 0,

	.agc2_max = 65535,
	.agc2_min = 0,

	.agc1_pt1 = 0,
	.agc1_pt2 = 32,
	.agc1_pt3 = 114,
	.agc1_slope1 = 143,
	.agc1_slope2 = 144,
	.agc2_pt1 = 114,
	.agc2_pt2 = 227,
	.agc2_slope1 = 116,
	.agc2_slope2 = 117,

	.alpha_mant = 28,
	.alpha_exp = 26,
	.beta_mant = 31,
	.beta_exp = 51,

	.perform_agc_softsplit = 0,
	}
};

static struct dibx000_bandwidth_config dib8090_pll_config_12mhz = {
	.internal = 54000,
	.sampling = 13500,

	.pll_prediv = 1,
	.pll_ratio = 18,
	.pll_range = 3,
	.pll_reset = 1,
	.pll_bypass = 0,

	.enable_refdiv = 0,
	.bypclk_div = 0,
	.IO_CLK_en_core = 1,
	.ADClkSrc = 1,
	.modulo = 2,

	.sad_cfg = (3 << 14) | (1 << 12) | (599 << 0),

	.ifreq = (0 << 25) | 0,
	.timf = 20199727,

	.xtal_hz = 12000000,
};

static int dib8090_get_adc_power(struct dvb_frontend *fe)
{
	struct dvb_usb_adapter *adap = fe->dvb->priv;
	struct dib0700_adapter_state *state = adap->priv;

	return state->dib8000_ops.get_adc_power(fe, 1);
}

static void dib8090_agc_control(struct dvb_frontend *fe, u8 restart)
{
	deb_info("AGC control callback: %i\n", restart);
	dib0090_dcc_freq(fe, restart);

	if (restart == 0) /* before AGC startup */
		dib0090_set_dc_servo(fe, 1);
}

static struct dib8000_config dib809x_dib8000_config[2] = {
	{
	.output_mpeg2_in_188_bytes = 1,

	.agc_config_count = 2,
	.agc = dib8090_agc_config,
	.agc_control = dib8090_agc_control,
	.pll = &dib8090_pll_config_12mhz,
	.tuner_is_baseband = 1,

	.gpio_dir = DIB8000_GPIO_DEFAULT_DIRECTIONS,
	.gpio_val = DIB8000_GPIO_DEFAULT_VALUES,
	.gpio_pwm_pos = DIB8000_GPIO_DEFAULT_PWM_POS,

	.hostbus_diversity = 1,
	.div_cfg = 0x31,
	.output_mode = OUTMODE_MPEG2_FIFO,
	.drives = 0x2d98,
	.diversity_delay = 48,
	.refclksel = 3,
	}, {
	.output_mpeg2_in_188_bytes = 1,

	.agc_config_count = 2,
	.agc = dib8090_agc_config,
	.agc_control = dib8090_agc_control,
	.pll = &dib8090_pll_config_12mhz,
	.tuner_is_baseband = 1,

	.gpio_dir = DIB8000_GPIO_DEFAULT_DIRECTIONS,
	.gpio_val = DIB8000_GPIO_DEFAULT_VALUES,
	.gpio_pwm_pos = DIB8000_GPIO_DEFAULT_PWM_POS,

	.hostbus_diversity = 1,
	.div_cfg = 0x31,
	.output_mode = OUTMODE_DIVERSITY,
	.drives = 0x2d08,
	.diversity_delay = 1,
	.refclksel = 3,
	}
};

static struct dib0090_wbd_slope dib8090_wbd_table[] = {
	/* max freq ; cold slope ; cold offset ; warm slope ; warm offset ; wbd gain */
	{ 120,     0, 500,  0,   500, 4 }, /* CBAND */
	{ 170,     0, 450,  0,   450, 4 }, /* CBAND */
	{ 380,    48, 373, 28,   259, 6 }, /* VHF */
	{ 860,    34, 700, 36,   616, 6 }, /* high UHF */
	{ 0xFFFF, 34, 700, 36,   616, 6 }, /* default */
};

static struct dib0090_config dib809x_dib0090_config = {
	.io.pll_bypass = 1,
	.io.pll_range = 1,
	.io.pll_prediv = 1,
	.io.pll_loopdiv = 20,
	.io.adc_clock_ratio = 8,
	.io.pll_int_loop_filt = 0,
	.io.clock_khz = 12000,
	.reset = dib80xx_tuner_reset,
	.sleep = dib80xx_tuner_sleep,
	.clkouttobamse = 1,
	.analog_output = 1,
	.i2c_address = DEFAULT_DIB0090_I2C_ADDRESS,
	.use_pwm_agc = 1,
	.clkoutdrive = 1,
	.get_adc_power = dib8090_get_adc_power,
	.freq_offset_khz_uhf = -63,
	.freq_offset_khz_vhf = -143,
	.wbd = dib8090_wbd_table,
	.fref_clock_ratio = 6,
};

static u8 dib8090_compute_pll_parameters(struct dvb_frontend *fe)
{
	u8 optimal_pll_ratio = 20;
	u32 freq_adc, ratio, rest, max = 0;
	u8 pll_ratio;

	for (pll_ratio = 17; pll_ratio <= 20; pll_ratio++) {
		freq_adc = 12 * pll_ratio * (1 << 8) / 16;
		ratio = ((fe->dtv_property_cache.frequency / 1000) * (1 << 8) / 1000) / freq_adc;
		rest = ((fe->dtv_property_cache.frequency / 1000) * (1 << 8) / 1000) - ratio * freq_adc;

		if (rest > freq_adc / 2)
			rest = freq_adc - rest;
		deb_info("PLL ratio=%i rest=%i\n", pll_ratio, rest);
		if ((rest > max) && (rest > 717)) {
			optimal_pll_ratio = pll_ratio;
			max = rest;
		}
	}
	deb_info("optimal PLL ratio=%i\n", optimal_pll_ratio);

	return optimal_pll_ratio;
}

static int dib8096_set_param_override(struct dvb_frontend *fe)
{
	struct dvb_usb_adapter *adap = fe->dvb->priv;
	struct dib0700_adapter_state *state = adap->priv;
	u8 pll_ratio, band = BAND_OF_FREQUENCY(fe->dtv_property_cache.frequency / 1000);
	u16 target, ltgain, rf_gain_limit;
	u32 timf;
	int ret = 0;
	enum frontend_tune_state tune_state = CT_SHUTDOWN;

	switch (band) {
	default:
		deb_info("Warning : Rf frequency  (%iHz) is not in the supported range, using VHF switch ", fe->dtv_property_cache.frequency);
		fallthrough;
	case BAND_VHF:
		state->dib8000_ops.set_gpio(fe, 3, 0, 1);
		break;
	case BAND_UHF:
		state->dib8000_ops.set_gpio(fe, 3, 0, 0);
		break;
	}

	ret = state->set_param_save(fe);
	if (ret < 0)
		return ret;

	if (fe->dtv_property_cache.bandwidth_hz != 6000000) {
		deb_info("only 6MHz bandwidth is supported\n");
		return -EINVAL;
	}

	/* Update PLL if needed ratio */
	state->dib8000_ops.update_pll(fe, &dib8090_pll_config_12mhz, fe->dtv_property_cache.bandwidth_hz / 1000, 0);

	/* Get optimize PLL ratio to remove spurious */
	pll_ratio = dib8090_compute_pll_parameters(fe);
	if (pll_ratio == 17)
		timf = 21387946;
	else if (pll_ratio == 18)
		timf = 20199727;
	else if (pll_ratio == 19)
		timf = 19136583;
	else
		timf = 18179756;

	/* Update ratio */
	state->dib8000_ops.update_pll(fe, &dib8090_pll_config_12mhz, fe->dtv_property_cache.bandwidth_hz / 1000, pll_ratio);

	state->dib8000_ops.ctrl_timf(fe, DEMOD_TIMF_SET, timf);

	if (band != BAND_CBAND) {
		/* dib0090_get_wbd_target is returning any possible temperature compensated wbd-target */
		target = (dib0090_get_wbd_target(fe) * 8 * 18 / 33 + 1) / 2;
		state->dib8000_ops.set_wbd_ref(fe, target);
	}

	if (band == BAND_CBAND) {
		deb_info("tuning in CBAND - soft-AGC startup\n");
		dib0090_set_tune_state(fe, CT_AGC_START);

		do {
			ret = dib0090_gain_control(fe);
			msleep(ret);
			tune_state = dib0090_get_tune_state(fe);
			if (tune_state == CT_AGC_STEP_0)
				state->dib8000_ops.set_gpio(fe, 6, 0, 1);
			else if (tune_state == CT_AGC_STEP_1) {
				dib0090_get_current_gain(fe, NULL, NULL, &rf_gain_limit, &ltgain);
				if (rf_gain_limit < 2000) /* activate the external attenuator in case of very high input power */
					state->dib8000_ops.set_gpio(fe, 6, 0, 0);
			}
		} while (tune_state < CT_AGC_STOP);

		deb_info("switching to PWM AGC\n");
		dib0090_pwm_gain_reset(fe);
		state->dib8000_ops.pwm_agc_reset(fe);
		state->dib8000_ops.set_tune_state(fe, CT_DEMOD_START);
	} else {
		/* for everything else than CBAND we are using standard AGC */
		deb_info("not tuning in CBAND - standard AGC startup\n");
		dib0090_pwm_gain_reset(fe);
	}

	return 0;
}

static int dib809x_tuner_attach(struct dvb_usb_adapter *adap)
{
	struct dib0700_adapter_state *st = adap->priv;
	struct i2c_adapter *tun_i2c = st->dib8000_ops.get_i2c_master(adap->fe_adap[0].fe, DIBX000_I2C_INTERFACE_TUNER, 1);

	/* FIXME: if adap->id != 0, check if it is fe_adap[1] */
	if (!dvb_attach(dib0090_register, adap->fe_adap[0].fe, tun_i2c, &dib809x_dib0090_config))
		return -ENODEV;

	st->set_param_save = adap->fe_adap[0].fe->ops.tuner_ops.set_params;
	adap->fe_adap[0].fe->ops.tuner_ops.set_params = dib8096_set_param_override;
	return 0;
}

static int stk809x_frontend_attach(struct dvb_usb_adapter *adap)
{
	struct dib0700_adapter_state *state = adap->priv;

	if (!dvb_attach(dib8000_attach, &state->dib8000_ops))
		return -ENODEV;

	dib0700_set_gpio(adap->dev, GPIO6, GPIO_OUT, 1);
	msleep(10);
	dib0700_set_gpio(adap->dev, GPIO9, GPIO_OUT, 1);
	dib0700_set_gpio(adap->dev, GPIO4, GPIO_OUT, 1);
	dib0700_set_gpio(adap->dev, GPIO7, GPIO_OUT, 1);

	dib0700_set_gpio(adap->dev, GPIO10, GPIO_OUT, 0);

	dib0700_ctrl_clock(adap->dev, 72, 1);

	msleep(10);
	dib0700_set_gpio(adap->dev, GPIO10, GPIO_OUT, 1);
	msleep(10);
	dib0700_set_gpio(adap->dev, GPIO0, GPIO_OUT, 1);

	state->dib8000_ops.i2c_enumeration(&adap->dev->i2c_adap, 1, 18, 0x80, 0);

	adap->fe_adap[0].fe = state->dib8000_ops.init(&adap->dev->i2c_adap, 0x80, &dib809x_dib8000_config[0]);

	return adap->fe_adap[0].fe == NULL ?  -ENODEV : 0;
}

/* ---- end upstream ---- */

#undef dib0700_set_gpio
#undef dib0700_ctrl_clock

static struct {
	struct dvb_usb_device dev;
	struct dvb_usb_adapter adap;
	struct dvb_adapter dvb;
	struct dib0700_adapter_state state;
	struct dvb_frontend *fe;
	u16 revision;
} board;

/* the demod answers at 0x80 (8-bit) once enumeration has moved it there */
static u16 demod_read16(u16 reg)
{
	u8 wb[2] = { reg >> 8, reg & 0xff }, rb[2] = { 0, 0 };
	struct i2c_msg msg[2] = {
		{ .addr = 0x80 >> 1, .flags = 0, .buf = wb, .len = 2 },
		{ .addr = 0x80 >> 1, .flags = I2C_M_RD, .buf = rb, .len = 2 },
	};

	if (i2c_transfer(&board.dev.i2c_adap, msg, 2) != 2)
		return 0;
	return (rb[0] << 8) | rb[1];
}

int stk_open(struct dib0700 *bridge)
{
	int ret;

	memset(&board, 0, sizeof(board));
	board.dev.bridge = bridge;
	board.dev.i2c_adap = *dib0700_i2c_adapter(bridge);
	board.adap.dev = &board.dev;
	board.adap.priv = &board.state;
	board.dvb.priv = &board.adap;

	ret = stk809x_frontend_attach(&board.adap);
	if (ret < 0) {
		kcompat_log(KC_LOG_ERROR, "DiB8000 demod not found\n");
		return ret;
	}
	board.fe = board.adap.fe_adap[0].fe;
	board.fe->dvb = &board.dvb;
	board.revision = demod_read16(897);

	ret = dib809x_tuner_attach(&board.adap);
	if (ret < 0) {
		kcompat_log(KC_LOG_ERROR, "DiB0090 tuner not found\n");
		return ret;
	}

	/* what dvb_frontend_init() does when the device node is opened */
	if (board.fe->ops.init)
		board.fe->ops.init(board.fe);
	if (board.fe->ops.tuner_ops.init)
		board.fe->ops.tuner_ops.init(board.fe);
	return 0;
}

void stk_close(void)
{
	if (!board.fe)
		return;
	if (board.fe->ops.sleep)
		board.fe->ops.sleep(board.fe);
	if (board.fe->ops.tuner_ops.release)
		board.fe->ops.tuner_ops.release(board.fe);
	if (board.fe->ops.release)
		board.fe->ops.release(board.fe);
	board.fe = NULL;
}

u16 stk_demod_revision(void)
{
	return board.revision;
}

/* dvb_frontend_clear_cache() defaults for ISDB-T, as dvbv5-scan leaves them */
static void clear_cache(struct dtv_frontend_properties *c)
{
	int i;

	memset(c, 0, offsetof(struct dtv_frontend_properties, strength));
	c->delivery_system = SYS_ISDBT;
	c->transmission_mode = TRANSMISSION_MODE_AUTO;
	c->guard_interval = GUARD_INTERVAL_AUTO;
	c->hierarchy = HIERARCHY_AUTO;
	c->code_rate_HP = FEC_AUTO;
	c->code_rate_LP = FEC_AUTO;
	c->fec_inner = FEC_AUTO;
	c->inversion = INVERSION_AUTO;
	c->isdbt_layer_enabled = 7;
	for (i = 0; i < 3; i++) {
		c->layer[i].fec = FEC_AUTO;
		c->layer[i].modulation = QAM_AUTO;
	}
}

enum fe_status stk_tune(u32 freq_hz)
{
	struct dtv_frontend_properties *c = &board.fe->dtv_property_cache;

	clear_cache(c);
	c->frequency = freq_hz;
	c->bandwidth_hz = 6000000;

	board.fe->ops.set_frontend(board.fe);
	return stk_read_status();
}

enum fe_status stk_read_status(void)
{
	enum fe_status status = 0;

	board.fe->ops.read_status(board.fe, &status);
	return status;
}

u8 stk_layer_lock(void)
{
	/* reg 568 bits 7/6/5 = layer A/B/C MPEG lock (see dib8000_tune) */
	u16 lock = demod_read16(568);

	return ((lock >> 7) & 1) | (((lock >> 6) & 1) << 1) | (((lock >> 5) & 1) << 2);
}

u16 stk_read_ucb(void)
{
	/* same register dib8000_read_unc_blocks uses for rev < 0x8090 */
	return demod_read16(565);
}

void stk_read_signal(u16 *strength, u16 *snr)
{
	*strength = 0;
	*snr = 0;
	board.fe->ops.read_signal_strength(board.fe, strength);
	board.fe->ops.read_snr(board.fe, snr);
}

int stk_get_tmcc(struct dtv_frontend_properties *out)
{
	int ret = board.fe->ops.get_frontend(board.fe, &board.fe->dtv_property_cache);

	*out = board.fe->dtv_property_cache;
	return ret;
}
