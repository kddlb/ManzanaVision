// SPDX-License-Identifier: GPL-2.0-only
/*
 * DiB0700 USB bridge over libusb.
 *
 * Ported from linux drivers/media/usb/dvb-usb/dib0700_core.c
 *  Copyright (C) 2005-6 DiBcom, SA
 */
#include "dib0700.h"

#include <libusb.h>

#define DIB0700_VID 0x10b8
#define STK8096GP_PID 0x1fa0

#define EP_FW_OUT 0x01
#define EP_TS_IN 0x82

#define REQUEST_I2C_READ       0x2
#define REQUEST_I2C_WRITE      0x3
#define REQUEST_JUMPRAM        0x8
#define REQUEST_SET_CLOCK      0xB
#define REQUEST_SET_GPIO       0xC
#define REQUEST_ENABLE_VIDEO   0xF
#define REQUEST_GET_VERSION    0x15

#define CTRL_TIMEOUT_MS 1000

/* Firmware < 1.20.1 cannot change the USB xfer length: reads must be n*512 */
#define TS_XFER_SIZE (32 * 512)
#define TS_NUM_XFERS 8

#define VENDOR_OUT (LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_ENDPOINT_OUT)
#define VENDOR_IN (LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_ENDPOINT_IN)

struct dib0700 {
	libusb_context *ctx;
	libusb_device_handle *h;
	u32 fw_version;
	bool was_cold;
	u8 channel_state;
	struct i2c_adapter i2c;

	/* TS reassembly across bulk transfers */
	u8 carry[TS_PACKET_SIZE];
	int carry_len;
};

static const struct i2c_algorithm dib0700_i2c_algo;

static int ctrl_wr(struct dib0700 *d, u8 *tx, u16 txlen)
{
	int ret = libusb_control_transfer(d->h, VENDOR_OUT, tx[0], 0, 0, tx, txlen, CTRL_TIMEOUT_MS);

	if (ret != txlen && kcompat_debug)
		fprintf(stderr, "dib0700: ep0 write of req 0x%02x failed: %s\n", tx[0],
			ret < 0 ? libusb_error_name(ret) : "short");
	return ret < 0 ? -EIO : 0;
}

static int get_version(struct dib0700 *d, u8 buf[16])
{
	return libusb_control_transfer(d->h, VENDOR_IN, REQUEST_GET_VERSION, 0, 0, buf, 16, CTRL_TIMEOUT_MS);
}

/*
 * The .fw file is a packed Intel-HEX variant: len, addr (LE16), type, data,
 * checksum. Each record goes out on the bulk pipe with the address big-endian.
 */
static int download_firmware(struct dib0700 *d, const char *path)
{
	FILE *f = fopen(path, "rb");
	u8 *fw, buf[260], jump[8] = { REQUEST_JUMPRAM, 0, 0, 0, 0x70, 0x00, 0x00, 0x00 };
	long size, pos = 0;
	int ret = 0, actlen;

	if (!f) {
		fprintf(stderr, "cannot open firmware '%s': %s\n"
			"run scripts/fetch-firmware.sh or set MANZANA_FIRMWARE\n", path, strerror(errno));
		return -ENOENT;
	}
	fseek(f, 0, SEEK_END);
	size = ftell(f);
	rewind(f);
	fw = malloc(size);
	if (fread(fw, 1, size, f) != (size_t)size) {
		fclose(f);
		free(fw);
		return -EIO;
	}
	fclose(f);

	while (pos < size) {
		const u8 *b = &fw[pos];
		u8 len = b[0];
		u16 addr = b[1] | (b[2] << 8);

		if (pos + len + 4 >= size) {
			ret = -EINVAL;
			break;
		}
		buf[0] = len;
		buf[1] = addr >> 8;
		buf[2] = addr & 0xff;
		buf[3] = b[3];
		memcpy(&buf[4], &b[4], len);
		buf[4 + len] = b[4 + len];

		ret = libusb_bulk_transfer(d->h, EP_FW_OUT, buf, len + 5, &actlen, 1000);
		if (ret < 0) {
			fprintf(stderr, "firmware download failed at %ld: %s\n", pos, libusb_error_name(ret));
			ret = -EIO;
			break;
		}
		pos += len + 5;
	}
	free(fw);
	if (ret < 0)
		return ret;

	ret = libusb_bulk_transfer(d->h, EP_FW_OUT, jump, sizeof(jump), &actlen, 1000);
	if (ret < 0 || actlen != sizeof(jump)) {
		fprintf(stderr, "firmware jumpram failed: %s\n", libusb_error_name(ret));
		return -EIO;
	}
	msleep(500);
	return 0;
}

