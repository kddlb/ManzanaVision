/* SPDX-License-Identifier: GPL-2.0-only */
/* Userspace stand-in for <linux/i2c.h>: adapters are just algo + data. */
#ifndef _KC_I2C_H
#define _KC_I2C_H
#include "../kcompat.h"

#define I2C_M_RD	0x0001
#define I2C_M_NOSTART	0x4000
#define I2C_FUNC_I2C	0x00000001

struct i2c_msg {
	u16 addr;	/* 7-bit address */
	u16 flags;
	u16 len;
	u8 *buf;
};

struct i2c_adapter;

struct i2c_algorithm {
	int (*master_xfer)(struct i2c_adapter *adap, struct i2c_msg *msgs, int num);
	u32 (*functionality)(struct i2c_adapter *adap);
};

struct device {
	struct device *parent;
};

struct i2c_adapter {
	const struct i2c_algorithm *algo;
	void *algo_data;
	void *adapdata;
	struct device dev;
	char name[48];
};

static inline void *i2c_get_adapdata(const struct i2c_adapter *adap) { return adap->adapdata; }
static inline void i2c_set_adapdata(struct i2c_adapter *adap, void *data) { adap->adapdata = data; }
static inline int i2c_add_adapter(struct i2c_adapter *adap) { (void)adap; return 0; }
static inline void i2c_del_adapter(struct i2c_adapter *adap) { (void)adap; }

int i2c_transfer(struct i2c_adapter *adap, struct i2c_msg *msgs, int num);

#endif
