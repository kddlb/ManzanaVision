// SPDX-License-Identifier: GPL-2.0-only
/* manzanavision: ISDB-T scanner for the DiBcom STK8096GP on macOS */
#include <getopt.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dib0700.h"
#include "meter.h"
#include "scan.h"
#include "stk8096gp.h"
#include "watch.h"

void kcompat_set_debug(int level);

#define DEFAULT_FIRMWARE "firmware/dvb-usb-dib0700-1.20.fw"

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
		"The bridge firmware is read from $MANZANA_FIRMWARE or " DEFAULT_FIRMWARE ".\n"
		"The channel list lives in $MANZANA_CHANNELS or\n"
		"~/Library/Application Support/ManzanaVision/channels.tsv.\n");
}

static void on_sigint(int sig)
{
	(void)sig;
	scan_interrupt();
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
	struct dib0700 *d;

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
	} else if (!strcmp(cmd, "watch")) {
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
	    strcmp(cmd, "watch") && strcmp(cmd, "channels")) {
		usage();
		return 2;
	}
	if (!strcmp(cmd, "channels"))
		return channels_run(); /* no hardware needed */
	if ((rf && (rf < 14 || rf > 69)) || so.from < 14 || so.to > 69 || so.from > so.to) {
		fprintf(stderr, "UHF channels are 14-69\n");
		return 2;
	}
	kcompat_set_debug(verbose);

	fw = getenv("MANZANA_FIRMWARE");
	d = dib0700_open(fw ? fw : DEFAULT_FIRMWARE);
	if (!d)
		return 1;
	u32 v = dib0700_fw_version(d);
	fprintf(stderr, "DiB0700 firmware 0x%05x%s\n", v,
		dib0700_was_cold(d) ? " (uploaded)" : "");

	if (stk_open(d) < 0) {
		dib0700_close(d);
		return 1;
	}
	fprintf(stderr, "DiB8000 rev 0x%04x + DiB0090 ready\n", stk_demod_revision());

	signal(SIGINT, on_sigint);
	if (!strcmp(cmd, "scan"))
		ret = scan_run(d, &so);
	else if (!strcmp(cmd, "tune"))
		ret = tune_run(d, rf, dump, seconds);
	else if (!strcmp(cmd, "signal"))
		ret = meter_run(d, rf, beep);
	else if (!strcmp(cmd, "watch"))
		ret = watch_run(d, query, output);
	else
		ret = 0;

	stk_close();
	dib0700_close(d);
	return ret;
}
