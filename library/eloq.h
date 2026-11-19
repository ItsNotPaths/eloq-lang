#ifndef ELOQ_H
#define ELOQ_H

#include <stdbool.h>

#define ELOQ_ABEND_CAPACITY 16

typedef struct { const char *data; int len; } String;

typedef enum {
	ELOQ_ABEND_BAD_CASE,
	ELOQ_ABEND_BAD_COUNT,
	ELOQ_ABCONT_TABLE_FULL,
	ELOQ_ABCONT_BAD_INDEX,
} Eloq_Code;

typedef struct {
	Eloq_Code code;
	const char *file;
	int line;
	int row;   // -1 when not in a table
	int value; // the bad enum, count or index
} Eloq_Entry;

typedef struct {
	Eloq_Entry entries[ELOQ_ABEND_CAPACITY];
	int count;
	int dropped;
	bool stop_on_abcont;
} Eloq_Abends;

static inline bool eloq_is_abend(Eloq_Code code) {
	return code == ELOQ_ABEND_BAD_CASE || code == ELOQ_ABEND_BAD_COUNT;
}

static inline const char *eloq_code_name(Eloq_Code code) {
	switch (code) {
	case ELOQ_ABEND_BAD_CASE: return "BAD_CASE";
	case ELOQ_ABEND_BAD_COUNT: return "BAD_COUNT";
	case ELOQ_ABCONT_TABLE_FULL: return "TABLE_FULL";
	case ELOQ_ABCONT_BAD_INDEX: return "BAD_INDEX";
	}
	return "UNKNOWN";
}

#endif

// Apart from the guard, so a host that defines ELOQ_STDIO after a first include still gets it.
#if defined(ELOQ_STDIO) && !defined(ELOQ_STDIO_H)
#define ELOQ_STDIO_H
#include <stdio.h>

static inline void eloq_print_abends(const Eloq_Abends *abends, FILE *out) {
	for (int entry = 0; entry < abends->count; entry += 1) {
		Eloq_Entry code = abends->entries[entry];
		fprintf(out, "%s:%d", code.file, code.line);
		if (code.row >= 0) fprintf(out, " row %d", code.row);
		fprintf(out, ": %s %s (value %d)\n", eloq_is_abend(code.code) ? "abend" : "abcont", eloq_code_name(code.code), code.value);
	}
	if (abends->dropped > 0) fprintf(out, "%d more codes dropped\n", abends->dropped);
}
#endif
