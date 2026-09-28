// SPDX-License-Identifier: GPL-2.0-only
/* manzanavision: ISDB-T scanner for the DiBcom STK8096GP on macOS */
#include <getopt.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cli.h"
#include "meter.h"

#define FIRMWARE_NAME "dvb-usb-dib0700-1.20.fw"
#define DEFAULT_FIRMWARE "firmware/" FIRMWARE_NAME

static void usage(void)
{
	fprintf(stderr,
		"usage: manzanavision [-v] <command> [options]\n"
		"\n"
		"commands:\n"
		"  probe                          bring up the stick and identify the chips\n"
		"  scan [--from N] [--to N] [--json] [--psi-timeout MS] [--no-save]\n"
		"                                 scan UHF channels (default 14-51) and save\n"
		"                                 what was found to the channel list\n"
		"  channels                       show the saved channel list\n"
		"  watch <9.1|9|name> [--output FILE]\n"
		"                                 stream one channel as MPEG-TS to stdout,\n"
		"                                 e.g. manzanavision watch 9.1 | ffplay -\n"
		"  tune <rf> [--dump FILE] [--seconds N]\n"
		"                                 tune one channel, optionally capture TS\n"
		"  signal <rf> [--beep]           live signal meter for aiming an antenna;\n"
		"                                 --beep plays a tone whose pitch follows SNR\n"
		"\n"
		"The bridge firmware is read from $MANZANA_FIRMWARE, " DEFAULT_FIRMWARE ",\n"
		"or ~/Library/Application Support/ManzanaVision/firmware/.\n"
		"The channel list lives in $MANZANA_CHANNELS or\n"
		"~/Library/Application Support/ManzanaVision/channels.tsv.\n");
}

static mzv_device *device;

static void on_sigint(int sig)
{
	(void)sig;
	if (device)
		mzv_cancel(device);
}

/* $MANZANA_FIRMWARE, ./firmware/, then the folder the Mac app downloads into */
static const char *find_firmware(void)
{
	static char path[1024];
	const char *env = getenv("MANZANA_FIRMWARE");
	const char *home = getenv("HOME");

	if (env && *env)
		return env;
	if (access(DEFAULT_FIRMWARE, R_OK) == 0 || !home)
		return DEFAULT_FIRMWARE;
	snprintf(path, sizeof(path), "%s/Library/Application Support/ManzanaVision/firmware/%s", home,
		 FIRMWARE_NAME);
	return access(path, R_OK) == 0 ? path : DEFAULT_FIRMWARE;
}

int main(int argc, char **argv)
{
	static const struct option longopts[] = {
		{ "from", required_argument, NULL, 'f' },
		{ "to", required_argument, NULL, 't' },
		{ "json", no_argument, NULL, 'j' },
		{ "psi-timeout", required_argument, NULL, 'p' },
		{ "dump", required_argument, NULL, 'd' },
		{ "seconds", required_argument, NULL, 's' },
		{ "beep", no_argument, NULL, 'b' },
		{ "no-save", no_argument, NULL, 'n' },
		{ "output", required_argument, NULL, 'o' },
		{ "verbose", no_argument, NULL, 'v' },
		{ "help", no_argument, NULL, 'h' },
		{ 0 }
	};
	struct scan_opts so = { .from = 14, .to = 51, .psi_timeout_ms = 5000, .save = true };
	const char *dump = NULL, *output = NULL, *query = NULL, *fw, *cmd;
	unsigned int seconds = 10;
	int verbose = 0, c, ret, rf = 0;
	bool beep = false;
	struct mzv_device_info info;

	/* "+" stops at the command; options after it are parsed below */
	while ((c = getopt_long(argc, argv, "+vh", longopts, NULL)) != -1) {
		switch (c) {
		case 'v': verbose++; break;
		default: usage(); return c == 'h' ? 0 : 2;
		}
	}
	if (optind >= argc) {
		usage();
		return 2;
	}
	cmd = argv[optind++];
	if (!strcmp(cmd, "tune") || !strcmp(cmd, "signal")) {
		if (optind >= argc) {
			usage();
			return 2;
		}
		rf = atoi(argv[optind++]);
	} else if (!strcmp(cmd, "watch") || !strcmp(cmd, "remux")) {
		if (optind >= argc) {
			usage();
			return 2;
		}
		query = argv[optind++];
	}
	while ((c = getopt_long(argc, argv, "v", longopts, NULL)) != -1) {
		switch (c) {
		case 'f': so.from = atoi(optarg); break;
		case 't': so.to = atoi(optarg); break;
		case 'j': so.json = true; break;
		case 'p': so.psi_timeout_ms = atoi(optarg); break;
		case 'd': dump = optarg; break;
		case 's': seconds = atoi(optarg); break;
		case 'b': beep = true; break;
		case 'n': so.save = false; break;
		case 'o': output = optarg; break;
		case 'v': verbose++; break;
		default: usage(); return 2;
		}
	}
	if (strcmp(cmd, "probe") && strcmp(cmd, "scan") && strcmp(cmd, "tune") && strcmp(cmd, "signal") &&
	    strcmp(cmd, "watch") && strcmp(cmd, "channels") && strcmp(cmd, "remux")) {
		usage();
		return 2;
	}
	if (!strcmp(cmd, "channels"))
		return channels_run(); /* no hardware needed */
	if (!strcmp(cmd, "remux")) {
		/* hidden: remux IN.ts <service_id|9.1> --output OUT.ts */
		if (!query || !output || optind >= argc) {
			fprintf(stderr, "usage: manzanavision remux IN.ts <service_id|virtual> --output OUT.ts\n");
			return 2;
		}
		return remux_run(query, argv[optind], output);
	}
	if ((rf && (rf < MZV_RF_MIN || rf > MZV_RF_MAX)) || so.from < MZV_RF_MIN || so.to > MZV_RF_MAX ||
	    so.from > so.to) {
		fprintf(stderr, "UHF channels are 14-69\n");
		return 2;
	}
	mzv_set_debug(verbose);

	fw = find_firmware();
	ret = mzv_open(fw, &device);
	if (ret < 0) {
		if (ret == MZV_ERR_BUSY)
			fprintf(stderr, "the tuner is in use by another program\n");
		else if (ret == MZV_ERR_FIRMWARE)
			fprintf(stderr, "the firmware ships in firmware/; run from the repo or set MANZANA_FIRMWARE\n");
		return 1;
	}
	mzv_get_info(device, &info);
	fprintf(stderr, "DiB0700 firmware 0x%05x%s\n", info.firmware_version,
		info.firmware_uploaded ? " (uploaded)" : "");
	fprintf(stderr, "DiB8000 rev 0x%04x + DiB0090 ready\n", info.demod_revision);

	signal(SIGINT, on_sigint);
	if (!strcmp(cmd, "scan"))
		ret = scan_run(device, &so);
	else if (!strcmp(cmd, "tune"))
		ret = tune_run(device, rf, dump, seconds);
	else if (!strcmp(cmd, "signal"))
		ret = meter_run(device, rf, beep);
	else if (!strcmp(cmd, "watch"))
		ret = watch_run(device, query, output);
	else
		ret = 0;

	mzv_close(device);
	device = NULL;
	return ret;
}