struct dib0700 *dib0700_open(const char *firmware_path)
{
	struct dib0700 *d = calloc(1, sizeof(*d));
	u8 ver[16];
	int ret;

	if (libusb_init(&d->ctx) < 0) {
		fprintf(stderr, "libusb_init failed\n");
		free(d);
		return NULL;
	}
	d->h = libusb_open_device_with_vid_pid(d->ctx, DIB0700_VID, STK8096GP_PID);
	if (!d->h) {
		fprintf(stderr, "no STK8096GP (%04x:%04x) found\n", DIB0700_VID, STK8096GP_PID);
		goto fail;
	}
	ret = libusb_claim_interface(d->h, 0);
	if (ret < 0) {
		fprintf(stderr, "cannot claim interface: %s\n", libusb_error_name(ret));
		goto fail;
	}

	/* a cold bridge stalls GET_VERSION until firmware runs from RAM */
	if (get_version(d, ver) <= 0) {
		d->was_cold = true;
		if (download_firmware(d, firmware_path) < 0)
			goto fail;
		if (get_version(d, ver) <= 0) {
			fprintf(stderr, "bridge did not come up after firmware download\n");
			goto fail;
		}
	}
	d->fw_version = (ver[8] << 24) | (ver[9] << 16) | (ver[10] << 8) | ver[11];

	d->i2c.algo = &dib0700_i2c_algo;
	strscpy(d->i2c.name, "dib0700 frontend i2c", sizeof(d->i2c.name));
	i2c_set_adapdata(&d->i2c, d);
	return d;

fail:
	dib0700_close(d);
	return NULL;
}

void dib0700_close(struct dib0700 *d)
{
	if (!d)
		return;
	if (d->h) {
		libusb_release_interface(d->h, 0);
		libusb_close(d->h);
	}
	libusb_exit(d->ctx);
	free(d);
}

u32 dib0700_fw_version(const struct dib0700 *d) { return d->fw_version; }
bool dib0700_was_cold(const struct dib0700 *d) { return d->was_cold; }
struct i2c_adapter *dib0700_i2c_adapter(struct dib0700 *d) { return &d->i2c; }

int dib0700_set_gpio(struct dib0700 *d, enum dib07x0_gpios gpio, u8 dir, u8 val)
{
	u8 buf[3] = { REQUEST_SET_GPIO, gpio, ((dir & 0x01) << 7) | ((val & 0x01) << 6) };

	return ctrl_wr(d, buf, sizeof(buf));
}

static int dib0700_set_clock(struct dib0700 *d, u8 en_pll, u8 pll_src, u8 pll_range, u8 clock_gpio3,
			     u16 pll_prediv, u16 pll_loopdiv, u16 free_div, u16 dsuScaler)
{
	u8 buf[10] = {
		REQUEST_SET_CLOCK,
		(en_pll << 7) | (pll_src << 6) | (pll_range << 5) | (clock_gpio3 << 4),
		pll_prediv >> 8, pll_prediv & 0xff,
		pll_loopdiv >> 8, pll_loopdiv & 0xff,
		free_div >> 8, free_div & 0xff,
		dsuScaler >> 8, dsuScaler & 0xff,
	};

	return ctrl_wr(d, buf, sizeof(buf));
}

int dib0700_ctrl_clock(struct dib0700 *d, u32 clk_MHz, u8 clock_out_gp3)
{
	switch (clk_MHz) {
	case 72:
		return dib0700_set_clock(d, 1, 0, 1, clock_out_gp3, 2, 24, 0, 0x4c);
	default:
		return -EINVAL;
	}
}

