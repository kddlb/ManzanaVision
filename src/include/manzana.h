/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Public C API of the ManzanaVision core: what the CLI and the Mac app
 * build on. Everything else under src/ is private to the core.
 *
 * Threading: the core drives one USB stick through global state, so all
 * calls on an mzv_device must come from one thread. The only exception is
 * mzv_cancel(), which is safe from any thread or a signal handler.
 */
#ifndef MANZANA_H
#define MANZANA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Version of the core library, e.g. "0.1.0" */
const char *mzv_version(void);

/* ---- errors and logging ---------------------------------------------- */

enum mzv_error {
	MZV_OK = 0,
	MZV_ERR_NO_DEVICE = -1,		/* no STK8096GP connected */
	MZV_ERR_BUSY = -2,		/* already open here, or claimed by another process */
	MZV_ERR_FIRMWARE = -3,		/* firmware missing, unreadable or rejected */
	MZV_ERR_IO = -4,		/* USB/I2C failure */
	MZV_ERR_NO_FRONTEND = -5,	/* demod or tuner didn't answer */
	MZV_ERR_CANCELLED = -6,
	MZV_ERR_NO_LOCK = -7,
	MZV_ERR_GONE = -8,		/* device unplugged */
	MZV_ERR_INVALID = -9,
};

const char *mzv_strerror(int err);

enum mzv_log_level {
	MZV_LOG_ERROR,
	MZV_LOG_WARN,
	MZV_LOG_INFO,
	MZV_LOG_DEBUG,	/* driver internals, shown with -v */
	MZV_LOG_TRACE,	/* I2C traffic, shown with -vv */
};

/* msg is one formatted message, usually ending in '\n' */
typedef void (*mzv_log_fn)(enum mzv_log_level level, const char *msg, void *ctx);

/* Routes all core output to fn; NULL restores the default (stderr) */
void mzv_set_log(mzv_log_fn fn, void *ctx);

/* 0 = errors/warnings/info only, 1 = + driver debug, 2 = + I2C trace */
void mzv_set_debug(int level);

/* ---- device ----------------------------------------------------------- */

typedef struct mzv_device mzv_device;

/*
 * Opens the stick, uploading firmware_path if it's cold, and brings up the
 * demod and tuner. Only one device can be open per process.
 */
int mzv_open(const char *firmware_path, mzv_device **out);
void mzv_close(mzv_device *dev);

struct mzv_device_info {
	uint32_t firmware_version;	/* e.g. 0x10200 */
	bool firmware_uploaded;		/* the stick was cold and got firmware now */
	uint16_t demod_revision;	/* 0x8002 = DiB8000C */
};

void mzv_get_info(const mzv_device *dev, struct mzv_device_info *info);

/*
 * Makes the current and any later blocking call return MZV_ERR_CANCELLED
 * (or finish mzv_stream) as soon as possible, until mzv_reset_cancel().
 * Thread- and async-signal-safe.
 */
void mzv_cancel(mzv_device *dev);
void mzv_reset_cancel(mzv_device *dev);
bool mzv_is_cancelled(const mzv_device *dev);

/* ---- tuning and signal ------------------------------------------------ */

#define MZV_RF_MIN 14
#define MZV_RF_MAX 69

/* Centre frequency of ISDB-T (ABNT/Chile) UHF channel rf, in Hz */
uint32_t mzv_rf_frequency(int rf);

struct mzv_signal {
	uint8_t status;		/* raw fe_status bits (bit0 SIGNAL .. bit4 LOCK) */
	bool has_signal;
	bool has_lock;
	uint8_t layer_lock;	/* MPEG lock per layer: bit0 = A, bit1 = B, bit2 = C */
	uint16_t strength;	/* 0..65535, AGC-derived */
	int strength_pct;
	uint16_t snr_tenths;	/* SNR in 0.1 dB */
	double snr_db;
	double errors_per_s;	/* uncorrectable TS packets/s, smoothed; 0 when unknown */
};

