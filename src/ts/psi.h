/* SPDX-License-Identifier: GPL-2.0-only */
/* Just enough MPEG-TS PSI/SI parsing to list the services on an ISDB-T mux */
#ifndef PSI_H
#define PSI_H

#include <stdbool.h>
#include <stdint.h>

#define PSI_MAX_SERVICES 32

struct psi_service {
	uint16_t service_id;
	uint16_t pmt_pid;
	uint8_t service_type;	/* from the SDT service_descriptor (0x01 TV, 0xC0 data, ...) */
	bool in_pat;
	bool in_sdt;
	char name[64];		/* UTF-8 */
	char provider[64];	/* UTF-8 */
};

#define PSI_MAX_ES 32

/* PMT of the program selected with psi_watch_program() */
struct psi_program {
	uint16_t program_number;	/* 0 = none selected */
	uint16_t pmt_pid;		/* from the live PAT, 0 until known */
	bool have_pmt;
	unsigned int generation;	/* bumps on every new PMT version */
	uint16_t pcr_pid;
	int nes;
	struct {
		uint8_t stream_type;
		uint16_t pid;
	} es[PSI_MAX_ES];
};

struct psi_mux {
	bool have_pat;
	bool have_sdt;
	bool have_nit;

	uint16_t transport_stream_id;
	uint16_t original_network_id;
	uint16_t network_id;
	char network_name[64];	/* NIT network_name_descriptor */
	char ts_name[64];	/* NIT ts_information_descriptor */
	uint8_t remote_control_key_id; /* virtual channel major number, 0 if absent */

	int nservices;
	struct psi_service services[PSI_MAX_SERVICES];

	struct psi_program program;
};

struct psi_parser;

struct psi_parser *psi_new(void);
void psi_free(struct psi_parser *p);

/* Also follows the PMT of this program (its PID is taken from the PAT) */
void psi_watch_program(struct psi_parser *p, uint16_t program_number);

/* Feeds one 188-byte TS packet */
void psi_feed(struct psi_parser *p, const uint8_t *pkt);

/* true once PAT, SDT and NIT for this TS have all been seen in full */
bool psi_complete(const struct psi_parser *p);

const struct psi_mux *psi_result(const struct psi_parser *p);

/*
 * One-seg services carry their PMT on 0x1FC8..0x1FCF (ARIB TR-B14). Without
 * a PAT, falls back to the service_id type bits or SDT service type 0xC0.
 */
bool psi_is_oneseg(const struct psi_service *s);

/*
 * Virtual channel number as receivers show it: major = remote_control_key_id,
 * minor = service_number + 1 for full-seg (service_id & 7, per NBR 15603) and
 * 31.. for one-seg. Broadcasters don't all follow the service_id type bits,
 * so one-seg is detected from the PMT PID instead. e.g. 8.1, 8.2, 8.31.
 */
void psi_virtual_channel(const struct psi_mux *m, const struct psi_service *s, int *major, int *minor);

#endif
