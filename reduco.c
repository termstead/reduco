#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "config.h"

#ifndef VERSION
#define VERSION "unknown"
#endif

static void vmsg(const char *fmt, va_list ap)
{
	int err = errno;
	size_t len = strlen(fmt);

	fputs("reduco: ", stderr);
	vfprintf(stderr, fmt, ap);
	if (len > 0 && fmt[len - 1] == ':')
		fprintf(stderr, " %s", strerror(err));
	fputc('\n', stderr);
}

void warn(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vmsg(fmt, ap);
	va_end(ap);
}

void die(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vmsg(fmt, ap);
	va_end(ap);
	exit(EXIT_FAILURE);
}

static void usage(void)
{
	fputs("usage: reduco [-v]\n", stderr);
	exit(EXIT_FAILURE);
}

static void version(void)
{
	puts("reduco-" VERSION);
	if (fflush(stdout) == EOF || ferror(stdout))
		die("write:");
	exit(EXIT_SUCCESS);
}

int main(int argc, char *argv[])
{
	int opt;

	while ((opt = getopt(argc, argv, "v")) != -1) {
		switch (opt) {
		case 'v':
			version();
			break;
		default:
			usage();
		}
	}

	usage();
	return EXIT_FAILURE;
}