enum mzv_modulation { MZV_MOD_UNKNOWN, MZV_MOD_QPSK, MZV_MOD_DQPSK, MZV_MOD_QAM16, MZV_MOD_QAM64 };
enum mzv_code_rate { MZV_FEC_UNKNOWN, MZV_FEC_1_2, MZV_FEC_2_3, MZV_FEC_3_4, MZV_FEC_5_6, MZV_FEC_7_8 };

struct mzv_layer {
	int segments;		/* 0 = layer not used */
	enum mzv_modulation modulation;
	enum mzv_code_rate fec;
	int interleaving;
};

struct mzv_tmcc {
	int mode;		/* ISDB-T mode 1/2/3 (2k/4k/8k), 0 unknown */
	int guard_interval;	/* denominator: 4, 8, 16 or 32; 0 unknown */
	struct mzv_layer layer[3];
};

const char *mzv_modulation_name(enum mzv_modulation m);
const char *mzv_code_rate_name(enum mzv_code_rate f);
const char *mzv_guard_interval_name(int denominator);

/* Tunes rf with all transmission parameters on AUTO; blocks until lock or give-up */
int mzv_tune(mzv_device *dev, int rf, struct mzv_signal *signal);
int mzv_read_signal(mzv_device *dev, struct mzv_signal *signal);
/* TMCC after a lock; MZV_ERR_NO_LOCK if the demod hasn't synced */
int mzv_read_tmcc(mzv_device *dev, struct mzv_tmcc *tmcc);

/* ---- scanning (PSI) ---------------------------------------------------- */

#define MZV_MAX_SERVICES 32

struct mzv_service {
	uint16_t service_id;
	uint16_t pmt_pid;	/* 0 if not in the PAT */
	uint8_t service_type;	/* SDT service_type */
	bool in_pat, in_sdt;
	bool listed;		/* shown to users: in the PAT, or in the SDT when there's no PAT */
	int major, minor;	/* virtual channel, e.g. 9.31 */
	char kind[8];		/* "TV", "1seg", "radio", "data", "other" */
	char name[64];		/* UTF-8 */
	char provider[64];
};

struct mzv_mux {
	int rf;
	uint32_t frequency;
	struct mzv_signal signal;
	bool have_tmcc;
	struct mzv_tmcc tmcc;

	bool have_psi;		/* any of PAT/SDT/NIT */
	bool have_pat, have_sdt, have_nit;
	uint16_t transport_stream_id;
	uint16_t original_network_id;
	uint16_t network_id;
	uint8_t remote_control_key_id;
	char network_name[64];
	char ts_name[64];
	int ts_packets;		/* packets read while collecting PSI */

	int nservices;
	struct mzv_service services[MZV_MAX_SERVICES];
};

/*
 * Tunes rf and, if it locks, reads TMCC and collects PAT/SDT/NIT for up to
 * psi_timeout_ms. Returns MZV_OK whether or not it locked (see
 * out->signal.has_lock); errors are for device problems and cancellation.
 */
int mzv_scan_rf(mzv_device *dev, int rf, unsigned int psi_timeout_ms, struct mzv_mux *out);

/* The PSI half of mzv_scan_rf on recorded packets (no signal/TMCC) */
void mzv_mux_from_packets(const uint8_t *packets, size_t count, int rf, struct mzv_mux *out);

/* ---- channel list ----------------------------------------------------- */

struct mzv_channel {
	int major, minor;
	char name[64];
	char kind[8];
	int rf;
	uint16_t service_id;
	uint16_t pmt_pid;	/* as last seen; 0 if unknown */
};

struct mzv_channel_list {
	int count, capacity;
	struct mzv_channel *items;
};

/* $MANZANA_CHANNELS, or ~/Library/Application Support/ManzanaVision/channels.tsv */
const char *mzv_channels_default_path(void);

/* A missing file loads as an empty list. Returns MZV_OK or MZV_ERR_IO. */
int mzv_channels_load(const char *path, struct mzv_channel_list *list);
/* Writes atomically, creating the parent directory. */
int mzv_channels_save(const char *path, struct mzv_channel_list *list);
void mzv_channels_free(struct mzv_channel_list *list);

