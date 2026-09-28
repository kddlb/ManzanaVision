// SPDX-License-Identifier: GPL-2.0-only
/* One place all core output goes through, so the app can capture it */
#include <stdarg.h>
#include <stdio.h>

#include "core.h"

static mzv_log_fn log_fn;
static void *log_ctx;

void mzv_set_log(mzv_log_fn fn, void *ctx)
{
	log_fn = fn;
	log_ctx = ctx;
}

void mzv_set_debug(int level)
{
	kcompat_set_debug(level);
}

static void vlog(int level, const char *fmt, va_list ap)
{
	char msg[1024];

	if ((level == MZV_LOG_DEBUG && kcompat_debug < 1) || (level == MZV_LOG_TRACE && kcompat_debug < 2))
		return;
	vsnprintf(msg, sizeof(msg), fmt, ap);
	if (log_fn)
		log_fn((enum mzv_log_level)level, msg, log_ctx);
	else
		fputs(msg, stderr);
}

void mzv_log(enum mzv_log_level level, const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vlog(level, fmt, ap);
	va_end(ap);
}

void kcompat_log(int level, const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vlog(level, fmt, ap);
	va_end(ap);
}

const char *mzv_version(void)
{
	return "0.1.0";
}

const char *mzv_strerror(int err)
{
	switch (err) {
	case MZV_OK: return "ok";
	case MZV_ERR_NO_DEVICE: return "no STK8096GP connected";
	case MZV_ERR_BUSY: return "tuner is in use";
	case MZV_ERR_FIRMWARE: return "firmware missing or rejected";
	case MZV_ERR_IO: return "USB I/O error";
	case MZV_ERR_NO_FRONTEND: return "demodulator or tuner not responding";
	case MZV_ERR_CANCELLED: return "cancelled";
	case MZV_ERR_NO_LOCK: return "no lock";
	case MZV_ERR_GONE: return "tuner disconnected";
	case MZV_ERR_INVALID: return "invalid argument";
	default: return "unknown error";
	}
}
