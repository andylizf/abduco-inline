-include config.mk

VERSION = 1.0

CFLAGS_STD ?= -std=c99 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700 -DNDEBUG
CFLAGS_STD += -DVERSION=\"${VERSION}\"

LDFLAGS_STD ?= -lc -lutil

STRIP ?= strip
INSTALL ?= install

PREFIX ?= /usr/local

SRC = abduco.c

all: lich

config.h:
	cp config.def.h config.h

config.mk:
	@touch $@

lich: config.h config.mk *.c
	${CC} ${CFLAGS} ${CFLAGS_STD} ${CFLAGS_AUTO} ${CFLAGS_EXTRA} ${SRC} ${LDFLAGS} ${LDFLAGS_STD} ${LDFLAGS_AUTO} -o $@

debug: clean
	make CFLAGS_EXTRA='${CFLAGS_DEBUG}'

clean:
	@echo cleaning
	@rm -f lich lich-*.tar.gz config.h

install: lich
	@echo installing executable to ${DESTDIR}${PREFIX}/bin
	@${INSTALL} -d ${DESTDIR}${PREFIX}/bin
	@${INSTALL} -m 0755 lich ${DESTDIR}${PREFIX}/bin

install-strip: install
	${STRIP} ${DESTDIR}${PREFIX}/bin/lich

uninstall:
	@rm -f ${DESTDIR}${PREFIX}/bin/lich

.PHONY: all clean install install-strip uninstall debug