static void trace_msg(const char *dir, const struct i2c_msg *m)
{
	if (kcompat_debug < 2)
		return;
	fprintf(stderr, "i2c %s %02x:", dir, m->addr);
	for (int k = 0; k < m->len; k++)
		fprintf(stderr, " %02x", m->buf[k]);
	fprintf(stderr, "\n");
}

/*
 * Legacy I2C (dib0700_i2c_xfer_legacy). Linux keeps the STK8096GP on this
 * path even with 1.20 firmware; the "new" requests stall once the DiB8000
 * switches to its PLL. A write followed by a read becomes one I2C_READ
 * request carrying up to two register-address bytes in wIndex.
 */
static int dib0700_i2c_xfer(struct i2c_adapter *adap, struct i2c_msg *msg, int num)
{
	struct dib0700 *d = i2c_get_adapdata(adap);
	u8 buf[2 + 64];
	int i, ret;

	for (i = 0; i < num; i++) {
		if (msg[i].len > sizeof(buf) - 2)
			return -EIO;

		if (i + 1 < num && (msg[i + 1].flags & I2C_M_RD)) {
			u16 value, index = 0;

			if (msg[i].len > 2 || msg[i + 1].len > sizeof(buf))
				return -EIO;
			trace_msg("W", &msg[i]);
			/* dib0700_ctrl_rd: tx = req, addr|1, reg bytes */
			value = (msg[i].len << 8) | (msg[i].addr << 1) | 1;
			if (msg[i].len > 0)
				index |= msg[i].buf[0] << 8;
			if (msg[i].len > 1)
				index |= msg[i].buf[1];
			ret = libusb_control_transfer(d->h, VENDOR_IN, REQUEST_I2C_READ, value, index,
						      buf, msg[i + 1].len, CTRL_TIMEOUT_MS);
			/* firmware quirk: a zero-length reply means the read failed */
			if (ret <= 0) {
				if (kcompat_debug)
					fprintf(stderr, "dib0700: i2c read 0x%02x failed: %s\n", msg[i].addr,
						ret < 0 ? libusb_error_name(ret) : "empty");
				return -EIO;
			}
			memcpy(msg[i + 1].buf, buf, msg[i + 1].len);
			trace_msg("R", &msg[i + 1]);
			i++;
		} else if (msg[i].flags & I2C_M_RD) {
			return -EOPNOTSUPP; /* bare reads need the new API */
		} else {
			trace_msg("W", &msg[i]);
			buf[0] = REQUEST_I2C_WRITE;
			buf[1] = msg[i].addr << 1;
			memcpy(&buf[2], msg[i].buf, msg[i].len);
			ret = libusb_control_transfer(d->h, VENDOR_OUT, REQUEST_I2C_WRITE, 0, 0,
						      buf, msg[i].len + 2, CTRL_TIMEOUT_MS);
			if (ret < 0) {
				if (kcompat_debug)
					fprintf(stderr, "dib0700: i2c write 0x%02x failed: %s\n",
						msg[i].addr, libusb_error_name(ret));
				return -EIO;
			}
		}
	}
	return num;
}

static u32 dib0700_i2c_func(struct i2c_adapter *adapter)
{
	(void)adapter;
	return I2C_FUNC_I2C;
}

static const struct i2c_algorithm dib0700_i2c_algo = {
	.master_xfer = dib0700_i2c_xfer,
	.functionality = dib0700_i2c_func,
};

/* Streams adapter 0 (EP 0x82) in master mode */
int dib0700_streaming_ctrl(struct dib0700 *d, int onoff)
{
	u8 buf[4];

	if (onoff)
		d->channel_state |= 1;
	else
		d->channel_state &= ~1;

	buf[0] = REQUEST_ENABLE_VIDEO;
	buf[1] = (onoff << 4) | 0x00; /* MPEG2 188-byte mode */
	buf[2] = (0x01 << 4) | d->channel_state; /* master mode */
	buf[3] = 0x00;
	d->carry_len = 0;
	return ctrl_wr(d, buf, sizeof(buf));
}