/*
 * Replaces the list's channels for mux->rf with the mux's listed services.
 * Muxes that didn't lock keep their old entries, and so does a mux heard
 * only through its one-seg layer (no PAT) when entries already exist.
 * Returns true if the list changed.
 */
bool mzv_channels_merge_mux(struct mzv_channel_list *list, const struct mzv_mux *mux);

/* By virtual number ("9.1", or "9" for the lowest 9.x) or by name, ignoring case */
const struct mzv_channel *mzv_channels_find(const struct mzv_channel_list *list, const char *query);

/* ---- streaming -------------------------------------------------------- */

#define MZV_TS_PACKET_SIZE 188
#define MZV_MAX_ES 32

struct mzv_es {
	uint8_t stream_type;	/* 0x1b H.264, 0x0f AAC ADTS, 0x11 AAC LATM, ... */
	uint16_t pid;
	int16_t component_tag;		/* stream_identifier_descriptor, -1 if absent */
	uint16_t data_component_id;	/* data_component_descriptor (0x0008 = ARIB captions), 0 if absent */
};

struct mzv_program {
	uint16_t service_id;
	uint16_t pmt_pid;
	uint16_t pcr_pid;
	unsigned int generation;	/* bumps on every new PMT version */
	int nes;
	struct mzv_es es[MZV_MAX_ES];
};

enum mzv_event {
	MZV_EVENT_LOCKED,	/* streaming started */
	MZV_EVENT_LOCK_LOST,	/* no lock for relock_after_ms; streaming stops */
	MZV_EVENT_RETUNING,
	MZV_EVENT_RELOCKED,	/* streaming again; the epoch has changed */
};

struct mzv_stream_callbacks {
	/* Batches of 188-byte packets; return non-zero to stop streaming */
	int (*packets)(const uint8_t *packets, size_t count, uint32_t epoch, void *ctx);
	/* The program's PMT, each time a new version arrives (service streams only) */
	void (*program)(const struct mzv_program *program, void *ctx);
	/* Signal readings every signal_interval_ms */
	void (*signal)(const struct mzv_signal *signal, void *ctx);
	/* Transmission parameters, once decoded after each (re)lock */
	void (*tmcc)(const struct mzv_tmcc *tmcc, void *ctx);
	void (*event)(enum mzv_event event, uint32_t epoch, void *ctx);
	void *ctx;
};

struct mzv_stream_options {
	int rf;
	uint16_t service_id;		/* 0 = the whole mux, unfiltered */
	bool rewrite_pat;		/* service streams: a PAT listing only this service */
	unsigned int relock_after_ms;	/* 0 = default (2000) */
	unsigned int signal_interval_ms;/* 0 = no signal callbacks */
	unsigned int duration_ms;	/* 0 = until cancelled or stopped */
	bool skip_tune_if_locked;	/* don't re-tune when already locked on rf */
};

/*
 * Tunes and streams until cancelled, stopped by the packets callback, the
 * duration elapses or the device goes away. Re-tunes by itself when lock is
 * lost; each re-lock starts a new epoch (a discontinuity for the player).
 * Returns MZV_OK on a normal stop, MZV_ERR_NO_LOCK if the first tune fails.
 */
int mzv_stream(mzv_device *dev, const struct mzv_stream_options *opts,
	       const struct mzv_stream_callbacks *cb);

/* ---- single-program filter (also usable on recordings) ----------------- */

typedef struct mzv_filter mzv_filter;

mzv_filter *mzv_filter_new(uint16_t service_id, bool rewrite_pat);
void mzv_filter_free(mzv_filter *f);

/*
 * Keeps the service's PAT (rewritten or not), PMT, PCR and elementary
 * stream packets. out must hold count packets; returns how many it wrote.
 */
size_t mzv_filter_feed(mzv_filter *f, const uint8_t *packets, size_t count, uint8_t *out);

/* The service's current PMT; false until one has been seen */
bool mzv_filter_program(const mzv_filter *f, struct mzv_program *program);

#ifdef __cplusplus
}
#endif

#endif
