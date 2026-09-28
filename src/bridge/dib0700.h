/* SPDX-License-Identifier: GPL-2.0-only */
/* DiB0700 USB bridge over libusb (protocol from linux dvb-usb/dib0700_core.c) */
#ifndef DIB0700_BRIDGE_H
#define DIB0700_BRIDGE_H

#include <linux/i2c.h>

#define TS_PACKET_SIZE 188

/* GPIO numbers as the bridge firmware expects them (linux dib07x0.h) */
enum dib07x0_gpios {
	GPIO0  =  0,
	GPIO1  =  2,
	GPIO2  =  3,
	GPIO3  =  4,
	GPIO4  =  5,
	GPIO5  =  6,
	GPIO6  =  8,
	GPIO7  = 10,
	GPIO8  = 11,
	GPIO9  = 14,
	GPIO10 = 15,
};

#define GPIO_IN  0
#define GPIO_OUT 1

struct dib0700;

/*
 * Opens the first 10b8:1fa0 device, uploading firmware_path if the bridge is
 * still cold. Returns MZV_OK or an MZV_ERR_* code (logged).
 */
int dib0700_open(const char *firmware_path, struct dib0700 **out);
void dib0700_close(struct dib0700 *d);

u32 dib0700_fw_version(const struct dib0700 *d);

/* The stick was unplugged (a libusb call said so); the handle is dead */
bool dib0700_is_gone(struct dib0700 *d);
/* After an I/O error: checks the stick still answers, marking it gone if not */
bool dib0700_probe_alive(struct dib0700 *d);
/* true if this open uploaded the firmware (device was cold) */
bool dib0700_was_cold(const struct dib0700 *d);

/* I2C adapter for the frontend bus; its master_xfer drives the bridge */
struct i2c_adapter *dib0700_i2c_adapter(struct dib0700 *d);

int dib0700_set_gpio(struct dib0700 *d, enum dib07x0_gpios gpio, u8 dir, u8 val);
int dib0700_ctrl_clock(struct dib0700 *d, u32 clk_MHz, u8 clock_out_gp3);

int dib0700_streaming_ctrl(struct dib0700 *d, int onoff);

/*
 * Reads TS from the stream endpoint for up to timeout_ms (0 = no limit) and
 * hands every aligned 188-byte packet to cb. Every ~50 ms cb is also called
 * with pkt == NULL, so it can stop the read even while no data arrives.
 * Stops as soon as cb returns non-zero. Returns the number of packets
 * delivered, or a negative libusb error.
 */
typedef int (*dib0700_ts_cb)(const u8 *pkt, void *opaque);
int dib0700_read_ts(struct dib0700 *d, unsigned int timeout_ms, dib0700_ts_cb cb, void *opaque);

#endif