struct ts_read_ctx {
	struct dib0700 *d;
	dib0700_ts_cb cb;
	void *opaque;
	int packets;
	int stop;
	int error;
	int in_flight;
};

/* Splits a chunk of bulk data into sync-aligned 188-byte packets */
static void ts_feed(struct ts_read_ctx *rc, const u8 *data, int len)
{
	struct dib0700 *d = rc->d;

	while (len > 0 && !rc->stop) {
		if (d->carry_len == 0) {
			/* hunt for sync */
			const u8 *p = memchr(data, 0x47, len);

			if (!p)
				return;
			len -= p - data;
			data = p;
			if (len >= TS_PACKET_SIZE) {
				/* confirm with the next sync byte when we can see it */
				if (len > TS_PACKET_SIZE && data[TS_PACKET_SIZE] != 0x47) {
					data++;
					len--;
					continue;
				}
				rc->packets++;
				if (rc->cb(data, rc->opaque))
					rc->stop = 1;
				data += TS_PACKET_SIZE;
				len -= TS_PACKET_SIZE;
				continue;
			}
		}
		{
			int n = min(len, TS_PACKET_SIZE - d->carry_len);

			memcpy(&d->carry[d->carry_len], data, n);
			d->carry_len += n;
			data += n;
			len -= n;
			if (d->carry_len == TS_PACKET_SIZE) {
				d->carry_len = 0;
				if (d->carry[0] == 0x47) {
					rc->packets++;
					if (rc->cb(d->carry, rc->opaque))
						rc->stop = 1;
				}
			}
		}
	}
}

static void LIBUSB_CALL ts_xfer_done(struct libusb_transfer *xfer)
{
	struct ts_read_ctx *rc = xfer->user_data;

	if (xfer->status == LIBUSB_TRANSFER_COMPLETED || xfer->status == LIBUSB_TRANSFER_TIMED_OUT) {
		ts_feed(rc, xfer->buffer, xfer->actual_length);
	} else if (xfer->status != LIBUSB_TRANSFER_CANCELLED) {
		rc->error = LIBUSB_ERROR_IO;
		rc->stop = 1;
	}

	if (!rc->stop && xfer->status != LIBUSB_TRANSFER_CANCELLED &&
	    libusb_submit_transfer(xfer) == 0)
		return;
	rc->in_flight--;
}

int dib0700_read_ts(struct dib0700 *d, unsigned int timeout_ms, dib0700_ts_cb cb, void *opaque)
{
	struct libusb_transfer *xfers[TS_NUM_XFERS] = { 0 };
	struct ts_read_ctx rc = { .d = d, .cb = cb, .opaque = opaque };
	unsigned long deadline = jiffies + timeout_ms;
	int i;

	for (i = 0; i < TS_NUM_XFERS; i++) {
		u8 *buf = malloc(TS_XFER_SIZE);

		xfers[i] = libusb_alloc_transfer(0);
		libusb_fill_bulk_transfer(xfers[i], d->h, EP_TS_IN, buf, TS_XFER_SIZE, ts_xfer_done, &rc, 0);
		xfers[i]->flags |= LIBUSB_TRANSFER_FREE_BUFFER;
		if (libusb_submit_transfer(xfers[i]) == 0)
			rc.in_flight++;
	}

	while (!rc.stop && (!timeout_ms || time_before(jiffies, deadline))) {
		struct timeval tv = { .tv_sec = 0, .tv_usec = 50000 };

		libusb_handle_events_timeout_completed(d->ctx, &tv, NULL);
		if (!rc.stop && cb(NULL, opaque))
			rc.stop = 1;
	}

	rc.stop = 1;
	for (i = 0; i < TS_NUM_XFERS; i++)
		libusb_cancel_transfer(xfers[i]);
	while (rc.in_flight > 0) {
		struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 };

		libusb_handle_events_timeout_completed(d->ctx, &tv, NULL);
	}
	for (i = 0; i < TS_NUM_XFERS; i++)
		libusb_free_transfer(xfers[i]);

	return rc.error ? rc.error : rc.packets;
}
