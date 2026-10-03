.POSIX:

VERSION = 0.0

PREFIX = /usr/local
BINDIR = $(PREFIX)/bin
MANDIR = $(PREFIX)/share/man/man1

CC = cc
CFLAGS = -O2
CFLAGS_STD = -std=c99 -D_POSIX_C_SOURCE=200809L
CFLAGS_WARN = -Wall -Wextra -pedantic
LDFLAGS =

SRC = reduco.c

all: reduco

config.h:
	cp config.def.h config.h

reduco: config.h $(SRC)
	$(CC) $(CFLAGS) $(CFLAGS_STD) $(CFLAGS_WARN) -DVERSION=\"$(VERSION)\" $(SRC) $(LDFLAGS) -o $@

debug:
	$(MAKE) CFLAGS="-O0 -g"

test: reduco
	./testsuite.sh

clean:
	rm -f reduco reduco-$(VERSION).tar.gz

dist: clean
	mkdir -p reduco-$(VERSION)
	cp LICENSE Makefile README.md config.def.h reduco.1 reduco.c testlock.c testsuite.sh reduco-$(VERSION)
	tar -cf - reduco-$(VERSION) | gzip -c > reduco-$(VERSION).tar.gz
	rm -rf reduco-$(VERSION)

install: reduco
	mkdir -p $(DESTDIR)$(BINDIR) $(DESTDIR)$(MANDIR)
	cp -f reduco $(DESTDIR)$(BINDIR)/reduco
	chmod 755 $(DESTDIR)$(BINDIR)/reduco
	sed "s/VERSION/$(VERSION)/g" < reduco.1 > $(DESTDIR)$(MANDIR)/reduco.1
	chmod 644 $(DESTDIR)$(MANDIR)/reduco.1

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/reduco $(DESTDIR)$(MANDIR)/reduco.1

.PHONY: all debug test clean dist install uninstall
